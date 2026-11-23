#!/usr/bin/env bash
# --- Логирование и ротация логов на хосте ---
rn_nginx_log_dir() {
    if [[ -f "$RN_HOST_NGINX_ROTATE_FILE" ]]; then
        # Do not share paths with a native nginx or its distribution logrotate policy.
        printf '%s/nginx\n' "$RN_LOG_DIR"
    else
        printf '%s\n' "$RN_NGINX_LOG_DIR"
    fi
}

rn_prepare_log_paths() {
    local nginx_log_dir="$1" dir path
    for dir in "$RN_LOG_DIR" "$RN_LOG_DIR/xray" "$nginx_log_dir"; do
        if [[ -L "$dir" ]]; then
            rn_log "${ERROR_T} Не использую симлинк в качестве каталога логов: $dir"
            return 1
        fi
        if [[ ! -d "$dir" ]]; then install -d -m 0755 "$dir" || return 1; fi
    done
    for path in "$RN_LOG_DIR"/{access,error}.log "$nginx_log_dir"/{access,error}.log; do
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            rn_log "${ERROR_T} Ожидался обычный файл лога: $path"
            return 1
        fi
        if [[ ! -f "$path" ]]; then (umask 027; set -o noclobber; : > "$path") || return 1; fi
    done
}

rn_enable_logrotate_scheduler() {
    if [[ -d /run/systemd/system ]]; then
        systemctl is-active --quiet logrotate.timer || systemctl enable --now logrotate.timer >> "$RN_LOG_FILE" 2>&1
    elif [[ -x /etc/cron.daily/logrotate ]] && command -v cron >/dev/null; then
        rn_log "${INFO_T} Используется cron.daily/logrotate; убедитесь, что cron запущен."
    else
        rn_log "${ERROR_T} Не найден logrotate.timer или cron.daily/logrotate. Включите системный планировщик ротации."
        return 1
    fi
}

rn_setup_logging_and_rotation() (
    local nginx_log_dir="$1" tmp
    tmp=$(mktemp "$(dirname "$RN_LOGROTATE_FILE")/.remnanode-rotate.XXXXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    cat > "$tmp" <<EOF || return 1
$RN_LOG_DIR/access.log $RN_LOG_DIR/error.log {
    daily
    maxsize 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

$nginx_log_dir/access.log $nginx_log_dir/error.log {
    daily
    maxsize 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        if [ "\$(docker inspect --format '{{.State.Running}}' remnawave-nginx 2>/dev/null)" = true ]; then
            docker kill --signal=USR1 remnawave-nginx >/dev/null
        fi
    endscript
}
EOF
    if ! logrotate -d -s /dev/null "$tmp" >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${ERROR_T} Проверка logrotate не прошла. См. $RN_LOG_FILE."
        return 1
    fi
    if ! rn_enable_logrotate_scheduler; then
        rn_log "${ERROR_T} Не удалось включить планировщик logrotate. См. $RN_LOG_FILE."
        return 1
    fi
    if [[ ! -f "$RN_LOGROTATE_FILE" ]] || ! cmp -s -- "$tmp" "$RN_LOGROTATE_FILE"; then
        chmod 0644 "$tmp" && mv -fT -- "$tmp" "$RN_LOGROTATE_FILE" || return 1
    fi
    rn_log "${SUCCESS_T} Логи на хосте: $RN_LOG_DIR и $nginx_log_dir. Настроен logrotate."
)

# --- Развертывание Docker Compose ---
rn_deploy_compose() (
    umask 077
    local protocol="$1"
    local node_port="$2"
    local secret_key="$3" domain="${4:-}" template="${5:-status}" requested_alias="${6:-}"
    local transport_plan="${7:-}"

    local stage xray_dir config cert_dir="$RN_CERTS_DIR" live_cert_dir="" nginx_log_dir
    local cert_path_domain="" cert_path_override="" saved_alias="" candidate=""
    local bind_type=files
    local nginx_tls_prefix=/etc/nginx/ssl nginx_tls_cert=snakeoil.pem nginx_tls_key=snakeoil.key
    local node_cert_volumes="" nginx_cert_volumes=""
    rn_valid_port "$node_port" && [[ -n "$secret_key" && "$secret_key" != *$'\n'* && "$secret_key" != *$'\r'* ]] || return 1
    case "$protocol" in reality|xhttp|tls|combined) ;; *) return 1 ;; esac
    local -a validated_ports=()
    if [[ "$protocol" == reality ]]; then rn_valid_reality_sni "$RN_DECOY_DOMAIN" || return 1; fi
    if [[ -n "$domain" ]]; then
        rn_valid_domain "$domain" || return 1
        live_cert_dir="/etc/letsencrypt/live/$domain"
        if [[ -d "$RN_CERTS_DIR/managed/$domain" ]]; then
            cert_dir="$RN_CERTS_DIR/managed/$domain"
            bind_type=directory
        fi
    fi
    if [[ -n "$requested_alias" ]]; then
        if ! rn_valid_cert_path_domain "$domain" "$requested_alias"; then
            rn_log "${ERROR_T} Укажите имя ноды или её DNS-зону, без URL, Markdown и путей."
            return 1
        fi
        cert_path_override="${requested_alias,,}"
    elif [[ -r "$RN_APP_DIR/.cert_path_domain" ]]; then
        IFS= read -r saved_alias < "$RN_APP_DIR/.cert_path_domain" || return 1
        if rn_valid_cert_path_domain "$domain" "$saved_alias"; then cert_path_override="$saved_alias"; fi
    fi
    cert_path_domain="$cert_path_override"
    if [[ -z "$cert_path_domain" && -r "$cert_dir/.wildcard_zone" ]]; then
        IFS= read -r candidate < "$cert_dir/.wildcard_zone" || return 1
        if rn_valid_cert_path_domain "$domain" "$candidate"; then cert_path_domain="$candidate"; fi
    fi
    if [[ "$protocol" != reality ]]; then
        if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/privkey.pem" ]]; then
            rn_log "${ERROR_T} Не найдена полная пара сертификата на хосте: $cert_dir/{fullchain.pem,privkey.pem}. Compose не изменён."
            return 1
        fi
        if ! rn_cert_key_matches "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem"; then
            rn_log "${ERROR_T} Ключ не соответствует сертификату в $cert_dir или файлы повреждены. Compose не изменён."
            return 1
        fi
        if [[ -n "$domain" ]] && ! rn_cert_covers_host "$cert_dir/fullchain.pem" "$domain"; then
            rn_log "${ERROR_T} Сертификат $cert_dir/fullchain.pem не покрывает $domain. Compose не изменён."
            return 1
        fi
        rn_log "${INFO_T} Сертификат ноды на хосте: $cert_dir/fullchain.pem; ключ: $cert_dir/privkey.pem."
    fi
    mkdir -p "$RN_APP_DIR" || return 1
    [[ -f "$RN_WWW_DIR/index.html" ]] || rn_render_page_template "$template" || return 1
    cd "$RN_APP_DIR" || return 1
    exec 9>"$RN_APP_DIR/.deploy.lock" || return 1
    flock -w 30 9 || return 1
    if [[ "$protocol" == combined ]]; then
        if [[ -z "$transport_plan" && -f "$RN_APP_DIR/.transport_ports" ]]; then
            transport_plan=$(cat "$RN_APP_DIR/.transport_ports") || return 1
        fi
        if ! rn_read_transport_plan validated_ports "$transport_plan" "$node_port"; then
            rn_log "${ERROR_T} Для режима трёх транспортов нужен корректный список портов."
            return 1
        fi
    elif [[ -n "$transport_plan" ]]; then
        return 1
    fi
    stage=$(mktemp -d "$RN_APP_DIR/.deploy.XXXXXXXX") || return 1
    config="${stage}/docker-compose.yml"
    trap 'rm -rf -- "$stage"' EXIT

    if [[ "$RN_XRAY_VERSION_CHOICE" == legacy ]]; then
        xray_dir="$RN_XRAY_BIN_DIR"
    elif [[ "$RN_XRAY_VERSION_CHOICE" != built-in ]]; then
        rn_valid_xray_tag "$RN_XRAY_VERSION_CHOICE" || return 1
        xray_dir="$RN_XRAY_BIN_DIR/$RN_XRAY_VERSION_CHOICE"
    fi
    if [[ -n "${xray_dir:-}" && ! -x "$xray_dir/xray" ]]; then
        rn_log "${ERROR_T} Кастомный Xray не найден: $xray_dir/xray"
        return 1
    fi

    cat > "$stage/.env" <<EOF || return 1
### REMNANODE CONFIG ###
NODE_PORT=$node_port
SECRET_KEY=$secret_key
XTLS_API_PORT=61000
EOF

    nginx_log_dir=$(rn_nginx_log_dir) || return 1
    rn_prepare_log_paths "$nginx_log_dir" || return 1
    if [[ "$protocol" != reality ]]; then
        node_cert_volumes=$(rn_cert_volume_lines "$cert_dir" /etc/xray/certs "$bind_type") || return 1
    fi
    if [[ -n "$live_cert_dir" && -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
        nginx_cert_volumes=$(rn_cert_volume_lines "$cert_dir" "$live_cert_dir" "$bind_type") || return 1
        local tls_live_path="$live_cert_dir" alias_volumes
        if [[ -n "$cert_path_domain" && "$cert_path_domain" != "$domain" ]]; then
            tls_live_path="/etc/letsencrypt/live/$cert_path_domain"
            alias_volumes=$(rn_cert_volume_lines "$cert_dir" "$tls_live_path" "$bind_type") || return 1
            nginx_cert_volumes+=$'\n'"$alias_volumes"
        fi
        if [[ -n "$node_cert_volumes" ]]; then node_cert_volumes+=$'\n'; fi
        node_cert_volumes+="$nginx_cert_volumes"
        rn_log "${INFO_T} Путь к сертификату в контейнере: $tls_live_path/fullchain.pem."
        if [[ "$protocol" == reality ]] && rn_cert_covers_host "$cert_dir/fullchain.pem" "$RN_DECOY_DOMAIN" &&
            rn_cert_key_matches "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem"; then
            nginx_tls_prefix="$tls_live_path"
            nginx_tls_cert=fullchain.pem
            nginx_tls_key=privkey.pem
        fi
    fi

    local snakeoil_cert="$RN_CERTS_DIR/snakeoil.pem"
    local snakeoil_key="$RN_CERTS_DIR/snakeoil.key"
    if [[ "$protocol" == reality && "$nginx_tls_cert" == snakeoil.pem ]] && { [[ ! -s "$snakeoil_cert" || ! -s "$snakeoil_key" ]]; }; then
        mkdir -p "$RN_CERTS_DIR" || return 1
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$snakeoil_key" \
            -out "$snakeoil_cert" \
            -subj "/CN=localhost" >> "$RN_LOG_FILE" 2>&1 || return 1
        chmod 600 "$snakeoil_key" "$snakeoil_cert" || return 1
    fi

    if [[ "$protocol" == reality && "$nginx_tls_cert" == snakeoil.pem ]]; then
        if [[ -n "$nginx_cert_volumes" ]]; then nginx_cert_volumes+=$'\n'; fi
        printf -v nginx_cert_volumes '%s      - %s:%s/snakeoil.pem:ro\n      - %s:%s/snakeoil.key:ro' "$nginx_cert_volumes" "$snakeoil_cert" "$nginx_tls_prefix" "$snakeoil_key" "$nginx_tls_prefix"
    fi

    cat > "$config" <<EOF || return 1
services:
  remnanode:
    image: ghcr.io/remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    env_file:
      - .env
    logging:
      driver: local
      options:
        max-size: "20m"
        max-file: "5"
    volumes:
      - /dev/shm:/dev/shm:rw
      - $RN_LOG_DIR:/var/log/remnanode
      - $RN_LOG_DIR/xray:/var/log/xray
$node_cert_volumes
$( [[ -n "${xray_dir:-}" ]] && echo "      - $xray_dir/xray:/usr/local/bin/xray:ro" )
$( [[ -n "${xray_dir:-}" && -f "$xray_dir/geoip.dat" ]] && echo "      - $xray_dir/geoip.dat:/usr/local/share/xray/geoip.dat:ro" )
$( [[ -n "${xray_dir:-}" && -f "$xray_dir/geosite.dat" ]] && echo "      - $xray_dir/geosite.dat:/usr/local/share/xray/geosite.dat:ro" )

  remnawave-nginx:
    image: nginx:1.31
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - $RN_WWW_DIR:/var/www/html:ro
      - $nginx_log_dir:/var/log/nginx
$nginx_cert_volumes
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

    if [ "$protocol" = "reality" ]; then
        cat > "$stage/nginx.conf" <<EOF || return 1
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $RN_DECOY_DOMAIN;
    ssl_certificate "$nginx_tls_prefix/$nginx_tls_cert";
    ssl_certificate_key "$nginx_tls_prefix/$nginx_tls_key";

    root /var/www/html;
    index index.html;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    else
        cat > "$stage/nginx.conf" <<EOF || return 1
server {
    listen unix:/dev/shm/nginx.sock proxy_protocol default_server;
    server_name _;

    root /var/www/html;
    index index.html;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    local hash file rc=0 rollback_rc=0
    hash=$(sha256sum "$stage/nginx.conf") || return 1
    sed -i "/^    container_name: remnawave-nginx$/a\\    labels: { io.safe-remnanode.nginx-config: \"${hash%% *}\" }" "$config" || return 1
    # Stage relative paths independently; keep the live files untouched until the check passes.
    docker compose --project-directory "$stage" --env-file "$stage/.env" -f "$config" config --quiet >> "$RN_LOG_FILE" 2>&1 || {
        rn_log "${ERROR_T} Проверка новой Compose-конфигурации не прошла. Старая не изменена."
        return 1
    }
    rn_setup_logging_and_rotation "$nginx_log_dir" || return 1
    mkdir "$stage/previous" || return 1
    local -a files=(.env nginx.conf docker-compose.yml .xray_version .decoy_domain .protocol .cert_path_domain)
    printf '%s\n' "$cert_path_override" > "$stage/.cert_path_domain" || return 1
    printf '%s\n' "$protocol" > "$stage/.protocol" || return 1
    if [[ "$protocol" == combined ]]; then
        rn_format_transport_plan "${validated_ports[@]}" > "$stage/.transport_ports" || return 1
        files+=(.transport_ports)
    fi
    if [[ -n "$domain" ]]; then
        printf '%s\n' "$domain" > "$stage/.node_domain" || return 1
        files+=(.node_domain)
    fi
    printf '%s\n' "$RN_XRAY_VERSION_CHOICE" > "$stage/.xray_version" || return 1
    printf '%s\n' "$RN_DECOY_DOMAIN" > "$stage/.decoy_domain" || return 1
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then cp -p -- "$file" "$stage/previous/$file" || return 1; fi
    done
    for file in "${files[@]}"; do
        if [[ -f "$file" ]] && cmp -s -- "$stage/$file" "$file"; then continue; fi
        mv -fT -- "$stage/$file" "$file" || { rc=1; break; }
    done
    if (( rc == 0 )) && chmod 0600 .env && docker compose up -d --wait --wait-timeout 60 >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${SUCCESS_T} Compose запущен; выполнены доступные healthcheck."
        return 0
    fi
    rn_log "${ERROR_T} Новая ревизия не запущена. Восстанавливаю предыдущие конфиги."
    if [[ ! -f "$stage/previous/docker-compose.yml" && -f docker-compose.yml ]]; then
        docker compose down >> "$RN_LOG_FILE" 2>&1 || rollback_rc=1
    fi
    for file in "${files[@]}"; do
        if [[ -f "$stage/previous/$file" ]]; then
            if ! cmp -s -- "$stage/previous/$file" "$file"; then
                cp -p -- "$stage/previous/$file" "$stage/$file.restore" &&
                    mv -fT -- "$stage/$file.restore" "$file" || rollback_rc=1
            fi
        else
            rm -f -- "$file" || rollback_rc=1
        fi
    done
    if [[ -f "$stage/previous/docker-compose.yml" ]]; then
        docker compose up -d --wait --wait-timeout 60 >> "$RN_LOG_FILE" 2>&1 || rollback_rc=1
    fi
    if (( rollback_rc )); then
        trap - EXIT
        rn_log "${ERROR_T} Откат неполный; резервные копии: $stage/previous"
    fi
    return 1
)

rn_apply_node_logging() {
    local requested_alias="${1:-}"
    (( $# <= 1 )) || return 1
    if [[ ! -f "$RN_APP_DIR/docker-compose.yml" || ! -f "$RN_APP_DIR/.protocol" || ! -f "$RN_APP_DIR/.env" ]]; then
        rn_log "${ERROR_T} Не найден деплой, созданный установщиком."
        return 1
    fi
    rn_load_node_state || return 1
    local node_port secret protocol domain
    node_port=$(sed -n 's/^NODE_PORT=//p' "$RN_APP_DIR/.env") || return 1
    secret=$(sed -n 's/^SECRET_KEY=//p' "$RN_APP_DIR/.env") || return 1
    IFS= read -r protocol < "$RN_APP_DIR/.protocol" || return 1
    domain=$(cat "$RN_APP_DIR/.node_domain" 2>/dev/null || true)
    local backup f
    install -d -m 0700 "$BACKUP_DIR" || return 1
    backup=$(mktemp -d "$BACKUP_DIR/node-logs.XXXXXXXX") || return 1
    for f in .env docker-compose.yml nginx.conf .cert_path_domain; do
        if [[ -f "$RN_APP_DIR/$f" ]]; then cp -p -- "$RN_APP_DIR/$f" "$backup/$f" || return 1; fi
    done
    rn_log "${INFO_T} Предыдущие конфигурации сохранены в $backup."
    rn_log "${INFO_T} Подключение журналов к текущей ноде. Конфигурации Compose и nginx будут пересозданы из настроек установщика."
    rn_deploy_compose "$protocol" "$node_port" "$secret" "$domain" status "$requested_alias"
}
