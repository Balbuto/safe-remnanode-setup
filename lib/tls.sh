#!/usr/bin/env bash
# ACME rejects an exact SAN when another SAN in the order already covers it.
rn_build_acme_names() {
    local hostname="${1,,}" zone="${2,,}" relative
    local -n acme_args="$3"
    rn_valid_domain "$hostname" || return 1
    if [[ -z "$zone" ]]; then
        acme_args=(-d "$hostname")
        return 0
    fi
    rn_valid_domain "$zone" && [[ "$hostname" == "$zone" || "$hostname" == *".$zone" ]] || return 1
    acme_args=(-d "$zone" -d "*.$zone")
    if [[ "$hostname" != "$zone" ]]; then
        relative="${hostname%".$zone"}"
        # A wildcard covers only one label, so deeper descendants need their own SAN.
        if [[ "$relative" == *.* ]]; then acme_args+=(-d "$hostname"); fi
    fi
}

# --- Универсальный выпуск SSL (Cloudflare DNS / Standalone / Gcore DNS) ---
rn_issue_ssl_certificates_multi() (
    umask 077
    local domain="$1" deploy_mode="${2:-}" deployment_ports="${3:-}"

    echo -e "\n${BLUE}🔐 ВЫБОР МЕТОДА ВЫПУСКА SSL СЕРТИФИКАТА${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo " 1) Cloudflare API (DNS-01, с поддержкой wildcard *.домен)"
    echo " 2) Certbot Standalone (HTTP-01, проверка по 80 порту - стандартно)"
    echo " 3) Gcore DNS API (DNS-01, с поддержкой wildcard *.домен)"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -r -p "Выберите метод выпуска [2]: " ssl_method
    ssl_method=${ssl_method:-2}

    local cert_name="safe-remnanode-$domain" base_domain=""
    local -a names=()
    if [[ "$ssl_method" == 1 || "$ssl_method" == 3 ]]; then
        read -r -p "Зона для wildcard (Enter: сертификат только для $domain): " base_domain || return 1
    fi
    rn_build_acme_names "$domain" "$base_domain" names || {
        rn_log "${ERROR_T} Некорректное имя ноды или DNS-зона не соответствует имени."
        return 1
    }
    rn_log "${INFO_T} Имена в запросе Certbot: ${names[*]}"

    read -r -p "Введите ваш email для Let's Encrypt: " le_email
    while [ -z "$le_email" ]; do
        read -r -p "${RED}Email обязателен для получения SSL: ${NC}" le_email
    done

    mkdir -p "$RN_CERTS_DIR"

    case $ssl_method in
        1)
            rn_log "${INFO_T} Подготовка к выпуску сертификата через Cloudflare API (DNS-01)..."
            apt_install python3-certbot-dns-cloudflare || return 1

            echo -e "\nВыберите метод авторизации Cloudflare:"
            echo " 1) Через API Token (Рекомендуется, более безопасно)"
            echo " 2) Через Global API Key (Устаревший метод)"
            read -r -p "Ваш выбор [1]: " cf_auth_method
            cf_auth_method=${cf_auth_method:-1}

            mkdir -p ~/.secrets/certbot

            if [ "$cf_auth_method" -eq 1 ]; then
                read -rs -p "Введите ваш Cloudflare API Token: " cf_token || return 1
                printf '\n'
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $cf_token
EOL
            else
                read -r -p "Введите ваш Cloudflare Email: " cf_email
                read -rs -p "Введите ваш Global API Key: " cf_key || return 1
                printf '\n'
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $cf_email
dns_cloudflare_api_key = $cf_key
EOL
            fi

            chmod 600 ~/.secrets/certbot/cloudflare.ini

            rn_log "${INFO_T} Запуск выпуска DNS-01 сертификата для $domain..."
            if certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                --cert-name "$cert_name" "${names[@]}" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                rn_log "${SUCCESS_T} SSL-сертификат успешно выпущен через Cloudflare DNS!"
            else
                rn_log "${ERROR_T} Ошибка выпуска сертификата через Cloudflare API! Проверьте лог $RN_LOG_FILE"
                return 1
            fi
            ;;

        2)
            rn_log "${INFO_T} Выпуск сертификата в Standalone режиме (HTTP-01)..."

            local listeners
            listeners=$(ss -H -ltn 'sport = :80') || return 1
            if [[ -n "$listeners" ]]; then
                rn_log "${ERROR_T} Порт 80 занят. Используйте DNS-01 или освободите его вручную. Службы не остановлены."
                return 1
            fi

            if [[ "$deploy_mode" == combined ]]; then
                if [[ -z "$deployment_ports" && -r "$RN_APP_DIR/.transport_ports" ]]; then
                    deployment_ports=$(cat "$RN_APP_DIR/.transport_ports") || return 1
                fi
                if grep -Eq '^(TLS_TCP|XHTTP_TCP)=80$' <<< "$deployment_ports"; then
                    rn_log "${ERROR_T} В профиле Xray задан TCP/80: Standalone не сможет продлевать сертификат после запуска ноды. Используйте DNS-01."
                    return 1
                fi
                rn_log "${INFO_T} Standalone требует TCP/80 для выпуска и последующего продления; добавляю отдельное правило UFW."
                rn_check_ufw_ready && rn_ufw_allow 80/tcp comment 'HTTP / Certbot' || return 1
            fi

            if certbot certonly \
                --standalone \
                --cert-name "$cert_name" "${names[@]}" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                rn_log "${SUCCESS_T} SSL сертификат успешно выпущен в Standalone режиме!"
            else
                rn_log "${ERROR_T} Не удалось выпустить SSL сертификат! Ознакомьтесь с логом $RN_LOG_FILE"
                return 1
            fi
            ;;

        3)
            rn_log "${INFO_T} Подготовка к выпуску сертификата через Gcore DNS API (DNS-01)..."

            if ! certbot plugins 2>/dev/null | grep "dns-gcore" >/dev/null; then
                rn_log "${ERROR_T} Установите совместимый плагин dns-gcore в окружение Certbot и повторите."
                return 1
            fi

            read -rs -p "Введите ваш Gcore API Token: " gcore_token || return 1
            printf '\n'

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $gcore_token
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            rn_log "${INFO_T} Запуск выпуска DNS-01 сертификата для $domain через Gcore..."
            if certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                --cert-name "$cert_name" "${names[@]}" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                rn_log "${SUCCESS_T} SSL-сертификат успешно выпущен через Gcore DNS!"
            else
                rn_log "${ERROR_T} Ошибка выпуска сертификата через Gcore API! Проверьте лог $RN_LOG_FILE"
                return 1
            fi
            ;;
        *)
            rn_log "${ERROR_T} Выбран неверный метод."
            return 1
            ;;
    esac

    local renew_hook_file="$RN_RENEW_HOOK"
    local lineage="/etc/letsencrypt/live/$cert_name"
    local target="$RN_CERTS_DIR/managed/$domain" tmp
    mkdir -p "$target" "$(dirname "$renew_hook_file")" || return 1
    tmp=$(mktemp -d "$target/.deploy.XXXXXXXX") || return 1
    trap 'rm -rf -- "$tmp" "${hook_tmp:-}"' EXIT
    install -m 0644 "$lineage/fullchain.pem" "$tmp/fullchain.pem" || return 1
    install -m 0600 "$lineage/privkey.pem" "$tmp/privkey.pem" || return 1
    mv -fT "$tmp/fullchain.pem" "$target/fullchain.pem" &&
        mv -fT "$tmp/privkey.pem" "$target/privkey.pem" || return 1

    if [[ -n "$base_domain" ]]; then
        printf '%s\n' "${base_domain,,}" > "$tmp/.wildcard_zone" && mv -fT "$tmp/.wildcard_zone" "$target/.wildcard_zone" || return 1
    else
        rm -f -- "$target/.wildcard_zone" || return 1
    fi

    local hook_tmp
    hook_tmp=$(mktemp "$(dirname "$renew_hook_file")/.remnanode-hook.XXXXXXXX") || return 1
    if [[ ! -f "$renew_hook_file" || $(head -n 2 "$renew_hook_file" | tail -n 1) == '# safe-remnanode managed certificate hook' ]]; then
        cat > "$hook_tmp" <<'EOF' || return 1
#!/bin/bash
# safe-remnanode managed certificate hook
set -euo pipefail
umask 077
app=/opt/remnanode
[[ -r "$app/.node_domain" ]] || exit 0
IFS= read -r domain < "$app/.node_domain"
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" != '.' && "$domain" != '..' ]] || exit 1
[[ ${RENEWED_LINEAGE:-} == "/etc/letsencrypt/live/safe-remnanode-$domain" ]] || exit 0
certs="$app/certs/managed/$domain"
[[ -d "$certs" ]] || exit 0
tmp=$(mktemp -d "$certs/.renew.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$tmp/fullchain.pem"
install -m 0600 "$RENEWED_LINEAGE/privkey.pem" "$tmp/privkey.pem"
mv -fT "$tmp/fullchain.pem" "$certs/fullchain.pem"
mv -fT "$tmp/privkey.pem" "$certs/privkey.pem"
docker restart remnanode
if [[ -f "$app/nginx.conf" ]] &&
   grep -Eq '^[[:space:]]*ssl_certificate[[:space:]]+"?/etc/letsencrypt/live/' "$app/nginx.conf" &&
   [[ $(docker inspect --format '{{.State.Running}}' remnawave-nginx 2>/dev/null) == true ]]; then
    docker kill --signal=HUP remnawave-nginx >/dev/null
fi
EOF
        chmod 0700 "$hook_tmp" && mv -fT "$hook_tmp" "$renew_hook_file" || return 1
    else
        rn_log "${WARNING_T} Путь к новому Certbot hook уже занят сторонним скриптом. Файл оставлен без изменений."
        return 1
    fi
)

rn_valid_cert_path_domain() {
    local hostname="${1,,}" alias_name="${2,,}"
    rn_valid_domain "$hostname" && rn_valid_domain "$alias_name" &&
        [[ "$hostname" == "$alias_name" || "$hostname" == *".$alias_name" ]]
}

rn_cert_volume_lines() {
    local source_dir="$1" dest_dir="$2" type="$3"
    if [[ "$type" == directory ]]; then
        printf '      - %s:%s:ro\n' "$source_dir" "$dest_dir"
    else
        printf '      - %s/fullchain.pem:%s/fullchain.pem:ro\n      - %s/privkey.pem:%s/privkey.pem:ro\n' "$source_dir" "$dest_dir" "$source_dir" "$dest_dir"
    fi
}

rn_cert_covers_host() {
    LC_ALL=C openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null | grep -F 'does match certificate' >/dev/null
}

rn_cert_key_matches() {
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$2" -passin pass: -pubout 2>/dev/null) || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}
