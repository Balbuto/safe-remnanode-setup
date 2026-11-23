#!/usr/bin/env bash
rn_validate_transport_ports() {
    local control_port="$1" tls_tcp="$2" xhttp="$3" hy2_udp="$4" port
    local xhttp_port="${xhttp%/*}" xhttp_proto=tcp
    if [[ "$xhttp" == */* ]]; then xhttp_proto="${xhttp##*/}"; fi
    [[ "$xhttp_proto" == tcp || "$xhttp_proto" == udp ]] || return 1
    rn_valid_port "$control_port" || return 1
    for port in "$tls_tcp" "$xhttp_port" "$hy2_udp"; do
        rn_valid_port "$port" && [[ "$port" != "$control_port" && "$port" != 61000 ]] || return 1
    done
    case "$xhttp_proto" in
        tcp) [[ "$xhttp_port" != "$tls_tcp" ]] ;;
        udp) [[ "$xhttp_port" != "$hy2_udp" ]] ;;
    esac
}

rn_read_transport_plan() {
    local -n parsed="$1"
    local payload="$2" control_port="$3"
    local -a entries=()
    mapfile -t entries <<< "$payload"
    [[ ${#entries[@]} -eq 3 && "${entries[0]}" == TLS_TCP=* && "${entries[2]}" == HY2_UDP=* ]] || return 1
    local xhttp_proto
    case "${entries[1]}" in
        XHTTP_TCP=*) xhttp_proto=tcp ;;
        XHTTP_UDP=*) xhttp_proto=udp ;;
        *) return 1 ;;
    esac
    local -a values=("${entries[0]#*=}" "${entries[1]#*=}/$xhttp_proto" "${entries[2]#*=}")
    rn_validate_transport_ports "$control_port" "${values[@]}" || return 1
    # shellcheck disable=SC2034 # Assignment to the caller via nameref.
    parsed=("${values[@]}")
}

rn_format_transport_plan() {
    local xhttp="$2" xhttp_port="${2%/*}" xhttp_proto=tcp
    if [[ "$xhttp" == */* ]]; then xhttp_proto="${xhttp##*/}"; fi
    printf 'TLS_TCP=%s\nXHTTP_%s=%s\nHY2_UDP=%s\n' "$1" "${xhttp_proto^^}" "$xhttp_port" "$3"
}

rn_check_transport_ports() {
    local control_port plan listeners failed=0 i
    local -a saved_ports=() labels=('VLESS+TLS' 'VLESS+xHTTP+TLS' 'Hy2') protos=(tcp tcp udp) ss_flags=(-Hltnp -Hltnp -Hlunp)
    if [[ ! -r "$RN_APP_DIR/.transport_ports" || ! -r "$RN_APP_DIR/.env" ]]; then
        printf '%s\n' 'Не сохранены порты трёх транспортов. Проверьте профиль в панели и задайте порты через node-transports.' >&2
        return 1
    fi
    control_port=$(sed -n 's/^NODE_PORT=//p' "$RN_APP_DIR/.env") || return 1
    plan=$(cat "$RN_APP_DIR/.transport_ports") || return 1
    if ! rn_read_transport_plan saved_ports "$plan" "$control_port"; then
        printf '%s\n' 'Некорректная конфигурация .transport_ports.' >&2
        return 1
    fi
    if [[ "${saved_ports[1]}" == */udp ]]; then
        protos[1]=udp
        ss_flags[1]=-Hlunp
    fi
    saved_ports[1]="${saved_ports[1]%/*}"
    for i in "${!saved_ports[@]}"; do
        if ! listeners=$(ss "${ss_flags[i]}" "sport = :${saved_ports[i]}"); then return 1; fi
        if [[ -z "$listeners" ]]; then
            printf '%s %s/%s: слушателя нет\n' "${labels[i]}" "${saved_ports[i]}" "${protos[i]}"
            failed=1
        elif [[ "$listeners" == *'"rw-core"'* || "$listeners" == *'"xray"'* ]]; then
            printf '%s %s/%s: слушает Xray\n' "${labels[i]}" "${saved_ports[i]}" "${protos[i]}"
        else
            printf '%s %s/%s: порт занят, процесс Xray не подтверждён\n' "${labels[i]}" "${saved_ports[i]}" "${protos[i]}"
            failed=1
        fi
    done
    return "$failed"
}

# --- Фаервол (UFW) для ноды ---
rn_check_ufw_ready() {
    local status
    if ! command -v ufw >/dev/null; then
        rn_log "${ERROR_T} UFW не установлен. Установите пакет ufw и настройте доступ SSH до включения firewall."
        return 1
    fi
    if ! status=$(LC_ALL=C ufw status verbose 2>>"$RN_LOG_FILE"); then
        rn_log "${ERROR_T} Не удалось прочитать статус UFW. Проверьте sudo ufw status verbose и журнал: $RN_LOG_FILE"
        return 1
    fi
    rn_require_active_ufw "$status"
}

rn_require_active_ufw() {
    local status="$1"
    if [[ "$status" != 'Status: active'* ]]; then
        rn_log "${ERROR_T} UFW не активен. Правила не менялись."
        rn_log "${INFO_T} Перед включением UFW разрешите фактический TCP-порт SSH, проверьте имеющиеся правила и доступ через консоль VPS. Затем повторите установку."
        return 1
    fi
    if [[ "$status" != *'Default: deny (incoming)'* && "$status" != *'Default: reject (incoming)'* ]]; then
        rn_log "${ERROR_T} UFW не запрещает входящие подключения по умолчанию. Проверьте доступ SSH и настройте политику вручную. Правила не менялись."
        return 1
    fi
}

# Use the server-side port of the current SSH session, or a unique sshd listener.
# sudo may strip SSH_CONNECTION; never fall back to port 22 by guesswork.
rn_ssh_port_for_ufw() {
    local listeners local_address port line from_ip remote_port to_ip session_port extra choice
    local -A listening=() ssh_ports=()
    if ! listeners=$(LC_ALL=C ss -Hltnp 2>>"$RN_LOG_FILE"); then
        printf '%s\n' 'Не удалось прочитать TCP-слушатели (ss из iproute2). UFW не будет включён.' >&2
        return 1
    fi
    while IFS= read -r line; do
        local_address=$(awk '{print $4}' <<< "$line")
        case "$local_address" in 127.*|\[::1\]:*) continue ;; esac
        port="${local_address##*:}"
        rn_valid_port "$port" || continue
        listening[$port]=1
        case "$line" in
            *'("sshd",'*|*'("sshd-session",'*|*'("dropbear",'*) ssh_ports[$port]=1 ;;
        esac
    done <<< "$listeners"
    IFS=' ' read -r from_ip remote_port to_ip session_port extra <<< "${SSH_CONNECTION:-}"
    if [[ -n "$from_ip" && -n "$to_ip" && -z "$extra" ]] && rn_valid_port "$remote_port" &&
        rn_valid_port "$session_port" && [[ -n "${listening[$session_port]:-}" ]]; then
        printf '%s\n' "$session_port"
        return 0
    fi
    if (( ${#ssh_ports[@]} == 1 )); then
        printf '%s\n' "${!ssh_ports[@]}"
        return 0
    fi
    printf '%s' 'Не удалось однозначно определить порт SSH. Укажите фактический TCP-порт SSH или нажмите Enter для отмены: ' >&2
    if IFS= read -r choice && rn_valid_port "$choice" && [[ -n "${listening[$choice]:-}" ]]; then
        printf '%s\n' "$choice"
        return 0
    fi
    printf '\n%s\n' 'Порт SSH не подтверждён. UFW не будет включён. Проверьте SSH через консоль VPS.' >&2
    return 1
}

# Parse just the requested setting; never source firewall configuration.
rn_ufw_default() {
    awk -F= -v key="$1" '
        NF == 2 {
            k=$1; gsub(/[[:space:]]/, "", k)
            if (k == key) { v=$2; sub(/#.*/, "", v); gsub(/[[:space:]"\047]/, "", v); result=v }
        }
        END { print result }
    ' "$RN_UFW_DEFAULTS_FILE"
}

rn_prepare_ufw_initial() {
    local status='Status: inactive' ssh_port defaults saved_rules
    if [[ -e "$RN_APP_DIR/docker-compose.yml" ]]; then
        rn_check_ufw_ready
        return $?
    fi
    if command -v ufw >/dev/null; then
        status=$(LC_ALL=C ufw status verbose 2>>"$RN_LOG_FILE") || {
            rn_log "${ERROR_T} Не удалось прочитать статус UFW. Правила не менялись."
            return 1
        }
    fi
    if [[ "$status" != 'Status: inactive'* ]]; then
        rn_require_active_ufw "$status"
        return $?
    fi

    ssh_port=$(rn_ssh_port_for_ufw) || return 1
    if ! command -v ufw >/dev/null; then
        rn_log "${INFO_T} Устанавливаю UFW перед настройкой ноды."
        apt_update && apt_install ufw || return 1
        status=$(LC_ALL=C ufw status verbose 2>>"$RN_LOG_FILE") || return 1
        if [[ "$status" != 'Status: inactive'* ]]; then
            rn_require_active_ufw "$status"
            return $?
        fi
    fi
    defaults=$(rn_ufw_default DEFAULT_INPUT_POLICY 2>>"$RN_LOG_FILE") || return 1
    case "$defaults" in
        DROP|REJECT) ;;
        *) rn_log "${ERROR_T} UFW не включён: сначала проверьте политику входящих (нужен DROP или REJECT)."; return 1 ;;
    esac
    local current_ssh="${SSH_CONNECTION:-}" ipv6 ipv6_listeners=""
    ipv6=$(rn_ufw_default IPV6 2>>"$RN_LOG_FILE") || return 1
    if [[ "$ipv6" != yes ]]; then
        if [[ -z "$current_ssh" ]]; then
            ipv6_listeners=$(LC_ALL=C ss -H -ltn -6 "sport = :$ssh_port" 2>>"$RN_LOG_FILE") || return 1
        fi
        if [[ "${current_ssh%% *}" == *:* || -n "$ipv6_listeners" ]]; then
            rn_log "${ERROR_T} UFW не включён: SSH может использовать IPv6, а его поддержка в UFW не подтверждена. Используйте консоль VPS."
            return 1
        fi
    fi
    saved_rules=$(LC_ALL=C ufw show added 2>>"$RN_LOG_FILE") || return 1
    if grep -Eq '^ufw (deny|reject|limit)( |$)' <<< "$saved_rules"; then
        rn_log "${ERROR_T} UFW не включён: уже есть правила deny/reject/limit, которые могут влиять на SSH. Проверьте их вручную через консоль VPS."
        return 1
    fi
    rn_log "${INFO_T} UFW неактивен: разрешаю SSH ($ssh_port/tcp) перед включением."
    if ! LC_ALL=C ufw prepend allow "$ssh_port/tcp" comment 'SSH (initial setup)' >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${ERROR_T} Не удалось добавить правило SSH. UFW не включён; см. $RN_LOG_FILE."
        return 1
    fi
    saved_rules=$(LC_ALL=C ufw show added 2>>"$RN_LOG_FILE") || return 1
    if ! grep -Eq "^ufw allow $ssh_port/tcp( |$)" <<< "$saved_rules"; then
        rn_log "${ERROR_T} Правило SSH не найдено среди сохранённых правил. UFW не включён."
        return 1
    fi
    if ! LC_ALL=C ufw --force enable >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${ERROR_T} Не удалось включить UFW. Правило SSH могло сохраниться; проверьте состояние и $RN_LOG_FILE."
        return 1
    fi
    rn_check_ufw_ready || return 1
    rn_log "${SUCCESS_T} UFW активен. Прежде чем закрывать текущую SSH-сессию, проверьте вход во второй."
}

rn_ufw_allow() {
    local preview line unchanged=0
    if ! preview=$(LC_ALL=C ufw --dry-run allow "$@" 2>>"$RN_LOG_FILE"); then
        rn_log "${ERROR_T} Не удалось проверить правило UFW. См. $RN_LOG_FILE."
        return 1
    fi
    # Ask UFW itself, since a public rule may exist for only one address family.
    while IFS= read -r line; do
        case "$line" in
            '') ;;
            'Skipping adding existing rule'|'Skipping adding existing rule (v6)') unchanged=1 ;;
            *) unchanged=0; break ;;
        esac
    done <<< "$preview"
    if (( unchanged )); then return 0; fi
    if ! ufw allow "$@" >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${ERROR_T} Ошибка добавления правила UFW. Предыдущие успешные правила могли сохраниться; проверьте sudo ufw status verbose и $RN_LOG_FILE."
        return 1
    fi
}

rn_normalize_port_range() {
    if [[ "$1" == *:* && "${1%%:*}" == "${1##*:}" ]]; then
        printf '%s\n' "${1%%:*}"
    else
        printf '%s\n' "$1"
    fi
}

rn_collect_custom_ports() {
    local node_port="$1" entry port
    local -n result_ports="$2"
    local -A seen_ports=()
    result_ports=()
    [[ -f "$RN_APP_DIR/.xray_ports" ]] || return 0
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" ]] || continue
        if ! rn_public_range_ok "$node_port" "$entry"; then
            rn_log "${ERROR_T} Некорректная запись или пересечение с портом управления в .xray_ports: $entry"
            return 1
        fi
        port=$(rn_normalize_port_range "$entry") || return 1
        [[ "$port" != 443 && -z "${seen_ports[$port]:-}" ]] || continue
        seen_ports[$port]=1
        result_ports+=("$port")
    done < "$RN_APP_DIR/.xray_ports"
}

rn_store_custom_ports() (
    local path="$RN_APP_DIR/.xray_ports" tmp
    if [[ ! -f "$path" && $# -eq 0 ]]; then return 0; fi
    tmp=$(mktemp "$RN_APP_DIR/.xray-ports.XXXXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    if (( $# )); then printf '%s\n' "$@" > "$tmp" || return 1; fi
    if [[ -f "$path" ]] && cmp -s -- "$tmp" "$path"; then return 0; fi
    mv -fT -- "$tmp" "$path"
)

rn_allow_custom_port() {
    local port="$1"
    if [[ "$port" == 443 ]]; then return 0; fi
    if [[ "$port" != 80 ]]; then
        rn_ufw_allow "$port"/tcp comment 'Xray Custom Port TCP' || return 1
    fi
    rn_ufw_allow "$port"/udp comment 'Xray Custom Port UDP'
}

rn_delete_custom_port() {
    local port
    port=$(rn_normalize_port_range "$1") || return 1
    if [[ "$port" == 443 ]]; then return 0; fi
    if [[ "$port" != 80 ]]; then
        ufw delete allow "$port"/tcp >> "$RN_LOG_FILE" 2>&1 || return 1
    fi
    ufw delete allow "$port"/udp >> "$RN_LOG_FILE" 2>&1
}

rn_configure_firewall() {
    local node_port="$1" panel_ip="$2" entry port
    shift 2
    rn_valid_port "$node_port" && rn_valid_ipv4 "$panel_ip" || return 1
    rn_public_range_ok "$node_port" 80 && rn_public_range_ok "$node_port" 443 || return 1
    local -a custom_ports=()
    local -A seen_ports=()
    rn_collect_custom_ports "$node_port" custom_ports || return 1
    for port in "${custom_ports[@]}"; do seen_ports[$port]=1; done
    for entry in "$@"; do
        rn_public_range_ok "$node_port" "$entry" || return 1
        port=$(rn_normalize_port_range "$entry") || return 1
        [[ "$port" != 443 && -z "${seen_ports[$port]:-}" ]] || continue
        seen_ports[$port]=1
        custom_ports+=("$port")
    done
    rn_check_ufw_ready || return 1
    # Respect the administrator's firewall policy; never change defaults or enable it here.
    rn_ufw_allow from "$panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel' || return 1
    rn_ufw_allow 80/tcp comment 'HTTP / Certbot' || return 1
    rn_ufw_allow 443/tcp comment 'Xray Incoming TCP' || return 1
    rn_ufw_allow 443/udp comment 'Xray Incoming UDP' || return 1
    for port in "${custom_ports[@]}"; do rn_allow_custom_port "$port" || return 1; done
    rn_store_custom_ports "${custom_ports[@]}" || return 1
    rn_log "${SUCCESS_T} Правила ноды проверены. Добавлены только отсутствующие или требующие обновления."
}

rn_configure_combined_firewall() {
    local control_port="$1" panel_ip="$2" tls_tcp="$3" xhttp="$4" hy2_udp="$5"
    if ! rn_valid_ipv4 "$panel_ip" || ! rn_validate_transport_ports "$control_port" "$tls_tcp" "$xhttp" "$hy2_udp"; then
        rn_log "${ERROR_T} Некорректные порты или конфликт портов одного протокола. Порт управления и 61000 зарезервированы."
        return 1
    fi
    if [[ "$xhttp" != */* ]]; then xhttp+=/tcp; fi
    local xhttp_proto="${xhttp##*/}"
    rn_check_ufw_ready || return 1
    rn_ufw_allow from "$panel_ip" to any port "$control_port" proto tcp comment 'Remnanode Control from Panel' || return 1
    rn_ufw_allow "$tls_tcp/tcp" comment 'VLESS TLS TCP' || return 1
    rn_ufw_allow "$xhttp" comment "VLESS xHTTP TLS ${xhttp_proto^^}" || return 1
    rn_ufw_allow "$hy2_udp/udp" comment 'Hysteria2 UDP' || return 1
    rn_log "${SUCCESS_T} Проверены правила для $tls_tcp/tcp, $xhttp, $hy2_udp/udp. Старые правила не удалены."
}

rn_set_existing_transport_ports() (
    if (( $# != 3 )); then
        printf '%s\n' 'Использование: node-transports <VLESS-TLS TCP> <xHTTP port[/tcp|/udp]> <Hy2 UDP>' >&2
        return 1
    fi
    local control_port panel_ip planned
    if [[ ! -d "$RN_APP_DIR" ]]; then
        rn_log "${ERROR_T} Не найден управляемый деплой."
        return 1
    fi
    exec 9>"$RN_APP_DIR/.deploy.lock" || return 1
    flock -w 30 9 || return 1
    if [[ ! -f "$RN_APP_DIR/docker-compose.yml" || ! -f "$RN_APP_DIR/.env" || ! -f "$RN_APP_DIR/.panel_ip" ]]; then
        rn_log "${ERROR_T} Не найден управляемый деплой или IP панели."
        return 1
    fi
    control_port=$(sed -n 's/^NODE_PORT=//p' "$RN_APP_DIR/.env") || return 1
    IFS= read -r panel_ip < "$RN_APP_DIR/.panel_ip" || return 1
    planned=$(mktemp "$RN_APP_DIR/.transport-ports.XXXXXXXX") || return 1
    trap 'rm -f -- "$planned"' EXIT
    rn_format_transport_plan "$@" > "$planned" || return 1
    rn_configure_combined_firewall "$control_port" "$panel_ip" "$@" || return 1
    if ! cmp -s -- "$planned" "$RN_APP_DIR/.transport_ports"; then
        mv -fT -- "$planned" "$RN_APP_DIR/.transport_ports" || return 1
    fi
    rn_log "${SUCCESS_T} Список портов сохранён. Compose, nginx и конфигурация панели не изменены; контейнеры не перезапущены."
)

# --- Управление кастомными портами Xray и UFW ---
rn_manage_xray_ports() {
    if [[ -f "$RN_APP_DIR/.transport_ports" ]]; then
        rn_check_transport_ports || true
        rn_log "${INFO_T} Для изменения портов с учётом TCP/UDP используйте node-transports <TLS TCP> <xHTTP port[/tcp|/udp]> <Hy2 UDP>."
        pause_prompt
        return 0
    fi
    while true; do
        cls
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🔌 УПРАВЛЕНИЕ КЛИЕНТСКИМИ ПОРТАМИ XRAY И UFW"
        echo "  ========================================================"
        echo -e "${NC}"

        if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
            rn_log "${ERROR_T} Нода еще не установлена! Управление портами недоступно."
            pause_prompt
            return
        fi

        local panel_ip; panel_ip=$(cat "$RN_APP_DIR/.panel_ip" 2>/dev/null || echo "Не определен")
        local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")

        echo -e "📌 ${WHITE}Базовые порты ноды:${NC}"
        echo -e "   - Порт управления: ${CYAN}$node_port${NC} (настроенный IP панели: ${GREEN}$panel_ip${NC})"
        echo -e "   - Стандартные веб-порты:   ${CYAN}80, 443${NC} (Всегда открыты глобально для входящего трафика)"

        echo -e "\n📌 ${WHITE}Список кастомных входящих портов Xray в UFW:${NC}"
        if [ -f "$RN_APP_DIR/.xray_ports" ] && [ -s "$RN_APP_DIR/.xray_ports" ]; then
            local current_ports; current_ports=$(tr '\n' ' ' < "$RN_APP_DIR/.xray_ports" | xargs)
            local port
            for port in $current_ports; do
                echo -e "   - Port: ${GREEN}$port${NC} (UFW: Разрешен TCP/UDP входящий)"
            done
        else
            echo -e "   ${GRAY}Список пуст. Кастомные клиентские порты не настроены.${NC}"
        fi

        echo -e "${GRAY}--------------------------------------------------${NC}"
        echo " 1) ➕ Добавить новый клиентский порт / диапазон портов Xray в UFW"
        echo " 2) ➖ Удалить порт / диапазон из списка разрешенных"
        echo " 3) 🔄 Принудительно перезагрузить правила брандмауэра (UFW reload)"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -r -p "Выберите действие [0-3]: " port_choice
        port_choice=${port_choice:-0}

        case $port_choice in
            1)
                echo -e "\n${BLUE}Добавление нового клиентского порта:${NC}"
                read -r -p "Введите номер порта или диапазон (например, 8443 или 2000:2010): " input_port

                if ! rn_public_range_ok "$node_port" "$input_port"; then
                    rn_log "${ERROR_T} Некорректный диапазон или пересечение с портом управления."
                else
                    local canonical
                    canonical=$(rn_normalize_port_range "$input_port") || return 1
                    local -a saved_ports=()
                    rn_collect_custom_ports "$node_port" saved_ports || return 1
                    if [[ "$canonical" == 443 ]]; then
                        rn_log "${INFO_T} TCP и UDP 443 — базовые правила ноды, отдельная запись не нужна."
                    elif rn_allow_custom_port "$canonical"; then
                        if ! printf '%s\n' "${saved_ports[@]}" | grep -Fx -- "$canonical" >/dev/null; then
                            saved_ports+=("$canonical")
                        fi
                        rn_store_custom_ports "${saved_ports[@]}" || return 1
                        rn_log "${SUCCESS_T} Правила UFW для $canonical проверены."
                    else
                        rn_log "${ERROR_T} Не все правила UFW применены; проверьте текущие правила."
                    fi
                fi
                pause_prompt
                ;;
            2)
                if [ ! -f "$RN_APP_DIR/.xray_ports" ] || [ ! -s "$RN_APP_DIR/.xray_ports" ]; then
                    rn_log "${WARNING_T} Список кастомных портов пуст."
                    pause_prompt
                    continue
                fi
                echo -e "\n${BLUE}Текущие кастомные порты:${NC}"
                local i=1
                local port_list=()
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    echo " $i) $line"
                    port_list+=("$line")
                    ((i++))
                done < "$RN_APP_DIR/.xray_ports"
                echo -e "${GRAY}--------------------------------------------------${NC}"
                read -r -p "Введите номер порта для удаления: " del_num
                del_num=${del_num:-0}
                if [[ "$del_num" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$del_num" -ge 1 ] && [ "$del_num" -le "${#port_list[@]}" ]; then
                    local target="${port_list[$((del_num-1))]}"
                    if rn_public_range_ok "$node_port" "$target" &&
                       rn_delete_custom_port "$target"; then
                        sed -i "/^${target}$/d" "$RN_APP_DIR/.xray_ports" || return 1
                        rn_log "${SUCCESS_T} Правила UFW для $target удалены."
                    else
                        rn_log "${ERROR_T} Не все правила UFW удалены; проверьте текущие правила."
                    fi
                else
                    rn_log "${ERROR_T} Неверный номер."
                fi
                pause_prompt
                ;;
            3)
                if ufw reload >> "$RN_LOG_FILE" 2>&1; then
                    rn_log "${SUCCESS_T} Правила UFW перезагружены."
                else
                    rn_log "${ERROR_T} Не удалось перезагрузить UFW."
                fi
                pause_prompt
                ;;
            0)
                return
                ;;
        esac
    done
}
