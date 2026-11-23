#!/usr/bin/env bash
# Пользовательский интерфейс: статус, метрики, диагностика, меню, интерактивные действия.

json_bool() { [[ "$1" == "y" ]] && echo true || echo false; }

status_json() {
    local auto_update log_rst filter_ports port_policy tspu gov geo_enabled timer
    auto_update=$(get_bool_setting AUTO_UPDATE y) || auto_update=n
    log_rst=$(get_bool_setting LOG_RST n) || log_rst=n
    filter_ports=$(get_setting FILTER_PORTS all)
    port_policy=$(get_setting PORT_POLICY geoip_only)
    tspu=$(get_bool_setting ENABLE_TSPUBLOCK y) || tspu=n
    gov=$(get_bool_setting ENABLE_GOVIPS y) || gov=n
    geo_enabled=$({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)
    timer=$(systemctl is-active rkn-watcher-update.timer 2>/dev/null | head -n1 || true)
    timer=${timer:-inactive}

    python3 - "$VERSION" "$tspu" "$gov" "$geo_enabled" "$filter_ports" "$port_policy" \
        "$log_rst" "$auto_update" "$timer" \
        "$(ipset_count TSPUIPS)" "$(ipset_count GOVIPS)" \
        "$(ipset_count GEOIP_ALLOW_IPS)" "$(ipset_count GEOIP_DENY_IPS)" \
        "$(ipset_count GEOIP_COUNTRIES_ALLOW)" \
        "$(ipset_count GEOIP_ALLOW_IPS6)" "$(ipset_count GEOIP_DENY_IPS6)" \
        "$(ipset_count GEOIP_COUNTRIES_ALLOW6)" \
        "$(cat "$STATE_DIR/tspu_count.txt" 2>/dev/null || echo 0)" \
        "$(cat "$STATE_DIR/gov_count.txt" 2>/dev/null || echo 0)" <<'PY'
import json, sys
(version, tspu, gov, geo, ports, policy, log_rst, auto_update, timer,
 tspu_entries, gov_entries, allow_ips, deny_ips, countries,
 allow_ips6, deny_ips6, countries6,
 tspu_state, gov_state) = sys.argv[1:20]
print(json.dumps({
    "version": version,
    "enabled": {
        "tspublock": tspu == "y",
        "govips": gov == "y",
        "geoip": geo == "true",
        "auto_update": auto_update == "y",
        "rst_logging": log_rst == "y",
    },
    "filter_ports": ports,
    "port_policy": policy,
    "timer": timer,
    "entries": {
        "TSPUIPS": int(tspu_entries or 0),
        "GOVIPS": int(gov_entries or 0),
        "GEOIP_ALLOW_IPS": int(allow_ips or 0),
        "GEOIP_DENY_IPS": int(deny_ips or 0),
        "GEOIP_COUNTRIES_ALLOW": int(countries or 0),
        "GEOIP_ALLOW_IPS6": int(allow_ips6 or 0),
        "GEOIP_DENY_IPS6": int(deny_ips6 or 0),
        "GEOIP_COUNTRIES_ALLOW6": int(countries6 or 0),
    },
    "last_update_entries": {
        "tspublock": int(tspu_state or 0),
        "govips": int(gov_state or 0),
    },
}, indent=2, ensure_ascii=False))
PY
}

show_status() {
    local mode=${1:-interactive}
    if [[ "$mode" == "json" ]]; then
        status_json
        return 0
    fi

    local auto_update log_rst filter_ports port_policy tspu gov geo_enabled
    auto_update=$(get_bool_setting AUTO_UPDATE y) || auto_update=n
    log_rst=$(get_bool_setting LOG_RST n) || log_rst=n
    filter_ports=$(get_setting FILTER_PORTS all)
    port_policy=$(get_setting PORT_POLICY geoip_only)
    tspu=$(get_bool_setting ENABLE_TSPUBLOCK y) || tspu=n
    gov=$(get_bool_setting ENABLE_GOVIPS y) || gov=n
    geo_enabled=$({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)

    if [[ "$mode" == "interactive" ]]; then
        clear_screen
        title
        echo -e "${CYAN}${APP_NAME} ${VERSION} — статус${NC}"
        title
        echo
    fi

    echo "TSPUBLOCK enabled : $tspu"
    echo "GOVIPS enabled    : $gov"
    echo "GeoIP enabled     : $geo_enabled"
    echo "Filter ports      : $filter_ports"
    echo "Port policy       : $port_policy"
    echo "RST logging       : $log_rst"
    echo "Auto update       : $auto_update"
    echo
    echo "TSPUIPS entries   : $(ipset_count TSPUIPS) (IPv6: $(ipset_count TSPUIPS6))"
    echo "GOVIPS entries    : $(ipset_count GOVIPS) (IPv6: $(ipset_count GOVIPS6))"
    echo "GeoIP allow IPs   : $(ipset_count GEOIP_ALLOW_IPS) (IPv6: $(ipset_count GEOIP_ALLOW_IPS6))"
    echo "GeoIP deny IPs    : $(ipset_count GEOIP_DENY_IPS) (IPv6: $(ipset_count GEOIP_DENY_IPS6))"
    echo "GeoIP countries   : $(ipset_count GEOIP_COUNTRIES_ALLOW) (IPv6: $(ipset_count GEOIP_COUNTRIES_ALLOW6))"
    echo
    systemctl is-enabled rkn-watcher-update.timer >/dev/null 2>&1 && echo "Timer: enabled" || echo "Timer: disabled"
    systemctl is-active rkn-watcher-update.timer >/dev/null 2>&1 && echo "Timer state: active" || true
    echo

    if [[ "$mode" == "interactive" ]]; then
        read -r -p "Нажмите Enter для продолжения..." _ || true
    fi
}

show_metrics() {
    local np
    np=$(iptables -w "$IPT_WAIT" -L RKN_GEOIP_HOOK -v -n -x 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print $1; exit}' || echo 0)
    cat <<EOF
# HELP rkn_watcher_entries Количество записей в управляемых ipset-наборах
# TYPE rkn_watcher_entries gauge
rkn_watcher_entries{set="TSPUIPS"} $(ipset_count TSPUIPS)
rkn_watcher_entries{set="TSPUIPS6"} $(ipset_count TSPUIPS6)
rkn_watcher_entries{set="GOVIPS"} $(ipset_count GOVIPS)
rkn_watcher_entries{set="GOVIPS6"} $(ipset_count GOVIPS6)
rkn_watcher_entries{set="GEOIP_ALLOW_IPS"} $(ipset_count GEOIP_ALLOW_IPS)
rkn_watcher_entries{set="GEOIP_DENY_IPS"} $(ipset_count GEOIP_DENY_IPS)
rkn_watcher_entries{set="GEOIP_COUNTRIES_ALLOW"} $(ipset_count GEOIP_COUNTRIES_ALLOW)
rkn_watcher_entries{set="GEOIP_ALLOW_IPS6"} $(ipset_count GEOIP_ALLOW_IPS6)
rkn_watcher_entries{set="GEOIP_DENY_IPS6"} $(ipset_count GEOIP_DENY_IPS6)
rkn_watcher_entries{set="GEOIP_COUNTRIES_ALLOW6"} $(ipset_count GEOIP_COUNTRIES_ALLOW6)
# HELP rkn_watcher_enabled Включённость подсистем (1/0)
# TYPE rkn_watcher_enabled gauge
rkn_watcher_enabled{component="tspublock"} $([[ $(get_bool_setting ENABLE_TSPUBLOCK y || echo n) == y ]] && echo 1 || echo 0)
rkn_watcher_enabled{component="govips"} $([[ $(get_bool_setting ENABLE_GOVIPS y || echo n) == y ]] && echo 1 || echo 0)
rkn_watcher_enabled{component="geoip"} $([[ $({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1) == true ]] && echo 1 || echo 0)
# HELP rkn_watcher_hook_packets Пакеты, прошедшие через GeoIP hook
# TYPE rkn_watcher_hook_packets counter
rkn_watcher_hook_packets ${np:-0}
# HELP rkn_watcher_last_update_timestamp Время последнего запуска обновления
# TYPE rkn_watcher_last_update_timestamp gauge
rkn_watcher_last_update_timestamp $(stat -c %Y "$UPDATE_LOG" 2>/dev/null || echo 0)
# HELP rkn_watcher_last_update_success Успешность последнего обновления
# TYPE rkn_watcher_last_update_success gauge
rkn_watcher_last_update_success $(tail -n 3 "$UPDATE_LOG" 2>/dev/null | grep -q 'completed with errors' && echo 0 || echo 1)
EOF
}

# Диагностика одной командой: то, что раньше приходилось искать в TROUBLESHOOTING.
cmd_doctor() {
    local problems=0
    title
    echo -e "${CYAN}${APP_NAME} ${VERSION} — диагностика${NC}"
    title
    echo

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo -e "root: ${GREEN}да${NC}"
    else
        echo -e "root: ${RED}нет${NC} (часть проверок недоступна)"; problems=$((problems + 1))
    fi

    local pkg
    for pkg in iptables ipset curl python3 flock; do
        if command_exists "$pkg"; then
            echo -e "$pkg: ${GREEN}есть${NC}"
        else
            echo -e "$pkg: ${RED}нет${NC}"; problems=$((problems + 1))
        fi
    done
    has_ip6tables && echo -e "ip6tables: ${GREEN}есть${NC} (IPv6-блокировка активна)" \
        || echo -e "ip6tables: ${YELLOW}нет${NC} (IPv6 не защищён)"

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        for mod in ip_set xt_set xt_conntrack xt_multiport; do
            lsmod 2>/dev/null | grep -q "^${mod}" && echo -e "модуль $mod: ${GREEN}загружен${NC}" \
                || echo -e "модуль $mod: ${YELLOW}не загружен${NC} (проверьте modprobe)"
        done
        local backend tool
        backend=$(netfilter_backend) || { problems=$((problems + 1)); backend="auto"; }
        tool=$(_netfilter_tool iptables | awk '{print $1}')
        local actual="legacy"
        if "$tool" -S 2>/dev/null | grep -q "nf_tables\|^table ip "; then
            actual="nft"
        fi
        echo -e "netfilter backend: ${GREEN}${backend}${NC} (фактически: $actual, утилита: $(basename "$tool"))"
        if [[ "$backend" != "auto" && "$backend" != "$actual" ]]; then
            echo -e "  ${YELLOW}NETFILTER_BACKEND=$backend, но iptables работает через $actual${NC}"
            problems=$((problems + 1))
        fi
        if ipt -L INPUT -n >/dev/null 2>&1; then
            echo -e "iptables: ${GREEN}работает${NC}"
        else
            echo -e "iptables: ${RED}недоступен${NC}"; problems=$((problems + 1))
        fi
    fi

    # Конфликты с другими firewall-менеджерами
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "ufw: ${YELLOW}включён${NC} — проверить, не перезаписывает ли правила"; 
    fi
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo -e "firewalld: ${YELLOW}включён${NC} — правила iptables могут конфликтовать";
    fi
    if command_exists docker && docker ps >/dev/null 2>&1; then
        echo -e "docker: ${YELLOW}обнаружен${NC} — docker управляет FORWARD/NAT, hook в INPUT сохраняется";
    fi

    echo
    echo "Конфигурация:"
    local dupes
    dupes=$(grep -oE '^[A-Z_]+=' "$SETTINGS_FILE" 2>/dev/null | sort | uniq -d | tr '\n' ' ')
    if [[ -n "${dupes// /}" ]]; then
        echo -e "  ${YELLOW}дублирующиеся ключи (действует последнее значение): $dupes${NC}"
    fi
    if [[ -f "$SETTINGS_FILE" ]]; then
        local key raw
        for key in FILTER_PORTS PORT_POLICY NETFILTER_BACKEND SNAPSHOT_KEEP SNAPSHOT_MAX_AGE_DAYS \
            LOG_RST AUTO_UPDATE ENABLE_TSPUBLOCK ENABLE_GOVIPS; do
            raw=$(get_setting "$key" "")
            if [[ "$key" =~ ^(LOG_RST|AUTO_UPDATE|ENABLE_TSPUBLOCK|ENABLE_GOVIPS)$ ]]; then
                if normalize_bool "$raw" >/dev/null; then
                    echo -e "  $key=$raw ${GREEN}ok${NC}"
                else
                    echo -e "  $key=$raw ${RED}некорректно${NC} (допустимо y/n, true/false, 1/0)"
                    problems=$((problems + 1))
                fi
            else
                echo "  $key=$raw"
            fi
        done
    else
        echo -e "  ${RED}$SETTINGS_FILE отсутствует${NC}"; problems=$((problems + 1))
    fi

    echo
    echo "Соответствие правил конфигурации:"
    local enabled
    enabled=$(get_bool_setting ENABLE_TSPUBLOCK y || echo n)
    if iptables -w "$IPT_WAIT" -C INPUT -j TSPUBLOCK >/dev/null 2>&1; then
        echo "  TSPUBLOCK hook: присутствует"
        [[ "$enabled" == "n" ]] && { echo -e "  ${YELLOW}но ENABLE_TSPUBLOCK=n — хук лишний, выполните apply${NC}"; problems=$((problems + 1)); }
    else
        echo "  TSPUBLOCK hook: отсутствует"
        [[ "$enabled" == "y" ]] && { echo -e "  ${RED}но ENABLE_TSPUBLOCK=y — примените правила${NC}"; problems=$((problems + 1)); }
    fi
    if iptables -w "$IPT_WAIT" -C INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK >/dev/null 2>&1; then
        echo "  GeoIP hook: присутствует"
    else
        echo "  GeoIP hook: отсутствует"
        [[ $({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1) == "true" ]] && \
            { echo -e "  ${RED}но GeoIP включён в конфиге${NC}"; problems=$((problems + 1)); }
    fi

    echo
    echo "Источники и состояние:"
    local src
    for src in "$TSPU_URL" "$GOV_URL"; do
        if curl -fsSIL --connect-timeout 5 --max-time 15 -o /dev/null "$src" 2>/dev/null; then
            echo -e "  ${GREEN}ok${NC} $src"
        else
            echo -e "  ${RED}недоступен${NC} $src"; problems=$((problems + 1))
        fi
    done
    echo "  TSPUIPS: $(ipset_count TSPUIPS) записей, TSPUIPS6: $(ipset_count TSPUIPS6)"
    echo "  GOVIPS:  $(ipset_count GOVIPS) записей, GOVIPS6:  $(ipset_count GOVIPS6)"
    if [[ -f "$UPDATE_LOG" ]]; then
        echo "  последнее обновление: $(tail -n 1 "$UPDATE_LOG")"
    else
        echo -e "  ${YELLOW}журнал обновлений отсутствует${NC}"
    fi

    echo
    local timer_enabled timer_active
    timer_enabled=$(systemctl is-enabled rkn-watcher-update.timer 2>/dev/null | head -n1 || true)
    timer_active=$(systemctl is-active rkn-watcher-update.timer 2>/dev/null | head -n1 || true)
    echo "Таймер: ${timer_enabled:-disabled} / ${timer_active:-inactive}"
    if command_exists systemctl && systemctl list-timers --all 2>/dev/null | grep -q rkn-watcher-update; then
        systemctl list-timers --all 2>/dev/null | grep rkn-watcher-update | sed 's/^/  /'
    fi

    echo
    if (( problems == 0 )); then
        success "Проблем не найдено"
    else
        warn "Найдено проблем: $problems — см. docs/ru/TROUBLESHOOTING.md"
    fi
    return 0
}

show_rules() {
    clear_screen
    title
    echo -e "${CYAN}iptables / ipset${NC}"
    title
    echo
    iptables -w "$IPT_WAIT" -L INPUT -v -n | sed -n '1,40p' || true
    echo
    for chain in TSPUBLOCK GOVBLOCK RKN_GEOIP_HOOK RKN_DENY GEOIP_DROP RKN_PROTECT; do
        echo "=== $chain ==="
        iptables -w "$IPT_WAIT" -L "$chain" -v -n 2>/dev/null || echo "chain absent"
        echo
    done
    local set_name
    for set_name in "${MANAGED_IPSETS[@]}" "${MANAGED_IPSETS_V6[@]}"; do
        echo "=== $set_name ==="
        ipset list "$set_name" 2>/dev/null | sed -n '1,20p' || echo "set absent"
        echo
    done
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

show_logs() {
    local hours="${1:-0}"
    local since=""
    [[ "$hours" =~ ^[0-9]+$ ]] && (( hours > 0 )) && since="--since=-${hours}h"
    while true; do
        clear_screen
        title
        echo -e "${CYAN}Логи${NC}"
        title
        echo
        echo "1) update.log"
        echo "2) actions.log"
        echo "3) geoip.log"
        echo "4) Очистить все логи"
        echo "5) Только за последние 24 часа"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice || return 0
        case "$choice" in
            1) clear_screen; if [[ -n "$since" ]]; then journalctl -u rkn-watcher-update --no-pager -n 100 2>/dev/null || tail -n 100 "$UPDATE_LOG"; else tail -n 100 "$UPDATE_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; fi; echo; read -r -p "Enter..." _ || true ;;
            2) clear_screen; tail -n 100 "$ACTION_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ || true ;;
            3) clear_screen; tail -n 100 "$GEOIP_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ || true ;;
            4)
                # truncate сохраняет inode и не ломает tail -f / logrotate
                truncate -s 0 "$UPDATE_LOG" "$ACTION_LOG" "$GEOIP_LOG" 2>/dev/null || true
                success "Логи очищены"
                sleep 1
                ;;
            5)
                clear_screen
                echo "=== update.log (24h) ==="; journalctl -u rkn-watcher-update --since=-24h --no-pager 2>/dev/null || tail -n 200 "$UPDATE_LOG"
                echo; echo "=== actions.log ==="; find "$ACTION_LOG" -newermt '-24 hours' >/dev/null 2>&1 && tail -n 200 "$ACTION_LOG" || echo "нет записей за 24 часа"
                echo; read -r -p "Enter..." _ || true
                ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

show_geoip_config() {
    clear_screen
    title
    echo -e "${CYAN}Конфигурация GeoIP${NC}"
    title
    echo
    echo "--- whitelist.json ---"
    "$CONFIG_TOOL" show whitelist || true
    echo
    echo "--- blacklist.json ---"
    "$CONFIG_TOOL" show blacklist || true
    echo
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

reapply_rules() {
    if apply_all; then
        success "Правила успешно применены"
    else
        error "Не удалось применить правила"
    fi
    sleep 1
}

set_filter_ports_interactive() {
    local value
    read -r -p "Введите all или список портов через запятую: " value || return 1
    validate_ports_csv "$value" || { error "Некорректное значение"; sleep 1; return 1; }
    value=$(normalize_ports_csv "$value") || return 1
    set_setting FILTER_PORTS "$value"
    apply_all
    success "FILTER_PORTS обновлён: $value"
    sleep 1
}

set_backend_interactive() {
    local current
    current=$(get_setting NETFILTER_BACKEND auto)
    info "Текущий бэкенд: $current"
    echo "1) auto   — как настроено в системе (по умолчанию)"
    echo "2) legacy — iptables-legacy"
    echo "3) nft    — iptables-nft"
    read -r -p "Выберите вариант (1-3): " choice || return 1
    local value
    case "$choice" in
        2) value="legacy" ;;
        3) value="nft" ;;
        *) value="auto" ;;
    esac
    set_setting NETFILTER_BACKEND "$value"
    # shellcheck disable=SC2034  # кэш читается в lib/firewall.sh
    NETFILTER_BACKEND_CACHE=""
    apply_all
    success "NETFILTER_BACKEND=$value"
    sleep 1
}

set_port_policy_interactive() {
    local default
    default=$(get_setting PORT_POLICY geoip_only)
    info "Текущая политика: $default"
    echo "1) geoip_only — фильтровать только порты из FILTER_PORTS"
    echo "2) strict     — открыты только порты из FILTER_PORTS"
    read -r -p "Выберите вариант (1-2): " choice || return 1
    local value
    case "$choice" in
        2) value="strict" ;;
        *) value="geoip_only" ;;
    esac
    set_setting PORT_POLICY "$value"
    apply_all
    success "PORT_POLICY=$value"
    sleep 1
}

toggle_setting_yesno() {
    local key=$1
    local current next
    current=$(get_bool_setting "$key" n) || current=n
    if [[ "$current" == "y" ]]; then
        next="n"
    else
        next="y"
    fi
    set_setting "$key" "$next"
    printf '%s\n' "$next"
}

toggle_tspublock() {
    local next
    next=$(toggle_setting_yesno ENABLE_TSPUBLOCK) || return 1
    apply_all
    success "TSPUBLOCK: $next"
    sleep 1
}

toggle_govips() {
    local next
    next=$(toggle_setting_yesno ENABLE_GOVIPS) || return 1
    apply_all
    success "GOVIPS: $next"
    sleep 1
}

toggle_rst_logging() {
    local next
    next=$(toggle_setting_yesno LOG_RST) || return 1
    apply_all
    success "LOG_RST: $next"
    sleep 1
}

toggle_auto_update() {
    local next
    next=$(toggle_setting_yesno AUTO_UPDATE) || return 1
    enable_or_disable_timer
    success "AUTO_UPDATE: $next"
    sleep 1
}

toggle_geoip_enabled() {
    local current next_bool msg
    current=$({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)
    if [[ "$current" == "true" ]]; then
        next_bool="false"
        msg="отключён"
    else
        next_bool="true"
        msg="включён"
        guard_self_lock
    fi
    "$CONFIG_TOOL" set-enabled "$next_bool" >/dev/null
    apply_all
    success "GeoIP $msg"
    sleep 1
}

guard_self_lock() {
    local ssh_ip=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_ip=$(awk '{print $1}' <<< "$SSH_CONNECTION")
    fi
    [[ -z "$ssh_ip" ]] && return 0
    if "$CONFIG_TOOL" show whitelist 2>/dev/null | grep -q "$ssh_ip"; then
        return 0
    fi
    warn "Ваше SSH-подключение идёт с $ssh_ip, и этого адреса нет в GeoIP allow-списке."
    read -r -p "Добавить $ssh_ip в allow-список перед включением GeoIP? (y/n): " answer || answer="y"
    if [[ $(normalize_yesno "$answer") == "y" ]]; then
        "$CONFIG_TOOL" add-ip "$ssh_ip" >/dev/null && success "$ssh_ip добавлен в allow-список"
    fi
}

# Аргумент необязателен: без него берём адрес из $SSH_CONNECTION.
# shellcheck disable=SC2120
allow_my_ip() {
    check_root
    local ip=""
    if [[ -n "${1:-}" ]]; then
        ip=$1
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        ip=$(awk '{print $1}' <<< "$SSH_CONNECTION")
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        ip=$(awk '{print $1}' <<< "$SSH_CLIENT")
    fi
    if [[ -z "$ip" ]]; then
        error "Не удалось определить IP (нет SSH_CONNECTION). Укажите вручную: rkn-watcher allow-my-ip 203.0.113.7"
        return 1
    fi
    validate_ip_or_cidr "$ip" || { error "Некорректный IP: $ip"; return 1; }
    local result
    result=$("$CONFIG_TOOL" add-ip "$ip" 2>&1) || { error "$result"; return 1; }
    case "$result" in
        *EXISTS*) info "$ip уже в allow-списке" ;;
        *) success "$ip добавлен в allow-список" ;;
    esac
    apply_all
    log_action "allow-my-ip: $ip"
    return 0
}

block_ip() {
    check_root
    local ip=${1:-}
    [[ -n "$ip" ]] || { error "Использование: rkn-watcher block-ip 203.0.113.7"; return 1; }
    validate_ip_or_cidr "$ip" || { error "Некорректный IP/CIDR"; return 1; }
    local result
    result=$("$CONFIG_TOOL" add-deny-ip "$ip" 2>&1) || { error "$result"; return 1; }
    case "$result" in
        *EXISTS*) info "$ip уже заблокирован" ;;
        *) success "$ip заблокирован" ;;
    esac
    apply_all
}

unblock_ip() {
    check_root
    local ip=${1:-}
    [[ -n "$ip" ]] || { error "Использование: rkn-watcher unblock-ip 203.0.113.7"; return 1; }
    validate_ip_or_cidr "$ip" || { error "Некорректный IP/CIDR"; return 1; }
    local result
    result=$("$CONFIG_TOOL" remove-deny-ip "$ip" 2>&1) || { error "$result"; return 1; }
    success "Разблокирован: $ip"
    apply_all
}

run_config_tool_and_apply() {
    local output
    if ! output=$("$CONFIG_TOOL" "$@" 2>&1); then
        error "$output"
        sleep 1
        return 1
    fi
    apply_all
    # config_tool печатает служебные слова (ADDED/REMOVED), поэтому показываем
    # человекочитаемое сообщение вместо них.
    success "Готово: $*"
    sleep 1
}

geoip_menu() {
    while true; do
        clear_screen
        title
        echo -e "${CYAN}Настройка GeoIP${NC}"
        title
        echo
        echo "1) Вкл/выкл GeoIP"
        echo "2) Добавить страну"
        echo "3) Удалить страну"
        echo "4) Добавить allow IP/CIDR"
        echo "5) Удалить allow IP/CIDR"
        echo "6) Добавить allow порт"
        echo "7) Удалить allow порт"
        echo "8) Добавить deny IP/CIDR"
        echo "9) Удалить deny IP/CIDR"
        echo "10) Добавить deny порт"
        echo "11) Удалить deny порт"
        echo "12) Показать конфиг"
        echo "13) Разрешить мой текущий IP (SSH)"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice || return 0
        case "$choice" in
            1) toggle_geoip_enabled ;;
            2)
                read -r -p "Код страны (например, FI): " value || continue
                validate_country_code "$value" || { error "Некорректный код"; sleep 1; continue; }
                run_config_tool_and_apply add-country "$value"
                ;;
            3)
                read -r -p "Код страны: " value || continue
                validate_country_code "$value" || { error "Некорректный код"; sleep 1; continue; }
                run_config_tool_and_apply remove-country "$value"
                ;;
            4)
                read -r -p "IP или CIDR: " value || continue
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply add-ip "$value"
                ;;
            5)
                read -r -p "IP или CIDR: " value || continue
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply remove-ip "$value"
                ;;
            6)
                read -r -p "Порт: " value || continue
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply add-port "$value"
                ;;
            7)
                read -r -p "Порт: " value || continue
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply remove-port "$value"
                ;;
            8)
                read -r -p "IP или CIDR: " value || continue
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply add-deny-ip "$value"
                ;;
            9)
                read -r -p "IP или CIDR: " value || continue
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply remove-deny-ip "$value"
                ;;
            10)
                read -r -p "Порт: " value || continue
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply add-deny-port "$value"
                ;;
            11)
                read -r -p "Порт: " value || continue
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply remove-deny-port "$value"
                ;;
            12) show_geoip_config ;;
            13) allow_my_ip ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

settings_menu() {
    while true; do
        clear_screen
        title
        echo -e "${CYAN}Настройки${NC}"
        title
        echo
        echo "1) Изменить FILTER_PORTS"
        echo "2) Вкл/выкл LOG_RST"
        echo "3) Вкл/выкл AUTO_UPDATE"
        echo "4) Пере-применить правила"
        echo "5) Политика по портам (geoip_only / strict)"
        echo "6) Снапшот правил"
        echo "7) Откатить последний снапшот"
        echo "8) Диагностика (doctor)"
        echo "9) Список снапшотов"
        echo "10) Netfilter-бэкенд (auto/legacy/nft)"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice || return 0
        case "$choice" in
            1) set_filter_ports_interactive ;;
            2) toggle_rst_logging ;;
            3) toggle_auto_update ;;
            4) reapply_rules ;;
            5) set_port_policy_interactive ;;
            6) snapshot_state && success "Снапшот создан"; sleep 1 ;;
            7) rollback_state; sleep 2 ;;
            8) cmd_doctor; read -r -p "Enter..." _ || true ;;
            9) snapshot_list; read -r -p "Enter..." _ || true ;;
            10) set_backend_interactive ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

blocklists_menu() {
    while true; do
        clear_screen
        title
        echo -e "${CYAN}Блок-листы${NC}"
        title
        echo
        echo "1) Вкл/выкл TSPUBLOCK"
        echo "2) Вкл/выкл GOVIPS"
        echo "3) Обновить оба списка"
        echo "4) Показать правила / ipset"
        echo "5) Заблокировать IP (deny)"
        echo "6) Разблокировать IP"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice || return 0
        case "$choice" in
            1) toggle_tspublock ;;
            2) toggle_govips ;;
            3)
                if update_all; then success "Обновление завершено"; else warn "Обновление завершено с ошибками"; fi
                sleep 1
                ;;
            4) show_rules ;;
            5) read -r -p "IP или CIDR: " value || continue; block_ip "$value"; sleep 1 ;;
            6) read -r -p "IP или CIDR: " value || continue; unblock_ip "$value"; sleep 1 ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear_screen
        title
        echo -e "${CYAN}${APP_NAME} ${VERSION}${NC}"
        title
        echo
        if is_installed; then
            echo "1) Блок-листы"
            echo "2) GeoIP"
            echo "3) Настройки"
            echo "4) Статус"
            echo "5) Логи"
            echo "6) Переустановить / обновить"
            echo "7) Удалить"
            echo "8) Диагностика"
            echo "0) Выход"
        else
            echo "1) Установить"
            echo "0) Выход"
        fi
        echo
        read -r -p "Выберите пункт: " choice || exit 0
        if is_installed; then
            case "$choice" in
                1) blocklists_menu ;;
                2) geoip_menu ;;
                3) settings_menu ;;
                4) show_status ;;
                5) show_logs ;;
                6) install_or_upgrade ;;
                7) uninstall_all ;;
                8) cmd_doctor; read -r -p "Enter..." _ || true ;;
            10) set_backend_interactive ;;
                0) exit 0 ;;
                *) warn "Неверный выбор"; sleep 1 ;;
            esac
        else
            case "$choice" in
                1) install_or_upgrade ;;
                0) exit 0 ;;
                *) warn "Неверный выбор"; sleep 1 ;;
            esac
        fi
    done
}

print_usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  install              установить или обновить
  update               обновить TSPUBLOCK и GOVIPS
  apply                пере-применить правила из текущей конфигурации
  status [--json]      состояние
  doctor               диагностика окружения и правил
  metrics              метрики в формате Prometheus
  allow-my-ip [IP]     добавить свой IP (или IP из SSH_CONNECTION) в allow-список
  block-ip IP          заблокировать IP/CIDR
  unblock-ip IP        снять блокировку IP/CIDR
  snapshot             сохранить снапшот правил
  snapshots            список снапшотов
  rollback [STAMP]     откатить правила к снапшоту
  uninstall            удалить приложение
  menu                 интерактивное меню (по умолчанию)

Options:
  --quiet              минимум вывода (для systemd)
  --dry-run            показать правила, которые будут применены (apply)
  --json               машинный вывод (status)
  --yes                неинтерактивный режим (install/uninstall)
  --version            версия
EOF
}

