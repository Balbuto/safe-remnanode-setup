#!/usr/bin/env bash
# Работа с netfilter: выбор бэкенда, ipset, правила блокировки RST, сохранение состояния.

# iptables/ip6tables с ожиданием xtables lock: иначе параллельный apply и
# внешний firewall-менеджер (ufw/docker) дают тихий сбой правила.
# Бэкенд netfilter: auto (по умолчанию), legacy или nft. Значение читается из
# settings.conf один раз и кэшируется; при явном выборе используются утилиты
# *-legacy/*-nft, если они есть в системе.
NETFILTER_BACKEND_CACHE=""

netfilter_backend() {
    if [[ -n "$NETFILTER_BACKEND_CACHE" ]]; then
        printf '%s\n' "$NETFILTER_BACKEND_CACHE"
        return 0
    fi
    local mode
    mode=$(get_setting NETFILTER_BACKEND auto)
    case "$mode" in
        auto|legacy|nft) ;;
        *)
            error "NETFILTER_BACKEND: допустимо auto, legacy или nft (сейчас: $mode)"
            return 1
            ;;
    esac
    NETFILTER_BACKEND_CACHE="$mode"
    printf '%s\n' "$mode"
}

_netfilter_tool() {
    # _netfilter_tool iptables|ip6tables [suffix]
    local base=$1
    local suffix=${2:-}
    local mode
    mode=$(netfilter_backend) || return 1
    if [[ "$mode" != "auto" ]]; then
        if command_exists "${base}-${mode}${suffix}"; then
            printf '%s\n' "${base}-${mode}${suffix}"
            return 0
        fi
        warn "NETFILTER_BACKEND=$mode, но ${base}-${mode}${suffix} не найден: используется $base"
    fi
    printf '%s\n' "${base}${suffix}"
}

ipt() { "$(_netfilter_tool iptables)" -w "$IPT_WAIT" "$@"; }
ipt6() { "$(_netfilter_tool ip6tables)" -w "$IPT_WAIT" "$@"; }
ipt_restore() { "$(_netfilter_tool iptables -restore)" -w "$IPT_WAIT" "$@"; }
ipt6_restore() { "$(_netfilter_tool ip6tables -restore)" -w "$IPT_WAIT" "$@"; }
has_ip6tables() { command_exists ip6tables; }

install_dependencies() {
    if [[ "${RKN_SKIP_DEP_INSTALL:-0}" == "1" ]]; then
        info "Установка зависимостей пропущена: зависимости уже обработаны внешним установщиком"
        return 0
    fi

    info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables ipset curl ca-certificates python3 util-linux
}

ensure_ipset_exists() {
    local name=$1
    local type=${2:-hash:net}
    local maxelem=${3:-2000000}
    local family=${4:-inet}
    ipset create "$name" "$type" family "$family" maxelem "$maxelem" -exist >/dev/null 2>&1 || true
}

ipset_count() {
    local name=$1
    ipset list "$name" 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'
}

parse_number() {
    local value
    value=$(printf '%s' "${1:-0}" | tr -cd '0-9')
    printf '%s\n' "${value:-0}"
}

remove_rule_all() {
    local l3=$1
    local chain=$2
    shift 2
    local cmd
    case "$l3" in
        6) cmd=ipt6 ;;
        *) cmd=ipt ;;
    esac
    while "$cmd" -C "$chain" "$@" >/dev/null 2>&1; do
        "$cmd" -D "$chain" "$@" >/dev/null 2>&1 || break
    done
}

ensure_chain() {
    local l3=$1
    local chain=$2
    local cmd
    case "$l3" in
        6) cmd=ipt6 ;;
        *) cmd=ipt ;;
    esac
    "$cmd" -N "$chain" >/dev/null 2>&1 || true
    "$cmd" -F "$chain" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Блокировка RST-пакетов (TSPUBLOCK/GOVIPS) для IPv4 и IPv6
# ---------------------------------------------------------------------------

_apply_rst_block() {
    local l3=$1 set_name=$2 chain=$3 enabled=$4 log_rst=$5 label=$6
    local cmd
    case "$l3" in
        6)
            cmd=ipt6
            if ! has_ip6tables; then
                warn "ip6tables не найден: IPv6-блокировка $label пропущена"
                return 0
            fi
            ;;
        *) cmd=ipt ;;
    esac

    local family="inet"
    [[ "$l3" == "6" ]] && family="inet6"
    ensure_ipset_exists "$set_name" hash:net 2000000 "$family"
    ensure_chain "$l3" "$chain"
    remove_rule_all "$l3" INPUT -j "$chain"

    if [[ "$enabled" != "y" ]]; then
        log_action "$label disabled (ipv$l3)"
        return 0
    fi

    if [[ "$log_rst" == "y" ]]; then
        "$cmd" -A "$chain" -p tcp --tcp-flags RST RST -m set --match-set "$set_name" src \
            -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "${label}: " --log-level 4
    fi
    "$cmd" -A "$chain" -p tcp --tcp-flags RST RST -m set --match-set "$set_name" src -j DROP
    "$cmd" -I INPUT 1 -j "$chain"
    log_action "$label rules applied (ipv$l3)"
}

setup_tspublock_rules() {
    local enabled log_rst
    enabled=$(get_bool_setting ENABLE_TSPUBLOCK y) || return 1
    log_rst=$(get_bool_setting LOG_RST n) || return 1
    _apply_rst_block 4 TSPUIPS TSPUBLOCK "$enabled" "$log_rst" TSPUBLOCK
    _apply_rst_block 6 TSPUIPS6 TSPUBLOCK6 "$enabled" "$log_rst" TSPUBLOCK6
}

setup_govips_rules() {
    local enabled log_rst
    enabled=$(get_bool_setting ENABLE_GOVIPS y) || return 1
    log_rst=$(get_bool_setting LOG_RST n) || return 1
    _apply_rst_block 4 GOVIPS GOVBLOCK "$enabled" "$log_rst" GOVBLOCK
    _apply_rst_block 6 GOVIPS6 GOVBLOCK6 "$enabled" "$log_rst" GOVBLOCK6
}

save_ipset_state() {
    ensure_dirs
    local tmp set_name
    tmp=$(mktemp "$STATE_DIR/ipset.XXXXXX")
    : > "$tmp"
    for set_name in "${MANAGED_IPSETS[@]}" "${MANAGED_IPSETS_V6[@]}"; do
        ipset save "$set_name" >> "$tmp" 2>/dev/null || true
    done
    mv "$tmp" "$IPSET_STATE_FILE"
}

restore_ipset_state() {
    if [[ -f "$IPSET_STATE_FILE" ]]; then
        ipset restore -exist < "$IPSET_STATE_FILE" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Снапшоты: позволяют откатиться одной командой, если правила отрезали доступ
# ---------------------------------------------------------------------------

