#!/usr/bin/env bash
# ==============================================================================
# 🛡️ SAFE REMNANODE SETUP v1.1.0
# ==============================================================================
# Универсальный интерактивный скрипт для развертывания ноды Remnawave,
# объединяющий все возможности трёх проектов:
#
#   [1] Setup-and-Test-Server-Ubuntu-24 (server-setup.sh v3.3)
#       — первоначальная настройка сервера: apt, Docker, BBR, sysctl
#         SAFE/HIGHLOAD, IPv6, UFW-менеджер, мульти-тесты
#
#   [2] setup-remna-node (setup_node.sh v1.7.2)
#       — установка и управление нодой Remnawave: Xray-Core (Reality/TLS/xHTTP),
#         SSL (Cloudflare/Gcore/Standalone), маскировка Selfsteal, UFW, логи
#
#   [3] RKN-Watcher (встроенные rkn-watcher.sh и модули upstream)
#       — защита ноды от сканеров РКН: TSPUBLOCK/GOVIPS блок-листы,
#         GeoIP-фильтрация по странам, allow/deny IP и порты, systemd timer
#
# Возможности:
#   - Экспресс-режим: полная установка "сервер + нода + защита" за один запуск
#   - Полностью русифицированный интерактивный интерфейс
#   - Работает на Ubuntu 24.04 / Debian 11+ (root)
#   - Без автоматического исполнения загруженных shell-скриптов
#   - Логирование всех действий + бэкапы изменяемых файлов
#   - Регистрация глобальных команд: safe-remnanode-setup / remnanode / rkn-watcher
#   - Запуск установщика из локального файла
# ==============================================================================

set -Eeuo pipefail

UNIVERSAL_VERSION="1.1.0+hardening.15"

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'
NC='\033[0m'

# --- Символы ---
CHECK_MARK="✅"; CROSS_MARK="❌"; WARNING="⚠️"
INFO_T="[${BLUE}i${NC}]"; SUCCESS_T="[${GREEN}✓${NC}]"; WARNING_T="[${YELLOW}!${NC}]"; ERROR_T="[${RED}✗${NC}]"

# ==============================================================================
# ЛОГИРОВАНИЕ И БЭКАПЫ
# ==============================================================================
LOG_FILE=""
BACKUP_DIR="/root/remna-universal-backups/$(date +%Y%m%d-%H%M%S)"

strip_ansi() { sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | strip_ansi
    if [[ -n "${LOG_FILE:-}" && -w "$(dirname "$LOG_FILE" 2>/dev/null || echo /tmp)" ]]; then
        echo -e "$msg" | strip_ansi >> "$LOG_FILE" 2>/dev/null || true
    fi
}

init_logging() {
    local path=/var/log/remna-universal.log
    if touch "$path" 2>/dev/null; then
        LOG_FILE="$path"
        log "Лог: $LOG_FILE"
        return 0
    fi
    LOG_FILE="/dev/null"
    echo -e "${WARNING} Логирование в файл отключено, использую /dev/null" >&2
}

log_file() { echo "${LOG_FILE:-/dev/null}"; }

# Ротация общего лога скрипта (ранее не ротировался)
setup_general_logrotate() {
    cat > /etc/logrotate.d/remna-universal <<'EOF'
/var/log/remna-universal.log {
    daily
    maxsize 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 644 /etc/logrotate.d/remna-universal
    log "Logrotate для общего лога: /etc/logrotate.d/remna-universal"
}

backup_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_').bak"
        log "Backup: $f -> $BACKUP_DIR"
    fi
}

# ==============================================================================
# APT-ХЕЛПЕРЫ (с ожиданием блокировки и диагностикой)
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-qq -o Dpkg::Use-Pty=0)

wait_apt_lock() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null >/dev/null; do
        if (( i == 0 )); then echo -ne "${YELLOW}⏳ Жду освобождения apt-lock...${NC}"; fi
        sleep 3; i=$((i+1))
        if (( i > 40 )); then echo -e "\r${CROSS_MARK} apt lock не освободился за 120с${NC}"; return 1; fi
        echo -ne "."
    done
    if (( i > 0 )); then echo -e "\r${CHECK_MARK} apt lock свободен          ${NC}"; fi
    return 0
}

apt_fail_tail() {
    echo -e "${RED}--- последние 40 строк $LOG_FILE ---${NC}" >&2
    tail -n 40 "$(log_file)" >&2 || true
    echo -e "${RED}--- конец лога ---${NC}" >&2
}

apt_update() {
    wait_apt_lock || return 1
    echo -ne "${BLUE}📦 Обновление списков пакетов...${NC}"
    if apt-get update "${APT_OPTS[@]}" >>"$(log_file)" 2>&1; then
        echo -e "\r${GREEN}📦 Списки пакетов обновлены          ${NC}"
    else
        echo -e "\r${CROSS_MARK} ${RED}apt update failed${NC}"
        apt_fail_tail
        return 1
    fi
}

apt_install() {
    wait_apt_lock || return 1
    local pkgs=("$@")
    local pkgs_str
    local IFS=' '
    pkgs_str="${pkgs[*]}"
    echo -ne "${BLUE}📦 Устанавливаю: ${pkgs_str} ...${NC}"
    if apt-get install -y "${APT_OPTS[@]}" "${pkgs[@]}" >>"$(log_file)" 2>&1; then
        echo -e "\r${CHECK_MARK} Установлено: ${pkgs_str}          ${NC}"
        log "apt install OK: ${pkgs_str}"
    else
        echo -e "\r${CROSS_MARK} ${RED}Ошибка установки ${pkgs_str}${NC}"
        apt_fail_tail
        return 1
    fi
}

apt_upgrade_full() {
    wait_apt_lock || return 1
    echo -ne "${BLUE}📦 upgrade / dist-upgrade ...${NC}"
    if apt-get upgrade -y "${APT_OPTS[@]}" >>"$(log_file)" 2>&1 \
    && apt-get dist-upgrade -y "${APT_OPTS[@]}" >>"$(log_file)" 2>&1; then
        echo -e "\r${CHECK_MARK} Система обновлена              ${NC}"
    else
        echo -e "\r${CROSS_MARK} ${RED}upgrade failed${NC}"
        apt_fail_tail
        return 1
    fi
}

apt_autoclean() {
    wait_apt_lock || true
    apt-get autoremove -y "${APT_OPTS[@]}" >>"$(log_file)" 2>&1 || true
    apt-get autoclean -y "${APT_OPTS[@]}" >>"$(log_file)" 2>&1 || true
}

need_cmd() {
    local cmd=$1; shift
    local pkgs=("$@")
    if [[ ${#pkgs[@]} -eq 0 ]]; then pkgs=("$cmd"); fi
    if ! command -v "$cmd" &>/dev/null; then
        apt_install "${pkgs[@]}" || return 1
    fi
}

# ==============================================================================
# ПРОВЕРКИ ОКРУЖЕНИЯ
# ==============================================================================
check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            echo -e "${WARNING_T} ${YELLOW}Скрипт тестировался на Ubuntu/Debian. Ваша ОС: ${PRETTY_NAME:-unknown}. Возможны сбои.${NC}"
        fi
    else
        echo -e "${ERROR_T} ${RED}Не удалось определить операционную систему.${NC}"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$ARCH" in
        amd64|x86_64) ARCH_XRAY="64" ;;
        arm64|aarch64) ARCH_XRAY="arm64-v8a" ;;
        *) echo -e "${ERROR_T} ${RED}Неподдерживаемая архитектура: $ARCH${NC}"; exit 1 ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${CROSS_MARK} ${RED}Нужен root: sudo $0${NC}"
        return 1
    fi
    return 0
}

pause_prompt() { read -r -p "Нажмите Enter для продолжения..." _ || true; }

# Безопасная очистка экрана (не падает без TTY, например при curl | bash или cron)
cls() { clear 2>/dev/null || true; }

show_header() {
    cls
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}🛡️ SAFE REMNANODE SETUP  v${UNIVERSAL_VERSION}${NC}"
    echo -e "${GRAY}   Сервер + Нода + Защита — всё в одном скрипте${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    echo -e "${BLUE} Система: ${PRETTY_NAME:-$(uname -a)}${NC}"
    echo -e "${BLUE} Ядро: $(uname -r)${NC}"
    # Статусы модулей
    local st_node="${RED}не установлена${NC}" st_rkn="${RED}не установлена${NC}" st_srv="${YELLOW}базовая настройка не выполнена${NC}"
    [[ -f /opt/remnanode/docker-compose.yml ]] && st_node="${GREEN}установлена${NC}"
    [[ -d /opt/rkn-watcher && -f /etc/rkn-watcher/settings.conf ]] && st_rkn="${GREEN}установлена${NC}"
    [[ -f /etc/sysctl.d/99-server.conf || -f /etc/sysctl.d/99-remnanode.conf ]] && st_srv="${GREEN}выполнена${NC}"
    echo -e " ${GRAY}Нода:${NC} $st_node   ${GRAY}Защита:${NC} $st_rkn   ${GRAY}Сервер:${NC} $st_srv"
    echo ""
}

RN_APP_DIR="/opt/remnanode"
RN_LOG_DIR="/var/log/remnanode"
RN_NGINX_LOG_DIR="/var/log/nginx"
RN_HOST_NGINX_ROTATE_FILE="/etc/logrotate.d/nginx"
RN_UFW_DEFAULTS_FILE="/etc/default/ufw"
RN_LOG_FILE="/var/log/remnanode_install.log"
RN_XRAY_BIN_DIR="/opt/remnanode/bin"
RN_CERTS_DIR="/opt/remnanode/certs"
RN_WWW_DIR="$RN_APP_DIR/www"
RN_LOGROTATE_FILE="/etc/logrotate.d/remnanode"
RN_RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/safe-remnanode-managed-certs.sh"

RN_XRAY_VERSION_CHOICE="built-in"
RN_NODE_DOMAIN=""
RN_DECOY_DOMAIN="github.com"

rn_log() {
    mkdir -p "$(dirname "$RN_LOG_FILE")"
    echo -e "$1"
    echo "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$RN_LOG_FILE"
}

rn_valid_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 && "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?[.])+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

rn_valid_reality_sni() {
    rn_valid_domain "$1" && [[ ! "$1" =~ ^[0-9.]+$ ]]
}

rn_valid_ipv4() {
    local octet
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})([.](0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    local -a octets
    IFS=. read -ra octets <<< "$1"
    for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done
}

rn_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

rn_public_range_ok() {
    local control="$1" first="${2%%:*}" last="${2##*:}"
    [[ "$2" != *:*:* ]] || return 1
    rn_valid_port "$control" && rn_valid_port "$first" && rn_valid_port "$last" || return 1
    (( first <= last && (control < first || control > last) ))
}
