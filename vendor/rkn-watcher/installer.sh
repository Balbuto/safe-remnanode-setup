#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RKN Watcher Installer"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_SCRIPT="$SCRIPT_DIR/rkn-watcher.sh"
INSTALLED_APP_SCRIPT="/opt/rkn-watcher/rkn-watcher.sh"
BIN_PATH="/usr/local/bin/rkn-watcher"

STATE_DIR="/var/lib/rkn-watcher/state"
PKG_MANIFEST="$STATE_DIR/installer-packages.txt"

REQUIRED_PACKAGES=(iptables ipset nftables curl ca-certificates python3 util-linux)
MANAGED_IPSETS=(TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW)
MANAGED_CHAINS=(TSPUBLOCK GOVBLOCK GEOIP_DROP RKN_GEOIP_HOOK RKN_DENY RKN_PROTECT TSPUBLOCK6 GOVBLOCK6)
MANAGED_IPSETS_V6=(TSPUIPS6 GOVIPS6)
IPT_WAIT="5"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC} $*"; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Установщик должен быть запущен от root"
        echo "Пример: sudo ./installer.sh"
        exit 1
    fi
}

check_platform() {
    command -v apt-get >/dev/null 2>&1 || { error "Поддерживаются только Debian/Ubuntu (не найден apt-get)"; exit 1; }
    command -v dpkg-query >/dev/null 2>&1 || { error "Не найден dpkg-query"; exit 1; }
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

collect_missing_packages() {
    local missing=()
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    printf '%s\n' "${missing[@]:-}"
}

save_installed_packages_manifest() {
    local new_packages=("$@")
    mkdir -p "$(dirname "$PKG_MANIFEST")"

    python3 - "$PKG_MANIFEST" "${new_packages[@]}" <<'PY'
import os
import sys

path = sys.argv[1]
items = [x for x in sys.argv[2:] if x.strip()]
current = []
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as fh:
        current = [line.strip() for line in fh if line.strip()]
merged = sorted(set(current + items))
with open(path, 'w', encoding='utf-8') as fh:
    for item in merged:
        fh.write(item + '\n')
PY
}

show_dependency_status() {
    title
    echo -e "${CYAN}Зависимости${NC}"
    title
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if package_installed "$pkg"; then
            echo -e "$pkg : ${GREEN}installed${NC}"
        else
            echo -e "$pkg : ${YELLOW}missing${NC}"
        fi
    done
    echo
    echo -e "${CYAN}Netfilter${NC}"
    show_nftables_status
    echo
}

install_dependencies_interactive() {
    missing=()
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        package_installed "$pkg" || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        success "Все необходимые зависимости уже установлены"
        return 0
    fi

    info "Будут установлены зависимости: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing[@]}"
    save_installed_packages_manifest "${missing[@]}"
    success "Зависимости установлены"
}

# --- nftables -----------------------------------------------------------------
# Проект ставит правила через iptables/ip6tables (это может быть и iptables-nft),
# но на современных Debian/Ubuntu сам netfilter управляется nftables. Установщик
# проверяет, что пакет nftables есть, ядро и утилита nft доступны и что загруженный
# ruleset не пуст — иначе правила могут «теряться» или конфликтовать с чужим
# набором правил.

nft_installed() {
    package_installed nftables || command -v nft >/dev/null 2>&1
}

nft_binary() {
    command -v nft 2>/dev/null || true
}

nft_ruleset_rules() {
    # Количество строк-правил в загруженном ruleset (без комментариев и пустых строк).
    local nft
    nft=$(nft_binary)
    [[ -n "$nft" ]] || { echo "0"; return 0; }
    # пустой ruleset -> grep возвращает 1, поэтому глушим статус (иначе set -e/pipefail
    # обрывает проверку и установщик молча завершается)
    "$nft" list ruleset 2>/dev/null | grep -vE '^\s*(#|$|table |})' | wc -l | tr -d ' ' || true
}

nft_tables() {
    local nft
    nft=$(nft_binary)
    [[ -n "$nft" ]] || return 0
    "$nft" list tables 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ' || true
}

nft_ruleset_conf_rules() {
    # Правила из /etc/nftables.conf на диске (их ещё не обязательно загрузили).
    local conf="${NFTABLES_CONF:-/etc/nftables.conf}"
    [[ -r "$conf" ]] || { echo "0"; return 0; }
    grep -vE '^\s*(#|$)' "$conf" 2>/dev/null | wc -l | tr -d ' ' || true
}

nftables_service_state() {
    if ! systemctl list-unit-files nftables.service >/dev/null 2>&1; then
        echo "нет юнита"
        return 0
    fi
    local enabled active
    enabled=$(systemctl is-enabled nftables.service 2>/dev/null || true)
    active=$(systemctl is-active nftables.service 2>/dev/null || true)
    echo "${enabled:-unknown}/${active:-unknown}"
}

show_nftables_status() {
    local installed="нет" rules heavy=""
    nft_installed && installed="да"
    rules=$(nft_ruleset_rules)

    if [[ "$installed" == "да" ]]; then
        local ver
        ver=$(nft --version 2>/dev/null | head -n1 || true)
        echo -e "nftables : ${GREEN}установлен${NC}${ver:+ ($ver)}"
        echo -e "  ruleset: загружено правил: ${rules}${heavy}"
        local tables
        tables=$(nft_tables)
        [[ -n "${tables// /}" ]] && echo "  таблицы: ${tables}"
        echo "  сервис nftables.service: $(nftables_service_state)"
    else
        echo -e "nftables : ${YELLOW}не установлен${NC} — будет установлен"
    fi
}

# Проверка перед установкой: nftables установлен, включён и ruleset загружен.
ensure_nftables() {
    local interactive=${1:-n}
    local failures=0

    info "Проверка nftables..."

    if ! nft_installed; then
        if [[ "$interactive" == "y" ]]; then
            export DEBIAN_FRONTEND=noninteractive
            info "Устанавливаю пакет nftables"
            apt-get update -y >/dev/null 2>&1 || true
            if apt-get install -y nftables; then
                save_installed_packages_manifest nftables
                success "nftables установлен"
            else
                error "Не удалось установить nftables"
                failures=$((failures + 1))
            fi
        else
            error "nftables не установлен — выполните: apt-get install -y nftables"
            failures=$((failures + 1))
        fi
    else
        success "nftables установлен"
    fi

    if ! command -v nft >/dev/null 2>&1; then
        error "Утилита nft не найдена в PATH — netfilter-правила нельзя проверить"
        failures=$((failures + 1))
    elif ! nft list ruleset >/dev/null 2>&1; then
        # ядро без nf_tables, контейнер без CAP_NET_ADMIN и т.п.
        error "nft не может прочитать ruleset: ядро без nf_tables или нет прав"
        info "Проверьте: nft list ruleset; modprobe nf_tables; uname -r"
        failures=$((failures + 1))
    else
        local rules
        rules=$(nft_ruleset_rules)

        # ruleset мог быть ещё не загружен при выключенном сервисе nftables
        if [[ "$rules" -eq 0 ]]; then
            local conf_rules
            conf_rules=$(nft_ruleset_conf_rules)
            if [[ "$conf_rules" -gt 0 ]]; then
                warn "ruleset пуст, но в конфиге nftables есть правила ($conf_rules строк) — сервис не загружен"
                if [[ "$interactive" == "y" && "${RKN_ASSUME_YES:-0}" != "1" ]]; then
                    read -r -p "Загрузить nftables.service сейчас? (y/n): " answer || answer="n"
                    if [[ "${answer:-n}" =~ ^[yY] ]]; then
                        systemctl enable --now nftables.service && success "nftables.service запущен" \
                            || { error "Не удалось запустить nftables.service"; failures=$((failures + 1)); }
                        rules=$(nft_ruleset_rules)
                    fi
                fi
            else
                warn "ruleset nftables пуст (правил нет) — блокировка будет работать только через iptables-цепочки"
            fi
        else
            success "ruleset nftables загружен: правил $rules, таблицы: $(nft_tables)"
        fi

        if [[ "$interactive" == "y" && "${RKN_ASSUME_YES:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
            local state
            state=$(nftables_service_state)
            if [[ "$state" == *"/inactive"* && "$(nft_ruleset_rules)" -gt 0 ]]; then
                warn "nftables.service не активен ($state), но ruleset загружен — правила не переживут перезагрузку"
                read -r -p "Включить nftables.service для загрузки правил при старте? (y/n): " answer || answer="n"
                if [[ "${answer:-n}" =~ ^[yY] ]]; then
                    systemctl enable nftables.service && success "nftables.service добавлен в автозагрузку" \
                        || { warn "Не удалось включить nftables.service"; }
                fi
            fi
        fi
    fi

    # Кто реально обслуживает пакеты: iptables может быть симлинком на nft
    if command -v iptables >/dev/null 2>&1; then
        local target
        target=$(readlink -f "$(command -v iptables)" 2>/dev/null || true)
        case "$target" in
            *xtables-nft*|*iptables-nft*)
                success "iptables работает через nft-бэкенд ($(basename "$target"))" ;;
            *xtables-legacy*|*iptables-legacy*)
                warn "iptables работает через legacy-бэкенд ($(basename "$target")) — правила не попадут в nftables"
                info "Если нужен nft: NETFILTER_BACKEND=\"nft\" в /etc/rkn-watcher/settings.conf (или пункт 10 меню настроек)" ;;
        esac
    fi

    if [[ "$failures" -gt 0 ]]; then
        error "Проверка nftables: проблем — $failures"
    elif [[ "$(nft_ruleset_rules)" -gt 0 ]]; then
        success "nftables: установлен, доступен, ruleset загружен"
    else
        warn "nftables: установлен и доступен, но ruleset пуст (netfilter-правил нет)"
    fi
    return "$failures"
}

run_install() {
    [[ -f "$APP_SCRIPT" ]] || { error "Не найден файл $APP_SCRIPT"; exit 1; }

    show_dependency_status
    install_dependencies_interactive
    # nftables обязателен: проверяем пакет, утилиту и загруженный ruleset
    ensure_nftables n || { error "Проверка nftables не пройдена — установка остановлена"; exit 1; }

    info "Запуск основного установщика RKN Watcher..."
    RKN_SKIP_DEP_INSTALL=1 "$APP_SCRIPT" install
}

remove_rule_all() {
    local l3=$1
    local chain=$2
    shift 2
    local cmd=iptables
    [[ "$l3" == "6" ]] && { command -v ip6tables >/dev/null 2>&1 || return 0; cmd=ip6tables; }
    while "$cmd" -w "$IPT_WAIT" -C "$chain" "$@" >/dev/null 2>&1; do
        "$cmd" -w "$IPT_WAIT" -D "$chain" "$@" >/dev/null 2>&1 || break
    done
}

manual_cleanup() {
    info "Выполняю аварийную очистку управляемых изменений..."

    local l3 chain cmd
    for l3 in 4 6; do
        cmd=iptables
        [[ "$l3" == "6" ]] && { command -v ip6tables >/dev/null 2>&1 || continue; cmd=ip6tables; }
        remove_rule_all "$l3" INPUT -j TSPUBLOCK || true
        remove_rule_all "$l3" INPUT -j GOVBLOCK || true
        remove_rule_all "$l3" INPUT -j TSPUBLOCK6 || true
        remove_rule_all "$l3" INPUT -j GOVBLOCK6 || true
        remove_rule_all "$l3" INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK || true
        for chain in "${MANAGED_CHAINS[@]}"; do
            "$cmd" -w "$IPT_WAIT" -F "$chain" >/dev/null 2>&1 || true
            "$cmd" -w "$IPT_WAIT" -X "$chain" >/dev/null 2>&1 || true
        done
    done

    local set_name
    for set_name in "${MANAGED_IPSETS[@]}" "${MANAGED_IPSETS_V6[@]}"; do
        ipset destroy "$set_name" >/dev/null 2>&1 || true
    done

    systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    systemctl disable --now rkn-watcher-boot.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rkn-watcher-update.timer
    rm -f /etc/systemd/system/rkn-watcher-update.service
    rm -f /etc/systemd/system/rkn-watcher-boot.service
    rm -f /etc/systemd/system/rkn-watcher-failure@.service
    rm -f /etc/logrotate.d/rkn-watcher
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -f "$BIN_PATH"
    rm -rf /opt/rkn-watcher /etc/rkn-watcher /var/lib/rkn-watcher /var/log/rkn-watcher

    success "Аварийная очистка завершена"
}

read_manifest_packages() {
    local path="$PKG_MANIFEST"
    [[ -f "$path" ]] || return 0
    awk 'NF {print $0}' "$path"
}

remove_installer_packages() {
    local packages=("$@")
    local installed=()
    local pkg

    for pkg in "${packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        if package_installed "$pkg"; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        info "Нет пакетов, которые были бы установлены именно этим установщиком и ещё присутствовали в системе"
        return 0
    fi

    echo
    warn "Дополнительно можно удалить пакеты, которые этот установщик доустановил ранее: ${installed[*]}"
    read -r -p "Удалить эти пакеты тоже? (y/n): " answer
    case "${answer:-n}" in
        y|Y|yes|YES)
            export DEBIAN_FRONTEND=noninteractive
            apt-get remove -y "${installed[@]}" || true
            apt-get autoremove -y || true
            success "Пакеты удалены"
            ;;
        *)
            info "Удаление пакетов пропущено"
            ;;
    esac
}

run_uninstall() {
    local runner=""
    local packages=()

    mapfile -t packages < <(read_manifest_packages)

    if [[ -x "$INSTALLED_APP_SCRIPT" ]]; then
        runner="$INSTALLED_APP_SCRIPT"
    elif [[ -x "$BIN_PATH" ]]; then
        runner="$BIN_PATH"
    elif [[ -x "$APP_SCRIPT" ]]; then
        runner="$APP_SCRIPT"
    fi

    echo
    warn "Будут удалены все изменения, внесённые RKN Watcher:"
    echo "- systemd timer и service"
    echo "- правила iptables и управляемые ipset"
    echo "- конфигурация, state, кэш, логи"
    echo "- файлы в /opt/rkn-watcher и ссылка /usr/local/bin/rkn-watcher"
    echo
    if [[ "${RKN_ASSUME_YES:-0}" != "1" ]]; then
        read -r -p "Продолжить полное удаление? (напишите YES): " confirm || confirm=""
        [[ "$confirm" == "YES" ]] || { warn "Удаление отменено"; return 0; }
    fi

    if [[ -n "$runner" ]]; then
        RKN_ASSUME_YES=1 "$runner" uninstall || manual_cleanup
    else
        manual_cleanup
    fi

    remove_installer_packages "${packages[@]}"
}

show_status() {
    title
    echo -e "${CYAN}${APP_NAME}${NC}"
    title
    echo
    if [[ -x "$INSTALLED_APP_SCRIPT" || -x "$BIN_PATH" ]]; then
        echo "Основной скрипт: установлен"
    else
        echo "Основной скрипт: не установлен"
    fi
    echo
    show_dependency_status
}

main_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}${APP_NAME}${NC}"
        title
        echo
        echo "1) Установить / обновить RKN Watcher"
        echo "2) Проверить зависимости"
        echo "3) Полное удаление всех внесённых изменений"
        echo "4) Показать статус"
        echo "5) Проверить nftables"
        echo "0) Выход"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1)
                run_install
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            2)
                show_dependency_status
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            3)
                run_uninstall
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            4)
                show_status
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            5)
                show_nftables_status
                echo
                ensure_nftables y || true
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            0)
                exit 0
                ;;
            *)
                warn "Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  install      проверить/установить зависимости и запустить установку RKN Watcher
  uninstall    полное удаление внесённых изменений
  deps         показать статус зависимостей
  nft          проверить nftables (пакет, утилита nft, загруженный ruleset)
  status       показать статус установщика и программы
  menu         интерактивное меню (по умолчанию)
EOF
}

main() {
    case "${1:-menu}" in
        -h|--help|help|--version)
            # справка доступна без root: её читают до установки
            print_usage
            exit 0
            ;;
    esac
    check_root
    check_platform

    local cmd=${1:-menu}
    case "$cmd" in
        install)
            run_install
            ;;
        uninstall)
            run_uninstall
            ;;
        deps)
            show_dependency_status
            ;;
        nft|nftables)
            show_nftables_status
            ensure_nftables n
            ;;
        status)
            show_status
            ;;
        menu)
            main_menu
            ;;
        *)
            error "Неизвестная команда: $cmd"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
