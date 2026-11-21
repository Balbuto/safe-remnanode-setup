#!/bin/bash
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
#   [3] RKN-Watcher (rkn-watcher.sh v3.1.0 + installer.sh)
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

UNIVERSAL_VERSION="1.1.0+hardening.13"

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'
MAGENTA='\033[0;35m'; NC='\033[0m'

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

# ==============================================================================
# МОДУЛЬ A: НАСТРОЙКА СЕРВЕРА (из Setup-and-Test-Server-Ubuntu-24)
# ==============================================================================
SYSCTL_CONF="/etc/sysctl.d/99-server.conf"
LIMITS_CONF="/etc/security/limits.d/99-server.conf"

clean_old_sysctl() {
    rm -f /etc/sysctl.d/99-server-safe.conf /etc/sysctl.d/99-xray-highload.conf /etc/sysctl.d/99-server-highload.conf 2>/dev/null || true
    rm -f /etc/security/limits.d/99-server-safe.conf /etc/security/limits.d/99-xray.conf /etc/security/limits.d/99-server-highload.conf 2>/dev/null || true
}

install_docker_apt() {
    echo -e "${BLUE}🐳 Установка Docker через официальный apt-репозиторий${NC}"
    apt_update || return 1
    apt_install ca-certificates curl gnupg || return 1
    install -m 0755 -d /etc/apt/keyrings
    # Определяем дистрибутив: URL репозитория и GPG-ключа отличаются для Ubuntu и Debian
    local docker_distro="ubuntu"
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "$ID" = "debian" ]; then
        docker_distro="debian"
    fi
    if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
        if ! curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
            rm -f /etc/apt/keyrings/docker.gpg
            echo -e "${CROSS_MARK} ${RED}Не удалось получить GPG-ключ Docker${NC}"
            return 1
        fi
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    local codename="${VERSION_CODENAME:-}"
    if [ -z "$codename" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "stable")
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt_update || return 1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    systemctl enable --now docker >>"$(log_file)" 2>&1 || true
    local docker_ver
    docker_ver=$(docker --version 2>/dev/null || echo "not found")
    log "Docker установлен: $docker_ver"
}

# BBR + Cake qdisc (заменяет простой BBR в установке сервера)
enable_bbr_cake() {
    echo -e "${BLUE}🌀 Включение BBR + Cake (по мотивам saveksme/multitest)${NC}"
    local current_cc current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    echo -e "Текущий congestion control: ${WHITE}${current_cc}${NC}"
    echo -e "Текущий qdisc:              ${WHITE}${current_qdisc}${NC}"
    echo ""
    # Загрузка модулей (может отсутствовать в контейнере — не критично)
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_cake 2>/dev/null || true
    backup_file /etc/sysctl.d/99-bbr-cake.conf
    cat > /etc/sysctl.d/99-bbr-cake.conf <<'EOF'
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr-cake.conf >>"$(log_file)" 2>&1 || true
    local new_cc new_qdisc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    echo ""
    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "cake" ]]; then
        echo -e "${SUCCESS_T} BBR + Cake успешно включены!"
    else
        echo -e "${WARNING_T} Текущее состояние: cc=${new_cc}, qdisc=${new_qdisc}."
        echo -e "${WARNING_T} Проверьте поддержку ядра (модуль sch_cake)."
    fi
    log "BBR + Cake: cc=${new_cc}, qdisc=${new_qdisc}"
}

apply_sysctl_safe() {
    backup_file "$SYSCTL_CONF"; clean_old_sysctl
    cat > "$SYSCTL_CONF" <<'EOF'
# Server hardening - Ubuntu 24.04 SAFE
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 524288
vm.swappiness = 10
vm.max_map_count = 262144
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.netfilter.nf_conntrack_max = 65536
EOF
    backup_file "$LIMITS_CONF"
    cat > "$LIMITS_CONF" <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    sysctl --system >>"$(log_file)" 2>&1 || true
    log "SAFE sysctl применён"
}

apply_sysctl_highload() {
    echo -e "${WARNING} ${YELLOW}HIGHLOAD профиль: nofile 1M+, conntrack 2M. Для XRAY/VPN на мощных серверах.${NC}"
    if [[ "${1:-}" != "--force" ]]; then
        read -p "Точно применить HIGHLOAD? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] || return 0
    fi
    backup_file "$SYSCTL_CONF"; clean_old_sysctl
    cat > "$SYSCTL_CONF" <<'EOF'
# Server HIGHLOAD - XRAY / VPN
net.core.default_qdisc = cake
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
vm.swappiness = 10
vm.max_map_count = 262144
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 1048576
net.core.netdev_max_backlog = 262144
net.core.optmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_max_syn_backlog = 1048576
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
EOF
    backup_file "$LIMITS_CONF"
    cat > "$LIMITS_CONF" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    sysctl --system >>"$(log_file)" 2>&1 || true
    log "HIGHLOAD sysctl применён"
}

# Автовыбор профиля по объёму ОЗУ (из setup_node.sh)
apply_sysctl_auto() {
    local ram_kb ram_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$((ram_kb / 1024 / 1024))
    log "Обнаружено ОЗУ: ${ram_gb} GB"
    if (( ram_gb >= 2 )); then
        echo -e "${SUCCESS_T} Применяется профиль HIGHLOAD (ОЗУ >= 2 ГБ)"
        apply_sysctl_highload --force
    else
        echo -e "${SUCCESS_T} Применяется профиль SAFE (мало ОЗУ)"
        apply_sysctl_safe
    fi
}

# IPv6 менеджер (объединённый из обоих скриптов)
ipv6_menu() {
    show_header; echo -e "${WHITE}Управление IPv6${NC}\n"
    if sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q 1; then echo -e "Статус: ${RED}Отключён${NC}"; else echo -e "Статус: ${GREEN}Включён${NC}"; fi
    echo ""; echo "1) Отключить IPv6 (с бэкапом + restore-скрипт)"; echo "2) Включить IPv6 обратно"; echo "0) Назад"
    read -r -p "Выбор: " c || c=0
    case $c in
        1)
            backup_file /etc/sysctl.d/70-disable-ipv6.conf
            cat > /etc/sysctl.d/70-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            sysctl --system >>"$(log_file)" 2>&1 || true
            cat > /root/restore-ipv6.sh <<'RESTORE'
#!/bin/bash
rm -f /etc/sysctl.d/70-disable-ipv6.conf
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
sysctl -w net.ipv6.conf.lo.disable_ipv6=0
sysctl --system
echo "IPv6 включён обратно"
RESTORE
            chmod +x /root/restore-ipv6.sh
            echo -e "${CHECK_MARK} IPv6 отключён. Откат: ${YELLOW}/root/restore-ipv6.sh${NC}"
            log "IPv6 disabled"; pause_prompt ;;
        2)
            rm -f /etc/sysctl.d/70-disable-ipv6.conf
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >>"$(log_file)" 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >>"$(log_file)" 2>&1 || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >>"$(log_file)" 2>&1 || true
            sysctl --system >>"$(log_file)" 2>&1 || true
            echo -e "${CHECK_MARK} IPv6 включён"; pause_prompt ;;
    esac
}

base_setup() {
    show_header; echo -e "${WHITE}БАЗОВАЯ НАСТРОЙКА СЕРВЕРА - выберите шаги${NC}\n"
    read -r -p "1. Обновить систему? [Y/n] " a_update; a_update=${a_update:-Y}
    read -r -p "2. Установить базовый софт (mc, net-tools, ncdu, iftop, curl, wget, git)? [Y/n] " a_base; a_base=${a_base:-Y}
    read -r -p "3. Установить Docker (apt + GPG)? [Y/n] " a_docker; a_docker=${a_docker:-Y}
    read -r -p "4. Включить BBR + Cake qdisc? [Y/n] " a_bbr; a_bbr=${a_bbr:-Y}
    echo "5. Hardening профиль: [s]afe / [h]ighload / [a]uto / [n]one"
    read -r -p "Выбор [a]: " a_hard; a_hard=${a_hard:-a}
    read -r -p "6. Установить irqbalance? [Y/n] " a_irq; a_irq=${a_irq:-Y}
    echo ""

    local failed=0
    if [[ $a_update =~ ^[Yy] ]]; then
        apt_update || failed=1
        if ((failed==0)); then apt_upgrade_full || failed=1; fi
        apt_autoclean
        if ((failed)); then echo -e "${CROSS_MARK} ${RED}Обновление системы не удалось, прерываю настройку${NC}"; pause_prompt; return 1; fi
    fi
    if [[ $a_base =~ ^[Yy] ]]; then
        apt_install mc net-tools ncdu iftop curl wget git ca-certificates gnupg lsb-release || { echo -e "${CROSS_MARK} Установка базового софта не удалась"; pause_prompt; return 1; }
    fi
    if [[ $a_docker =~ ^[Yy] ]]; then
        if ! command -v docker &>/dev/null; then
            install_docker_apt || { echo -e "${CROSS_MARK} Установка Docker не удалась"; pause_prompt; return 1; }
        else
            echo "Docker уже установлен"
        fi
    fi
    if [[ $a_bbr =~ ^[Yy] ]]; then enable_bbr_cake; fi

    case $a_hard in
        s|S) apply_sysctl_safe ;;
        h|H) apply_sysctl_highload ;;
        a|A) apply_sysctl_auto ;;
        *) echo "Hardening пропущен" ;;
    esac

    if [[ $a_irq =~ ^[Yy] ]]; then
        apt_install irqbalance || echo -e "${WARNING} irqbalance не установился, пропускаю"
        systemctl enable --now irqbalance >>"$(log_file)" 2>&1 || true
    fi

    echo -e "\n${CHECK_MARK} Готово! Бэкапы в: $BACKUP_DIR"
    echo -e "Полный лог: ${BLUE}$LOG_FILE${NC}"
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${WARNING} Требуется перезагрузка"
        read -p "Перезагрузить сейчас? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && reboot
    fi
    pause_prompt
}

# Статус UFW
manage_ufw() {
    show_header; check_root || { pause_prompt; return; }
    if ! command -v ufw >/dev/null; then
        echo 'UFW не установлен.'
    else
        ufw status verbose || echo 'Не удалось получить статус UFW.'
    fi
    pause_prompt
}
# ==============================================================================
# МОДУЛЬ B: УСТАНОВКА И УПРАВЛЕНИЕ НОДОЙ REMNAWAVE (из setup_node.sh v1.7.2)
# ==============================================================================
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

# --- Сетевая оптимизация с автовыбором профиля по ОЗУ ---
rn_optimize_network() {
    rn_log "${INFO_T} Настройка сетевого стека..."
    backup_file /etc/sysctl.d/99-remnanode.conf || return 1
    backup_file /etc/security/limits.d/99-remnanode.conf || return 1
    local ram_kb ram_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$((ram_kb / 1024 / 1024))
    rn_log "${INFO_T} Обнаружено ОЗУ: ${ram_gb} GB"

    if [ "$ram_gb" -ge 2 ]; then
        rn_log "${SUCCESS_T} Применяется профиль HIGHLOAD для оптимальной работы VPN"
        cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Limits & Buffer Tuning
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
vm.swappiness = 10
vm.max_map_count = 262144

net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Conntrack
net.netfilter.nf_conntrack_max = 1048576
EOF
    else
        rn_log "${SUCCESS_T} Применяется профиль SAFE (консервативный) для VPS с малым объемом памяти"
        cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 524288
vm.swappiness = 10
vm.max_map_count = 262144

net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Conntrack
net.netfilter.nf_conntrack_max = 65536
EOF
    fi

    cat > /etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    sysctl -p /etc/sysctl.d/99-remnanode.conf >> "$RN_LOG_FILE" 2>&1 || return 1
    rn_log "${SUCCESS_T} Сетевые параметры ядра и системные лимиты успешно обновлены."
}

# --- Установка зависимостей ноды (с переиспользованием установленного Docker) ---
rn_install_dependencies() {
    rn_log "${INFO_T} Установка необходимых пакетов..."
    apt_update || return 1
    apt_install curl jq unzip logrotate ufw certbot ca-certificates gnupg openssl iproute2 util-linux || return 1

    if ! command -v docker &> /dev/null; then
        rn_log "${INFO_T} Docker не найден — установка через официальный репозиторий..."
        install_docker_apt || { rn_log "${ERROR_T} Не удалось установить Docker!"; return 1; }
    else
        rn_log "${SUCCESS_T} Docker уже установлен."
    fi
    docker compose version >> "$RN_LOG_FILE" 2>&1 && docker info >> "$RN_LOG_FILE" 2>&1 || return 1
    if ! docker compose up --help 2>> "$RN_LOG_FILE" | grep -- ' --wait ' >/dev/null; then
        rn_log "${ERROR_T} Нужен Docker Compose с поддержкой up --wait."
        return 1
    fi
}

# --- Менеджер версий Xray-Core ---
rn_valid_xray_tag() {
    [[ "$1" =~ ^v[0-9]+([.][0-9]+){1,3}([.-][A-Za-z0-9]+)*$ ]]
}

rn_prepare_xray_version() {
    local version="$1"
    rn_valid_xray_tag "$version" || { rn_log "${ERROR_T} Некорректный тег релиза Xray-Core."; return 1; }
    if ! rn_download_xray_core "$version"; then
        rn_log "${ERROR_T} Не удалось скачать или проверить Xray-Core $version. Работающий деплой не изменён."
        return 1
    fi
    RN_XRAY_VERSION_CHOICE="$version"
    rn_log "${SUCCESS_T} Xray-Core $version скачан и проверен."
}

rn_prepare_latest_xray() {
    local release version
    rn_log "${INFO_T} Запрашиваю последний стабильный релиз Xray-Core на GitHub..."
    if ! release=$(curl -fsSL --proto '=https' --connect-timeout 5 --max-time 20 \
        --retry 2 --retry-max-time 30 --header 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/XTLS/Xray-core/releases/latest' 2>>"$RN_LOG_FILE"); then
        rn_log "${ERROR_T} API GitHub недоступен. Проверьте подключение и повторите; встроенная версия не подставляется."
        return 1
    fi
    if ! version=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | strings' <<< "$release" 2>>"$RN_LOG_FILE"); then
        rn_log "${ERROR_T} GitHub не вернул корректный стабильный релиз."
        return 1
    fi
    rn_prepare_xray_version "$version"
}

rn_download_xray_core() (
    local version="$1" dir archive digest url
    rn_valid_xray_tag "$version" || return 1
    archive="Xray-linux-${ARCH_XRAY}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/${archive}"
    dir=$(mktemp -d "$RN_APP_DIR/.xray-download.XXXXXXXX") || return 1
    trap 'rm -rf -- "$dir"' EXIT
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 180 -o "$dir/release.zip" "$url" || return 1
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 30 -o "$dir/release.dgst" "$url.dgst" || return 1
    digest=$(awk 'toupper($0) ~ /SHA(2-)?256/ {print $NF; exit}' "$dir/release.dgst")
    [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
    printf '%s  %s\n' "$digest" "$dir/release.zip" | sha256sum -c --status || return 1
    mkdir -p "$RN_XRAY_BIN_DIR" || return 1
    install -d -m 0755 "$dir/bin" || return 1
    local name mode
    for name in xray geoip.dat geosite.dat; do
        mode=0644
        [[ "$name" != xray ]] || mode=0755
        unzip -p "$dir/release.zip" "$name" > "$dir/bin/$name" && [[ -s "$dir/bin/$name" ]] || return 1
        chmod "$mode" "$dir/bin/$name" || return 1
    done
    if [[ -e "$RN_XRAY_BIN_DIR/$version" ]]; then
        for name in xray geoip.dat geosite.dat; do
            cmp -s "$dir/bin/$name" "$RN_XRAY_BIN_DIR/$version/$name" || {
                rn_log "${ERROR_T} Содержимое существующей версии $version отличается. Файлы не изменены."
                return 1
            }
        done
        return 0
    fi
    mv -T -- "$dir/bin" "$RN_XRAY_BIN_DIR/$version"
)

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

rn_valid_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 && "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?[.])+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

rn_valid_reality_sni() {
    rn_valid_domain "$1" && [[ ! "$1" =~ ^[0-9.]+$ ]]
}

rn_prompt_reality_sni() {
    local sni
    printf '%s\n' 'Укажите DNS-имя SNI из Reality-профиля Remnawave (serverNames), не адрес ноды.'
    while read -r -p 'SNI для VLESS-Reality (например www.example.org): ' sni; do
        if rn_valid_reality_sni "$sni"; then
            RN_DECOY_DOMAIN="${sni,,}"
            printf 'SNI: %s. Установщик использует его в nginx; профиль Remnawave не изменяется.\n' "$RN_DECOY_DOMAIN"
            return 0
        fi
        printf '%s\n' 'Введите полное DNS-имя без https://, порта, пути или wildcard. IP не подходит.' >&2
    done
    rn_log "${ERROR_T} SNI не задан. Установка не продолжена."
    return 1
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

# --- Встроенные статические шаблоны без внешних ресурсов ---
# Фиксированный каталог: идентификатор темы не используется как имя файла или команда.
rn_render_page_template() (
    local template="${1:-status}" title subtitle label bg surface fg muted accent
    case "$template" in
        status)
            title='Технические работы'; subtitle='Мы обновляем сайт. Пожалуйста, зайдите немного позже.'
            label='Обслуживание'; bg='#eef3f8'; surface='#ffffff'; fg='#15263b'; muted='#43546b'; accent='#174da1'
            ;;
        minimal)
            title='Скоро вернёмся'; subtitle='Страница временно недоступна. Спасибо за терпение.'
            label='Уведомление'; bg='#f8f2e7'; surface='#fffdfa'; fg='#2f2118'; muted='#655346'; accent='#923416'
            ;;
        dark)
            title='Сайт временно недоступен'; subtitle='Сервис на паузе, пока мы проводим обслуживание.'
            label='Техническая пауза'; bg='#101722'; surface='#1a2636'; fg='#f1f6fd'; muted='#b5c3d5'; accent='#81e3ba'
            ;;
        *) return 1 ;;
    esac

    install -d -m 0755 "$RN_WWW_DIR" || return 1
    local tmp
    tmp=$(mktemp "$RN_WWW_DIR/.index.XXXXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    cat > "$tmp" <<EOF || return 1
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="$([[ "$template" == dark ]] && printf dark || printf light)">
<meta name="remnanode-template" content="$template">
<title>$title</title>
<style>
:root{background:$bg;color:$fg;font-family:system-ui,sans-serif}
*{box-sizing:border-box}
body{min-height:100vh;margin:0;display:grid;place-items:center;padding:1.5rem}
main{background:$surface;width:min(100%,39rem);padding:clamp(1.75rem,7vw,4rem);border-radius:1.25rem;border:1px solid $muted}
.tag{color:$accent;font-size:.8rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase}
h1{font-size:clamp(2rem,7vw,3.6rem);line-height:1.04;letter-spacing:-.04em;margin:1rem 0;overflow-wrap:anywhere}
p{font-size:1.05rem;line-height:1.6;color:$muted;margin-bottom:0}
</style>
</head>
<body><main>
<div class="tag">$label</div>
<h1>$title</h1>
<p>$subtitle</p>
</main></body>
</html>
EOF
    chmod 0644 "$tmp" && mv -fT -- "$tmp" "$RN_WWW_DIR/index.html"
)

rn_pick_page_template() {
    local selection
    local -a templates=(status minimal dark)
    printf '%s\n' 'Темы: 1 — статус, 2 — минимализм, 3 — тёмная, 4 — случайная, 0 — отмена.' >&2
    read -r -p 'Выберите тему [1]: ' selection || return 1
    case "${selection:-1}" in
        1) printf 'status\n' ;;
        2) printf 'minimal\n' ;;
        3) printf 'dark\n' ;;
        4) printf '%s\n' "${templates[RANDOM % ${#templates[@]}]}" ;;
        0) return 2 ;;
        *) printf '%s\n' 'Некорректный номер темы.' >&2; return 1 ;;
    esac
}

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

rn_cert_covers_host() {
    LC_ALL=C openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null | grep -F 'does match certificate' >/dev/null
}

rn_cert_key_matches() {
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$2" -passin pass: -pubout 2>/dev/null) || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

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

rn_load_node_state() {
    RN_XRAY_VERSION_CHOICE=built-in
    RN_DECOY_DOMAIN=github.com
    if [[ -f "$RN_APP_DIR/.xray_version" ]]; then
        IFS= read -r RN_XRAY_VERSION_CHOICE < "$RN_APP_DIR/.xray_version" || return 1
    elif [[ -f "$RN_APP_DIR/docker-compose.yml" ]] && grep -q '/bin/xray:/usr/local/bin/xray' "$RN_APP_DIR/docker-compose.yml"; then
        RN_XRAY_VERSION_CHOICE=legacy
    fi
    if [[ -f "$RN_APP_DIR/.decoy_domain" ]]; then
        IFS= read -r RN_DECOY_DOMAIN < "$RN_APP_DIR/.decoy_domain" || return 1
    elif [[ -f "$RN_APP_DIR/nginx.conf" ]]; then
        local existing
        existing=$(awk '$1 == "server_name" && $2 != "_;" {sub(/;$/, "", $2); print $2; exit}' "$RN_APP_DIR/nginx.conf") || return 1
        if rn_valid_domain "$existing"; then RN_DECOY_DOMAIN="$existing"; fi
    fi
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

# --- Первоначальная установка ноды (полный интерактивный флоу) ---
rn_initial_setup() {
    cls
    rn_log "${INFO_T} Запуск первоначальной настройки и установки ноды..."
    rn_prepare_ufw_initial || return 1

    if [ -f "$RN_APP_DIR/docker-compose.yml" ]; then
        echo -e "${WARNING_T} Нода уже установлена. Повторная установка ПЕРЕЗАПИШЕТ"
        echo -e "${WARNING_T} secret key и конфигурацию — панель потеряет текущую ноду."
        read -r -p "Всё равно продолжить? (y/N): " reinstall
        [[ "${reinstall:-n}" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Отменено.${NC}"; return; }
    fi

    mkdir -p "$RN_APP_DIR" || return 1
    rn_load_node_state || return 1

    echo ""
    echo -e "${BLUE}⚙️  ЭТАП 1: СЕТЕВАЯ ОПТИМИЗАЦИЯ И ЗАВИСИМОСТИ${NC}"
    read -r -p "Применить сетевую оптимизацию (BBR + sysctl профиль по ОЗУ)? [y/N]: " do_opt; do_opt=${do_opt:-N}
    if [[ $do_opt =~ ^[Yy] ]]; then rn_optimize_network || return 1; fi
    if ! rn_install_dependencies; then
        rn_log "${ERROR_T} Установка зависимостей не удалась — установка ноды прервана."
        pause_prompt
        return 1
    fi

    echo ""
    echo -e "${BLUE}⚙️  ЭТАП 2: ВЕРСИЯ XRAY-CORE${NC}"
    rn_prepare_latest_xray || return 1

    echo -e "\n${BLUE}🔌 НАСТРОЙКА ИДЕНТИФИКАЦИИ И СВЯЗИ С ПАНЕЛЬЮ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    read -r -p "Введите IP адрес панели Remnawave (для настройки UFW): " panel_ip || return 1
    while ! rn_valid_ipv4 "$panel_ip"; do
        read -r -p "${RED}Неверный формат IP. Введите корректный IPv4 панели: ${NC}" panel_ip || return 1
    done

    read -r -p "Введите домен вашей ноды (например, node.example.com): " node_domain
    while ! rn_valid_domain "$node_domain"; do
        read -r -p "${RED}Введите корректное DNS-имя ноды: ${NC}" node_domain || return 1
    done
    RN_NODE_DOMAIN="$node_domain"

    read -r -p "Порт управления нодой (для панели) [2222]: " node_port
    node_port=${node_port:-2222}
    if ! rn_public_range_ok "$node_port" 80 || ! rn_public_range_ok "$node_port" 443; then
        rn_log "${ERROR_T} Некорректный или зарезервированный порт управления."
        return 1
    fi

    if [[ -f "$RN_APP_DIR/docker-compose.yml" ]]; then
        local previous_port previous_ip
        previous_port=$(sed -n 's/^NODE_PORT=//p' "$RN_APP_DIR/.env") || return 1
        IFS= read -r previous_ip < "$RN_APP_DIR/.panel_ip" || return 1
        if [[ "$node_port" != "$previous_port" || "$panel_ip" != "$previous_ip" ]]; then
            rn_log "${ERROR_T} При переустановке порт и IP панели должны совпадать с текущими. Для смены IP используйте отдельный пункт меню."
            return 1
        fi
    fi
    echo -e "\n${YELLOW}Вставьте сертификат ноды (secret key), выданный в панели Remnawave${NC}"
    echo -e "${GRAY}(Для окончания ввода нажмите Enter дважды подряд):${NC}"
    local certificate=""
    while IFS= read -rs line; do
        if [ -z "$line" ]; then
            if [ -n "$certificate" ]; then
                break
            fi
        else
            certificate="${certificate}${line}\n"
        fi
    done

    printf '\n'
    local secret_key_value; secret_key_value=$(printf '%b' "$certificate" | xargs) || return 1
    while [ -z "$secret_key_value" ]; do
        rn_log "${ERROR_T} Сертификат не может быть пустым!"
        return 1
    done

    echo -e "\nВыберите конфигурацию ноды:"
    echo " 1) VLESS-Reality (с выбором SNI)"
    echo " 2) VLESS+TLS"
    echo " 3) VLESS+xHTTP+TLS"
    echo " 4) VLESS+TLS + VLESS+xHTTP+TLS + Hy2 одновременно"
    read -r -p "Ваш выбор [1]: " proto_choice || return 1
    local protocol transport_plan=""
    local -a new_public_ports=()
    local entry vless_tls_tcp vless_xhttp hy2_udp
    case "${proto_choice:-1}" in
        1) protocol=reality; rn_prompt_reality_sni || return 1 ;;
        2) protocol=tls ;;
        3) protocol=xhttp ;;
        4) protocol=combined ;;
        *) rn_log "${ERROR_T} Неизвестный вариант конфигурации."; return 1 ;;
    esac
    if [[ "$protocol" == combined ]]; then
        printf '%s\n' 'Укажите порты из панели Remnawave. Установщик не создаёт и не меняет inbounds.'
        read -r -p 'VLESS+TLS, TCP-порт: ' vless_tls_tcp || return 1
        read -r -p 'VLESS+xHTTP+TLS, порт (например 2053/tcp или 1500/udp для HTTP/3): ' vless_xhttp || return 1
        read -r -p 'Hy2, UDP-порт: ' hy2_udp || return 1
        if ! rn_validate_transport_ports "$node_port" "$vless_tls_tcp" "$vless_xhttp" "$hy2_udp"; then
            rn_log "${ERROR_T} Укажите TCP-порт VLESS TLS, порт xHTTP (/tcp или /udp), UDP-порт Hy2. Конфликты портов одного протокола, порт управления и 61000 не допускаются."
            return 1
        fi
        transport_plan=$(rn_format_transport_plan "$vless_tls_tcp" "$vless_xhttp" "$hy2_udp") || return 1
    else
        echo -e "\n${BLUE}⚙️  ВХОДЯЩИЕ ПОРТЫ ДЛЯ КЛИЕНТОВ XRAY${NC}"
        echo "По умолчанию порты 80 и 443 будут открыты автоматически."
        read -r -p "Дополнительные порты для Xray в UFW (через пробел) [Нет]: " add_ports_choice || return 1
        read -ra new_public_ports <<< "${add_ports_choice//,/ }"
        for entry in "${new_public_ports[@]}"; do
            if ! rn_public_range_ok "$node_port" "$entry"; then
                rn_log "${ERROR_T} Некорректный клиентский порт или диапазон: $entry"
                return 1
            fi
        done
    fi

    local template=status template_rc=0
    if [[ ! -f "$RN_WWW_DIR/index.html" ]]; then
        template=$(rn_pick_page_template) || template_rc=$?
        if (( template_rc == 2 )); then rn_log "${WARNING_T} Установка отменена."; return 1; fi
        (( template_rc == 0 )) || return 1
    fi
    if [[ "$protocol" == combined ]]; then
        rn_configure_combined_firewall "$node_port" "$panel_ip" "$vless_tls_tcp" "$vless_xhttp" "$hy2_udp" || return 1
    else
        rn_configure_firewall "$node_port" "$panel_ip" "${new_public_ports[@]}" || return 1
    fi
    if [[ "$protocol" != reality ]]; then
        rn_issue_ssl_certificates_multi "$RN_NODE_DOMAIN" "$protocol" "$transport_plan" || { pause_prompt; return 1; }
    fi
    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" "$RN_NODE_DOMAIN" "$template" '' "$transport_plan" || { pause_prompt; return 1; }

    printf '%s\n' "$panel_ip" > "$RN_APP_DIR/.panel_ip" || return 1

    # Регистрация глобальных команд
    register_global_commands || return 1

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "🎉   УСТАНОВКА И НАСТРОЙКА НОДЫ УСПЕШНО ЗАВЕРШЕНА!   🎉"
    echo -e "Вы можете запускать это меню командой: ${CYAN}remnanode${NC}"
    echo -e "${GREEN}========================================================${NC}"

    pause_prompt
}

# --- Смена домена ноды и перевыпуск SSL ---
rn_change_domain_and_ssl() {
    cls
    echo -e "${BLUE}🔐 СМЕНА ДОМЕНА НОДЫ И ПЕРЕВЫПУСК SSL${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
        rn_log "${ERROR_T} Нода еще не установлена! Пожалуйста, выполните первоначальную настройку."
        pause_prompt
        return
    fi

    read -r -p "Введите новый домен вашей ноды: " new_domain
    while ! rn_valid_domain "$new_domain"; do
        read -r -p "${RED}Введите корректное DNS-имя: ${NC}" new_domain || return 1
    done
    RN_NODE_DOMAIN="$new_domain"
    rn_load_node_state || return 1

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$RN_APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$RN_APP_DIR/.protocol" 2>/dev/null || echo "tls")

    if [[ "$protocol" != reality ]]; then
        rn_issue_ssl_certificates_multi "$RN_NODE_DOMAIN" "$protocol" || { pause_prompt; return 1; }
    fi

    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" "$RN_NODE_DOMAIN" || { pause_prompt; return 1; }

    rn_log "${SUCCESS_T} Домен ноды успешно изменен на $RN_NODE_DOMAIN, конфигурация обновлена!"
    pause_prompt
}

# --- Установка кастомной версии Xray Core ---
rn_update_xray_core_only() {
    cls
    echo -e "${BLUE}⚡ ОБНОВЛЕНИЕ XRAY-CORE С GITHUB${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
        rn_log "${ERROR_T} Нода еще не установлена! Пожалуйста, выполните первоначальную настройку."
        pause_prompt
        return
    fi

    rn_load_node_state || return 1
    local choice tag
    printf '%s\n' '1) Последний стабильный релиз' '2) Указать тег вручную' '0) Отмена'
    read -r -p 'Версия [1]: ' choice || return 1
    case "${choice:-1}" in
        1) rn_prepare_latest_xray || return 1 ;;
        2)
            read -r -p 'Тег релиза Xray-Core: ' tag || return 1
            rn_prepare_xray_version "$tag" || return 1
            ;;
        0) return 0 ;;
        *) rn_log "${ERROR_T} Некорректный выбор."; return 1 ;;
    esac

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$RN_APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$RN_APP_DIR/.protocol" 2>/dev/null || echo "reality")
    RN_NODE_DOMAIN=$(cat "$RN_APP_DIR/.node_domain" 2>/dev/null || true)

    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" "$RN_NODE_DOMAIN" || { pause_prompt; return 1; }

    rn_log "${SUCCESS_T} Версия Xray-Core успешно обновлена!"
    pause_prompt
}

# --- Смена IP панели ---
rn_change_panel_ip() {
    cls
    echo -e "${BLUE}🔌 СМЕНА IP АДРЕСА ПАНЕЛИ (UFW RULE UPDATE)${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
        rn_log "${ERROR_T} Нода еще не установлена!"
        pause_prompt
        return
    fi

    local old_panel_ip; old_panel_ip=$(cat "$RN_APP_DIR/.panel_ip" 2>/dev/null || echo "")
    rn_log "${INFO_T} Текущий разрешенный IP панели: ${YELLOW}${old_panel_ip:-Не определен}${NC}"

    read -r -p "Введите новый IP адрес панели: " new_panel_ip
    while ! rn_valid_ipv4 "$new_panel_ip"; do
        read -r -p "${RED}Неверный формат IP. Введите корректный IPv4: ${NC}" new_panel_ip || return 1
    done

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")

    rn_valid_port "$node_port" || return 1
    if [[ "$new_panel_ip" == "$old_panel_ip" ]]; then return 0; fi
    rn_ufw_allow from "$new_panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel' || return 1
    if rn_valid_ipv4 "$old_panel_ip"; then
        ufw delete allow from "$old_panel_ip" to any port "$node_port" proto tcp >> "$RN_LOG_FILE" 2>&1 || {
            rn_log "${ERROR_T} Новое правило добавлено, старое не удалено. Проверьте UFW; состояние не изменено."
            return 1
        }
    fi
    printf '%s\n' "$new_panel_ip" > "$RN_APP_DIR/.panel_ip" || return 1

    rn_log "${SUCCESS_T} Разрешенный IP панели изменен на $new_panel_ip. Проверьте эффективную политику UFW для порта $node_port."
    pause_prompt
}

# --- Полное удаление ноды с откатом изменений ---
rn_uninstall_and_rollback() {
    cls
    echo -e "${RED}Удаление контейнеров и файлов ноды. UFW, sysctl, оригиналы Certbot и общий webroot не меняются.${NC}"
    local confirm
    read -r -p "Продолжить? (y/N): " confirm || return 1
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    if [[ ! -f "$RN_APP_DIR/docker-compose.yml" ]]; then
        rn_log "${WARNING_T} Не найден docker-compose.yml; ничего не удалено."
        return 1
    fi
    if ! (cd "$RN_APP_DIR" && docker compose down) >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${ERROR_T} Docker не остановлен. Файлы ноды оставлены на месте."
        return 1
    fi
    rm -f -- "$RN_LOGROTATE_FILE" || return 1
    if [[ -f "$RN_RENEW_HOOK" && $(head -n 2 "$RN_RENEW_HOOK" | tail -n 1) == '# safe-remnanode managed certificate hook' ]]; then
        rm -f -- "$RN_RENEW_HOOK" || return 1
    fi
    rm -rf -- "$RN_APP_DIR" || return 1
    echo 'Нода удалена. Логи сохранены. Проверьте UFW, параметры ядра и старый Certbot hook вручную.'
    pause_prompt
}

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

# --- Диагностика и просмотр логов ноды ---
rn_diagnose_and_logs() {
    (
        set +e
        set +o pipefail
        trap - INT

        while true; do
            cls
            echo -e "${GREEN}"
            echo "  ========================================================"
            echo "  📊 ДИАГНОСТИКА И ПРОСМОТР ЛОГОВ НОДЫ"
            echo "  ========================================================"
            echo -e "${NC}"

            if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
                echo -e "${RED} Нода еще не установлена! Логи недоступны.${NC}"
                pause_prompt
                return
            fi

            echo -e "📌 ${WHITE}Ресурсы сервера:${NC}"
            local cpu_use; cpu_use=$(ps -eo pcpu 2>/dev/null | awk 'NR>1 {sum+=$1} END {print sum}')
            if [ -z "$cpu_use" ] || [ "$cpu_use" = "0" ]; then
                cpu_use="Недоступно"
            else
                local cores; cores=$(nproc 2>/dev/null || echo 1)
                cpu_use=$(awk "BEGIN {print int($cpu_use/$cores)}")"%"
            fi

            local mem_info; mem_info=$(free -h 2>/dev/null | grep "Mem:")
            local mem_used; mem_used=$(echo "$mem_info" | awk '{print $3}' || echo "N/A")
            local mem_total; mem_total=$(echo "$mem_info" | awk '{print $2}' || echo "N/A")
            local mem_use="${mem_used} / ${mem_total}"

            local disk_use; disk_use=$(df -h "$RN_APP_DIR" 2>/dev/null | tail -1 | awk '{print $5 " (Свободно " $4 ")"}' || echo "Недоступно")

            echo -e "   - Загрузка CPU:     ${CYAN}$cpu_use${NC}"
            echo -e "   - Использование ОЗУ: ${CYAN}$mem_use${NC}"
            echo -e "   - Занято на диске:   ${CYAN}$disk_use${NC}"

            echo -e "\n📌 ${WHITE}Статус Docker контейнеров:${NC}"
            local node_status="${RED}○ Остановлен${NC}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnanode"; then
                node_status="${GREEN}● Запущен${NC}"
            fi

            local nginx_status="${RED}○ Остановлен${NC}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-nginx"; then
                nginx_status="${GREEN}● Запущен${NC}"
            fi

            echo -e "   - remnanode:        $node_status"
            echo -e "   - remnawave-nginx:  $nginx_status"

            echo -e "\n📌 ${WHITE}Размер лог-файлов на хосте:${NC}"
            local node_acc_size; node_acc_size=$(du -sh "$RN_LOG_DIR/access.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local node_err_size; node_err_size=$(du -sh "$RN_LOG_DIR/error.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_log_dir; nginx_log_dir=$(rn_nginx_log_dir)
            local nginx_acc_size; nginx_acc_size=$(du -sh "$nginx_log_dir/access.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_err_size; nginx_err_size=$(du -sh "$nginx_log_dir/error.log" 2>/dev/null | awk '{print $1}' || echo "0B")

            echo -e "   - Xray access.log:  ${CYAN}$node_acc_size${NC}"
            echo -e "   - Xray error.log:   ${CYAN}$node_err_size${NC}"
            echo -e "   - Nginx access.log:  ${CYAN}$nginx_acc_size${NC}"
            echo -e "   - Nginx error.log:   ${CYAN}$nginx_err_size${NC}"

            echo -e "${GRAY}--------------------------------------------------${NC}"
            echo " 1) 📥 Лог запросов Xray (access.log) в реальном времени"
            echo " 2) 📥 Лог ошибок Xray (error.log) в реальном времени"
            echo " 3) 📥 Лог запросов веб-сервера Nginx в реальном времени"
            echo " 4) 📥 Вывод логов из контейнера Docker (remnanode)"
            echo " 5) 🔄 Вынужденно применить ротацию логов (logrotate)"
            echo " 0) Назад"
            echo -e "${GRAY}--------------------------------------------------${NC}"
            read -r -p "Выберите действие [0-5]: " log_choice
            log_choice=${log_choice:-0}

            case $log_choice in
                1)
                    cls
                    echo -e "${BLUE}Показ лога access.log (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$RN_LOG_DIR/access.log" || true
                    ;;
                2)
                    cls
                    echo -e "${BLUE}Показ лога error.log (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$RN_LOG_DIR/error.log" || true
                    ;;
                3)
                    cls
                    echo -e "${BLUE}Показ лога Nginx (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -F "$nginx_log_dir/access.log" || true
                    ;;
                4)
                    cls
                    echo -e "${BLUE}Показ Docker-логов remnanode (Выход: Ctrl+C)...${NC}\n"
                    docker compose -f "$RN_APP_DIR/docker-compose.yml" logs -f --tail=100 remnanode || true
                    ;;
                5)
                    echo -e "${INFO_T} Запуск принудительной ротации логов..."
                    if logrotate -f "$RN_LOGROTATE_FILE"; then
                        echo -e "${SUCCESS_T} Ротация логов успешно выполнена!"
                    else
                        echo -e "${ERROR_T} Ошибка выполнения ротации!"
                    fi
                    sleep 1.5
                    ;;
                0)
                    return
                    ;;
            esac
        done
    )
}

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

# --- Управление локальным HTML-шаблоном ---
rn_change_decoy_template_menu() {
    local template rc=0
    if [[ ! -f "$RN_APP_DIR/docker-compose.yml" ]]; then
        rn_log "${ERROR_T} Нода ещё не установлена."
        pause_prompt
        return 0
    fi
    template=$(rn_pick_page_template) || rc=$?
    if (( rc == 2 )); then return 0; fi
    if (( rc != 0 )) || ! rn_render_page_template "$template"; then
        rn_log "${ERROR_T} Не удалось обновить HTML-шаблон."
    elif grep -Fq -- "$RN_WWW_DIR:/var/www/html:ro" "$RN_APP_DIR/docker-compose.yml"; then
        rn_log "${SUCCESS_T} Тема $template применена без перезапуска контейнера."
    else
        rn_log "${SUCCESS_T} Тема $template сохранена; старый деплой подключит новый webroot при обновлении Compose."
    fi
    pause_prompt
}

# --- Меню управления нодой ---
rn_node_menu() {
    while true; do
        cls
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🔧 УПРАВЛЕНИЕ НОДОЙ REMNAWAVE (v1.7.2 совместимость)"
        echo "  ========================================================"
        echo -e "${NC}"

        local status="Не установлена"
        local color="$RED"
        if [ -f "$RN_APP_DIR/docker-compose.yml" ]; then
            if docker ps 2>/dev/null | grep -q "remnanode"; then
                status="Активна (Запущена)"
                color="$GREEN"
            else
                status="Установлена (Остановлена)"
                color="$YELLOW"
            fi
        fi

        echo -e "📌 Текущий статус ноды: ${color}${status}${NC}"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        echo " 1) 🚀 Первоначальная настройка и запуск ноды"
        echo " 2) 🔐 Выпуск и обновление SSL при смене домена ноды"
        echo " 3) ⚡ Установка/Обновление кастомной версии Xray-Core"
        echo " 4) 🔌 Смена IP адреса панели (Обновление правил UFW)"
        echo " 5) 🔌 Управление клиентскими портами Xray и UFW"
        echo " 6) 🎭 Настроить HTML-шаблон"
        echo " 7) 📊 Диагностика и просмотр логов ноды"
        echo " 8) 🗑️  Удаление ноды без сброса UFW"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -r -p "Выберите действие [0-8]: " menu_choice
        menu_choice=${menu_choice:-0}

        case $menu_choice in
            1) rn_initial_setup || { rn_log "${ERROR_T} Установка не завершена."; pause_prompt; } ;;
            2) rn_change_domain_and_ssl || { rn_log "${ERROR_T} Смена домена не завершена."; pause_prompt; } ;;
            3) rn_update_xray_core_only || { rn_log "${ERROR_T} Обновление Xray не завершено."; pause_prompt; } ;;
            4) rn_change_panel_ip || { rn_log "${ERROR_T} Смена IP не завершена."; pause_prompt; } ;;
            5) rn_manage_xray_ports ;;
            6) rn_change_decoy_template_menu ;;
            7) rn_diagnose_and_logs ;;
            8) rn_uninstall_and_rollback ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}
# ==============================================================================
# МОДУЛЬ C: ЗАЩИТА НОДЫ — RKN-WATCHER (из RKN-Watcher v3.1.0)
# Защита от сканеров РКН и госструктур РФ:
#   - TSPUBLOCK / GOVIPS блок-листы (iptables + ipset, атомарное обновление)
#   - GeoIP-фильтрация по странам (allow-список), allow/deny IP и порты
#   - systemd timer для автообновления списков, boot-восстановление правил
# ==============================================================================
RKN_VERSION="3.1.0"
RKN_APP_NAME="RKN Watcher"

RKN_INSTALL_DIR="/opt/rkn-watcher"
RKN_CONFIG_DIR="/etc/rkn-watcher"
RKN_DATA_DIR="/var/lib/rkn-watcher"
RKN_CACHE_DIR="$RKN_DATA_DIR/cache"
RKN_COUNTRY_CACHE_DIR="$RKN_CACHE_DIR/countries"
RKN_STATE_DIR="$RKN_DATA_DIR/state"
RKN_LOCK_DIR="$RKN_DATA_DIR/locks"
RKN_LOG_DIR="/var/log/rkn-watcher"

RKN_MAIN_SCRIPT="$RKN_INSTALL_DIR/rkn-watcher.sh"
RKN_CONFIG_TOOL="$RKN_INSTALL_DIR/config_tool.py"
RKN_GEOIP_APPLY_SCRIPT="$RKN_INSTALL_DIR/geoip_apply.py"
RKN_BIN_PATH="/usr/local/bin/rkn-watcher"

RKN_SETTINGS_FILE="$RKN_CONFIG_DIR/settings.conf"
RKN_WHITELIST_FILE="$RKN_CONFIG_DIR/whitelist.json"
RKN_BLACKLIST_FILE="$RKN_CONFIG_DIR/blacklist.json"
RKN_IPSET_STATE_FILE="$RKN_STATE_DIR/ipset.conf"
RKN_UPDATE_LOCK_FILE="$RKN_LOCK_DIR/update.lock"
RKN_UPDATE_LOG="$RKN_LOG_DIR/update.log"
RKN_ACTION_LOG="$RKN_LOG_DIR/actions.log"
RKN_GEOIP_LOG="$RKN_LOG_DIR/geoip.log"

RKN_BOOT_SERVICE="/etc/systemd/system/rkn-watcher-boot.service"
RKN_UPDATE_SERVICE="/etc/systemd/system/rkn-watcher-update.service"
RKN_UPDATE_TIMER="/etc/systemd/system/rkn-watcher-update.timer"

RKN_PKG_MANIFEST="$RKN_STATE_DIR/installer-packages.txt"
RKN_REQUIRED_PACKAGES=(iptables ipset curl ca-certificates python3 util-linux)
RKN_MANAGED_IPSETS=(TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW)
RKN_MANAGED_CHAINS=(TSPUBLOCK GOVBLOCK GEOIP_DROP RKN_GEOIP_HOOK)

rkn_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
rkn_success() { echo -e "${GREEN}[OK]${NC} $*"; }
rkn_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
rkn_error() { echo -e "${RED}[ERR]${NC} $*"; }
rkn_title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
rkn_subtitle() { echo -e "${MAGENTA}───────────────────────────────────────────────────────────────${NC}"; }

rkn_ensure_dirs() {
    mkdir -p "$RKN_INSTALL_DIR" "$RKN_CONFIG_DIR" "$RKN_DATA_DIR" "$RKN_CACHE_DIR" "$RKN_COUNTRY_CACHE_DIR" "$RKN_STATE_DIR" "$RKN_LOCK_DIR" "$RKN_LOG_DIR"
}

rkn_log_line() {
    local file=$1
    shift
    rkn_ensure_dirs
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$file"
}

rkn_log_action() { rkn_log_line "$RKN_ACTION_LOG" "$*"; }
rkn_log_update() { rkn_log_line "$RKN_UPDATE_LOG" "$*"; }

rkn_normalize_yesno() {
    case "${1:-n}" in
        y|Y|yes|YES|Yes) echo "y" ;;
        *) echo "n" ;;
    esac
}

rkn_validate_country_code() {
    [[ ${1:-} =~ ^[A-Za-z]{2}$ ]]
}

rkn_validate_ports_csv() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if value == 'all':
    sys.exit(0)
if not value:
    sys.exit(1)
parts = [p.strip() for p in value.split(',') if p.strip()]
if not parts:
    sys.exit(1)
seen = set()
for part in parts:
    if not part.isdigit():
        sys.exit(1)
    port = int(part)
    if port < 1 or port > 65535:
        sys.exit(1)
    seen.add(port)
sys.exit(0)
PY
}

rkn_validate_single_port() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if not value.isdigit():
    sys.exit(1)
port = int(value)
sys.exit(0 if 1 <= port <= 65535 else 1)
PY
}

rkn_normalize_ports_csv() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if value == 'all':
    print('all')
    sys.exit(0)
parts = [int(p.strip()) for p in value.split(',') if p.strip()]
print(','.join(str(p) for p in sorted(set(parts))))
PY
}

rkn_validate_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
try:
    if '/' in value:
        net = ipaddress.ip_network(value, strict=False)
    else:
        net = ipaddress.ip_address(value)
    sys.exit(0 if net.version == 4 else 1)
except Exception:
    sys.exit(1)
PY
}

rkn_normalize_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
try:
    if '/' in value:
        print(str(ipaddress.ip_network(value, strict=False)))
    else:
        print(str(ipaddress.ip_address(value)))
except Exception:
    print(value)
PY
}

rkn_get_setting() {
    local key=$1 default=${2:-}
    local value=""
    if [[ -f "$RKN_SETTINGS_FILE" ]]; then
        value=$(grep -E "^${key}=" "$RKN_SETTINGS_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '"' || true)
    fi
    echo "${value:-$default}"
}

rkn_set_setting() {
    local key=$1 value=$2
    rkn_ensure_dirs
    if [[ -f "$RKN_SETTINGS_FILE" ]]; then
        if grep -qE "^${key}=" "$RKN_SETTINGS_FILE"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$RKN_SETTINGS_FILE"
        else
            echo "${key}=\"${value}\"" >> "$RKN_SETTINGS_FILE"
        fi
    else
        echo "${key}=\"${value}\"" > "$RKN_SETTINGS_FILE"
    fi
}

rkn_is_installed() {
    [[ -f "$RKN_SETTINGS_FILE" || -f "$RKN_WHITELIST_FILE" || -f "$RKN_BLACKLIST_FILE" ]]
}

rkn_write_default_settings_if_missing() {
    rkn_ensure_dirs
    [[ -f "$RKN_SETTINGS_FILE" ]] && return 0
    cat > "$RKN_SETTINGS_FILE" <<'EOF'
FILTER_PORTS="all"
LOG_RST="n"
AUTO_UPDATE="y"
ENABLE_TSPUBLOCK="y"
ENABLE_GOVIPS="y"
EOF
}

rkn_write_default_json_if_missing() {
    rkn_ensure_dirs
    if [[ ! -f "$RKN_WHITELIST_FILE" ]]; then
        cat > "$RKN_WHITELIST_FILE" <<'EOF'
{
    "enabled": false,
    "countries": [],
    "ips": [],
    "ports": []
}
EOF
    fi
    if [[ ! -f "$RKN_BLACKLIST_FILE" ]]; then
        cat > "$RKN_BLACKLIST_FILE" <<'EOF'
{
    "ips": [],
    "ports": []
}
EOF
    fi
}

# --- Встраиваемые Python-хелперы (config_tool.py + geoip_apply.py) ---
rkn_embed_python_helpers() {
    rkn_ensure_dirs

    cat > "$RKN_CONFIG_TOOL" <<'RKN_PY_CFGTOOL'
#!/usr/bin/env python3
"""config_tool.py — управление whitelist/blacklist RKN Watcher (встроенная версия)."""
import fcntl
import ipaddress
import json
import os
import sys
import tempfile

WHITELIST_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"

DEFAULT_WHITELIST = {"enabled": False, "countries": [], "ips": [], "ports": []}
DEFAULT_BLACKLIST = {"ips": [], "ports": []}


def normalize_ip(value):
    value = str(value).strip()
    if "/" in value:
        network = ipaddress.ip_network(value, strict=False)
        if network.version != 4:
            raise ValueError("only IPv4 addresses and networks are supported")
        return str(network)
    address = ipaddress.ip_address(value)
    if address.version != 4:
        raise ValueError("only IPv4 addresses and networks are supported")
    return str(address)


def normalize_port(value):
    port = int(value)
    if port < 1 or port > 65535:
        raise ValueError("port out of range")
    return port


def normalize_country(value):
    value = str(value).strip().upper()
    if len(value) != 2 or not value.isalpha():
        raise ValueError("invalid country code")
    return value


def normalize_enabled(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off", ""}:
            return False
    raise ValueError("enabled must be a boolean")


def load_json(path, default):
    if not os.path.exists(path):
        return json.loads(json.dumps(default))
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return json.loads(json.dumps(default))
    merged = json.loads(json.dumps(default))
    merged.update(data)
    if "countries" in merged:
        merged["countries"] = sorted({normalize_country(v) for v in merged.get("countries", [])})
    if "ips" in merged:
        merged["ips"] = sorted({normalize_ip(v) for v in merged.get("ips", [])})
    if "ports" in merged:
        merged["ports"] = sorted({normalize_port(str(v)) for v in merged.get("ports", [])})
    if "enabled" in merged:
        merged["enabled"] = normalize_enabled(merged.get("enabled", False))
    return merged


def save_json_atomic(path, data):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=os.path.basename(path) + ".", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=4, ensure_ascii=False, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def update_json_locked(path, default, updater):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock_path = path + ".lock"
    with open(lock_path, "a", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        data = load_json(path, default)
        changed, result = updater(data)
        if changed:
            save_json_atomic(path, data)
        return result


def edit_list(path, default, key, action, value):
    def update(data):
        current = set(data.get(key, []))
        if action == "add":
            if value in current:
                return False, "EXISTS"
            current.add(value)
            data[key] = sorted(current)
            return True, "ADDED"
        if action == "remove":
            if value not in current:
                return False, "NOT_FOUND"
            current.remove(value)
            data[key] = sorted(current)
            return True, "REMOVED"
        raise ValueError("Unsupported action")

    print(update_json_locked(path, default, update))
    return 0


def set_enabled(value):
    normalized = normalize_enabled(value)

    def update(data):
        data["enabled"] = normalized
        return True, None

    update_json_locked(WHITELIST_FILE, DEFAULT_WHITELIST, update)
    print("ENABLED" if normalized else "DISABLED")
    return 0


def get_enabled():
    data = load_json(WHITELIST_FILE, DEFAULT_WHITELIST)
    print("true" if data.get("enabled", False) else "false")
    return 0


def show(which):
    if which == "whitelist":
        print(json.dumps(load_json(WHITELIST_FILE, DEFAULT_WHITELIST), indent=4, ensure_ascii=False, sort_keys=True))
        return 0
    if which == "blacklist":
        print(json.dumps(load_json(BLACKLIST_FILE, DEFAULT_BLACKLIST), indent=4, ensure_ascii=False, sort_keys=True))
        return 0
    result = {
        "whitelist": load_json(WHITELIST_FILE, DEFAULT_WHITELIST),
        "blacklist": load_json(BLACKLIST_FILE, DEFAULT_BLACKLIST)
    }
    print(json.dumps(result, indent=4, ensure_ascii=False, sort_keys=True))
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: config_tool.py <command> [args...]", file=sys.stderr)
        return 1
    cmd = argv[1]
    try:
        if cmd == "add-country":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "countries", "add", normalize_country(argv[2]))
        if cmd == "remove-country":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "countries", "remove", normalize_country(argv[2]))
        if cmd == "add-ip":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ips", "add", normalize_ip(argv[2]))
        if cmd == "remove-ip":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ips", "remove", normalize_ip(argv[2]))
        if cmd == "add-port":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ports", "add", normalize_port(argv[2]))
        if cmd == "remove-port":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ports", "remove", normalize_port(argv[2]))
        if cmd == "add-deny-ip":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ips", "add", normalize_ip(argv[2]))
        if cmd == "remove-deny-ip":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ips", "remove", normalize_ip(argv[2]))
        if cmd == "add-deny-port":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ports", "add", normalize_port(argv[2]))
        if cmd == "remove-deny-port":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ports", "remove", normalize_port(argv[2]))
        if cmd == "set-enabled":
            return set_enabled(argv[2])
        if cmd == "get-enabled":
            return get_enabled()
        if cmd == "show":
            which = argv[2] if len(argv) > 2 else "all"
            return show(which)
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1
    except IndexError:
        print("Missing argument", file=sys.stderr)
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
RKN_PY_CFGTOOL
    cat > "$RKN_GEOIP_APPLY_SCRIPT" <<'RKN_PY_GEOIP'
#!/usr/bin/env python3
"""geoip_apply.py — применение GeoIP-правил RKN Watcher (встроенная версия)."""
import ipaddress
import json
import logging
import os
import subprocess
import sys
import time
import urllib.request

CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
CACHE_DIR = "/var/lib/rkn-watcher/cache/countries"
LOG_FILE = "/var/log/rkn-watcher/geoip.log"

COUNTRY_CACHE_TTL = 24 * 3600
RULE_COMMENT = "rkn-watcher-geoip-hook"
HOOK_CHAIN = "RKN_GEOIP_HOOK"
ACTION_CHAIN = "GEOIP_DROP"
ALLOW_IP_SET = "GEOIP_ALLOW_IPS"
DENY_IP_SET = "GEOIP_DENY_IPS"
COUNTRY_SET = "GEOIP_COUNTRIES_ALLOW"

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", filename=LOG_FILE)


def run(cmd, check=True, capture=False, input_data=None):
    result = subprocess.run(cmd, input=input_data, text=True, capture_output=capture, check=False)
    if check and result.returncode != 0:
        err = (result.stderr or "").strip()
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(cmd)}\n{err}")
    return result


def remove_input_jump():
    while True:
        result = subprocess.run(
            ["iptables", "-C", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if result.returncode != 0:
            break
        run(["iptables", "-D", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN], check=False)


def ensure_chain(name):
    subprocess.run(["iptables", "-N", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    run(["iptables", "-F", name], check=False)


def ensure_ipset(name, set_type="hash:net", maxelem=2000000):
    run(["ipset", "create", name, set_type, "family", "inet", "maxelem", str(maxelem), "-exist"], check=True)


def replace_set(name, entries, set_type="hash:net", maxelem=2000000):
    temp_name = f"{name}_TMP"
    subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    lines = [f"create {temp_name} {set_type} family inet maxelem {maxelem} -exist", f"flush {temp_name}"]
    count = 0
    for entry in entries:
        lines.append(f"add {temp_name} {entry}")
        count += 1
    run(["ipset", "restore"], input_data="\n".join(lines) + "\n", capture=True)
    ensure_ipset(name, set_type=set_type, maxelem=maxelem)
    run(["ipset", "swap", temp_name, name])
    subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return count


def chunked(values, size=15):
    for index in range(0, len(values), size):
        yield values[index:index + size]


def load_settings():
    data = {"FILTER_PORTS": "all"}
    if not os.path.exists(SETTINGS_FILE):
        return data
    with open(SETTINGS_FILE, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
    return data


def load_json(path, default):
    if not os.path.exists(path):
        return json.loads(json.dumps(default))
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return json.loads(json.dumps(default))
    merged = json.loads(json.dumps(default))
    merged.update(data)
    return merged


def normalize_ip_list(values):
    result = []
    for value in values:
        if "/" in str(value):
            network = ipaddress.ip_network(str(value), strict=False)
            if network.version != 4:
                raise ValueError("only IPv4 addresses and networks are supported")
            result.append(str(network))
        else:
            address = ipaddress.ip_address(str(value))
            if address.version != 4:
                raise ValueError("only IPv4 addresses and networks are supported")
            result.append(str(address))
    return sorted(set(result))


def normalize_enabled(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off", ""}:
            return False
    raise ValueError("enabled must be a boolean")


def normalize_port_list(values):
    return sorted({int(v) for v in values if 1 <= int(v) <= 65535})


def normalize_country_list(values):
    result = []
    for value in values:
        code = str(value).strip().upper()
        if len(code) != 2 or not code.isalpha():
            raise ValueError(f"Invalid country code: {value}")
        result.append(code)
    return sorted(set(result))


def parse_filter_ports(raw_value):
    raw_value = (raw_value or "all").strip()
    if raw_value == "all":
        return "all"
    ports = []
    for part in raw_value.split(','):
        part = part.strip()
        if not part:
            continue
        port = int(part)
        if port < 1 or port > 65535:
            raise ValueError(f"Invalid filter port: {part}")
        ports.append(port)
    return sorted(set(ports))


def fetch_country_entries(country_code):
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, f"{country_code.lower()}.zone")
    now = time.time()
    content = None
    if os.path.exists(cache_path) and now - os.path.getmtime(cache_path) < COUNTRY_CACHE_TTL:
        with open(cache_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    else:
        url = f"https://www.ipdeny.com/ipblocks/data/aggregated/{country_code.lower()}-aggregated.zone"
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                content = response.read().decode("utf-8")
            with open(cache_path, "w", encoding="utf-8") as fh:
                fh.write(content)
        except Exception:
            if os.path.exists(cache_path):
                with open(cache_path, "r", encoding="utf-8") as fh:
                    content = fh.read()
            else:
                raise
    entries = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        network = ipaddress.ip_network(line, strict=False)
        if network.version == 4:
            entries.append(str(network))
    if not entries:
        raise RuntimeError(f"No IPv4 CIDRs for {country_code}")
    return entries


def build_country_set(country_codes):
    entries = set()
    for code in country_codes:
        for item in fetch_country_entries(code):
            entries.add(item)
    return sorted(entries)


def apply_geoip():
    settings = load_settings()
    whitelist = load_json(CONFIG_FILE, {"enabled": False, "countries": [], "ips": [], "ports": []})
    blacklist = load_json(BLACKLIST_FILE, {"ips": [], "ports": []})

    enabled = normalize_enabled(whitelist.get("enabled", False))
    whitelist_ips = normalize_ip_list(whitelist.get("ips", []))
    blacklist_ips = normalize_ip_list(blacklist.get("ips", []))
    whitelist_ports = normalize_port_list(whitelist.get("ports", []))
    blacklist_ports = normalize_port_list(blacklist.get("ports", []))
    countries = normalize_country_list(whitelist.get("countries", []))
    filter_ports = parse_filter_ports(settings.get("FILTER_PORTS", "all"))

    replace_set(ALLOW_IP_SET, whitelist_ips, set_type="hash:net", maxelem=65536)
    replace_set(DENY_IP_SET, blacklist_ips, set_type="hash:net", maxelem=65536)
    country_entries = build_country_set(countries) if countries else []
    replace_set(COUNTRY_SET, country_entries, set_type="hash:net", maxelem=3000000)

    ensure_chain(HOOK_CHAIN)
    ensure_chain(ACTION_CHAIN)
    remove_input_jump()

    if not enabled:
        logging.info("GeoIP filtering disabled")
        print("GeoIP filtering disabled")
        return 0

    if filter_ports == "all":
        run(["iptables", "-A", HOOK_CHAIN, "-j", ACTION_CHAIN])
    else:
        for port in filter_ports:
            run(["iptables", "-A", HOOK_CHAIN, "-p", "tcp", "--dport", str(port), "-j", ACTION_CHAIN])
        run(["iptables", "-A", HOOK_CHAIN, "-j", "RETURN"])

    if blacklist_ips:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", DENY_IP_SET, "src", "-j", "DROP"])
    if whitelist_ips:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", ALLOW_IP_SET, "src", "-j", "RETURN"])

    for chunk in chunked(blacklist_ports):
        run(["iptables", "-A", ACTION_CHAIN, "-p", "tcp", "-m", "multiport", "--dports", ",".join(str(p) for p in chunk), "-j", "DROP"])
    for chunk in chunked(whitelist_ports):
        run(["iptables", "-A", ACTION_CHAIN, "-p", "tcp", "-m", "multiport", "--dports", ",".join(str(p) for p in chunk), "-j", "RETURN"])

    if countries:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", COUNTRY_SET, "src", "-j", "RETURN"])
        run(["iptables", "-A", ACTION_CHAIN, "-j", "DROP"])
    else:
        run(["iptables", "-A", ACTION_CHAIN, "-j", "RETURN"])

    run(["iptables", "-I", "INPUT", "1", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN])
    logging.info("GeoIP applied: countries=%s allow_ips=%s deny_ips=%s allow_ports=%s deny_ports=%s filter_ports=%s",
                 len(countries), len(whitelist_ips), len(blacklist_ips), len(whitelist_ports), len(blacklist_ports),
                 "all" if filter_ports == "all" else len(filter_ports))
    print("GeoIP rules applied")
    return 0


def status():
    for chain in (HOOK_CHAIN, ACTION_CHAIN):
        result = run(["iptables", "-L", chain, "-v", "-n"], check=False, capture=True)
        print(result.stdout)
    for set_name in (ALLOW_IP_SET, DENY_IP_SET, COUNTRY_SET):
        result = run(["ipset", "list", set_name], check=False, capture=True)
        print(result.stdout)
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: geoip_apply.py [apply|status]", file=sys.stderr)
        return 1
    cmd = argv[1]
    try:
        if cmd == "apply":
            return apply_geoip()
        if cmd == "status":
            return status()
    except Exception as exc:
        # Чистая ошибка без traceback (например, ядро без поддержки ipset)
        print(f"geoip apply failed: {exc}", file=sys.stderr)
        return 1
    print(f"Unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
RKN_PY_GEOIP

    chmod +x "$RKN_CONFIG_TOOL" "$RKN_GEOIP_APPLY_SCRIPT"
    rkn_success "Python-хелперы записаны: $RKN_CONFIG_TOOL, $RKN_GEOIP_APPLY_SCRIPT"
}

# --- ipset / iptables хелперы ---
rkn_ensure_ipset_exists() {
    local name=$1
    local type=${2:-hash:net}
    local maxelem=${3:-2000000}
    # -exist: не ошибка, если набор уже создан; || true: не роняем поток при
    # временной недоступности (например, ядро без поддержки ipset)
    ipset create "$name" "$type" family inet maxelem "$maxelem" -exist >/dev/null 2>&1 || true
}

rkn_ipset_count() {
    local name=$1
    ipset list "$name" 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'
}

rkn_remove_rule_all() {
    local chain=$1
    shift
    while iptables -C "$chain" "$@" >/dev/null 2>&1; do
        iptables -D "$chain" "$@" >/dev/null 2>&1 || break
    done
}

rkn_ensure_chain() {
    local chain=$1
    iptables -N "$chain" >/dev/null 2>&1 || true
    iptables -F "$chain" >/dev/null 2>&1 || true
}

rkn_setup_tspublock_rules() {
    local enabled log_rst
    enabled=$(rkn_get_setting ENABLE_TSPUBLOCK y)
    log_rst=$(rkn_get_setting LOG_RST n)

    rkn_ensure_ipset_exists TSPUIPS hash:net 2000000
    rkn_ensure_chain TSPUBLOCK
    rkn_remove_rule_all INPUT -j TSPUBLOCK

    if [[ "$enabled" != "y" ]]; then
        rkn_log_action "TSPUBLOCK disabled"
        return 0
    fi

    if [[ "$log_rst" == "y" ]]; then
        iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
    fi
    iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
    iptables -I INPUT 1 -j TSPUBLOCK
    rkn_log_action "TSPUBLOCK rules applied"
}

rkn_setup_govips_rules() {
    local enabled log_rst
    enabled=$(rkn_get_setting ENABLE_GOVIPS y)
    log_rst=$(rkn_get_setting LOG_RST n)

    rkn_ensure_ipset_exists GOVIPS hash:net 2000000
    rkn_ensure_chain GOVBLOCK
    rkn_remove_rule_all INPUT -j GOVBLOCK

    if [[ "$enabled" != "y" ]]; then
        rkn_log_action "GOVIPS disabled"
        return 0
    fi

    if [[ "$log_rst" == "y" ]]; then
        iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GOVBLOCK: " --log-level 4
    fi
    iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
    iptables -I INPUT 1 -j GOVBLOCK
    rkn_log_action "GOVIPS rules applied"
}

rkn_save_ipset_state() {
    rkn_ensure_dirs
    local tmp
    tmp=$(mktemp "$RKN_STATE_DIR/ipset.XXXXXX")
    : > "$tmp"
    local set_name
    for set_name in "${RKN_MANAGED_IPSETS[@]}"; do
        ipset save "$set_name" >> "$tmp" 2>/dev/null || true
    done
    mv "$tmp" "$RKN_IPSET_STATE_FILE"
}

rkn_restore_ipset_state() {
    if [[ -f "$RKN_IPSET_STATE_FILE" ]]; then
        ipset restore -exist < "$RKN_IPSET_STATE_FILE" >/dev/null 2>&1 || true
    fi
}

rkn_sanitize_tspu_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" <<'PY'
import ipaddress, sys
src, dst = sys.argv[1:3]
out = []
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except Exception:
            continue
        if net.version == 4:
            out.append(str(net))
with open(dst, 'w', encoding='utf-8') as fh:
    for item in sorted(set(out)):
        fh.write(item + '\n')
PY
}

rkn_sanitize_gov_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" <<'PY'
import ipaddress, re, sys
src, dst = sys.argv[1:3]
out = []
pattern = re.compile(r'^add\s+blacklist-v4\s+([0-9./]+)')
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        match = pattern.match(line)
        if not match:
            continue
        try:
            net = ipaddress.ip_network(match.group(1), strict=False)
        except Exception:
            continue
        if net.version == 4:
            out.append(str(net))
with open(dst, 'w', encoding='utf-8') as fh:
    for item in sorted(set(out)):
        fh.write(item + '\n')
PY
}

rkn_replace_ipset_from_file() {
    local target=$1
    local type=$2
    local maxelem=$3
    local file=$4
    local temp="${target}_TMP"
    local restore_file count
    restore_file=$(mktemp)
    count=0

    {
        printf 'create %s %s family inet maxelem %s -exist\n' "$temp" "$type" "$maxelem"
        printf 'flush %s\n' "$temp"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf 'add %s %s\n' "$temp" "$line"
            count=$((count + 1))
        done < "$file"
    } > "$restore_file"

    if (( count == 0 )); then
        rm -f "$restore_file"
        return 1
    fi

    # Явная проверка кода возврата: внутри `if ! count=$(...)` set -e отключается,
    # поэтому без проверки сбой ipset restore молча маскировался бы и обновление
    # ошибочно считалось успешным (ложные счётчики в статусе).
    if ! ipset restore < "$restore_file"; then
        rm -f "$restore_file"
        rkn_log_update "ERROR: ipset restore failed for $target (kernel/ipset unavailable?)"
        return 1
    fi
    rm -f "$restore_file"
    rkn_ensure_ipset_exists "$target" "$type" "$maxelem"
    if ! ipset swap "$temp" "$target"; then
        ipset destroy "$temp" >/dev/null 2>&1 || true
        rkn_log_update "ERROR: ipset swap failed for $target"
        return 1
    fi
    ipset destroy "$temp" >/dev/null 2>&1 || true
    printf '%s\n' "$count"
}

rkn_fetch_url() {
    local url=$1 out=$2
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "$url" -o "$out"
}

rkn_update_tspublock_list() {
    local raw sanitized count
    raw=$(mktemp)
    sanitized=$(mktemp)

    if ! rkn_fetch_url "https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt" "$raw"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    if ! rkn_sanitize_tspu_file "$raw" "$sanitized"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    rm -f "$raw"

    if ! count=$(rkn_replace_ipset_from_file TSPUIPS hash:net 2000000 "$sanitized"); then
        rm -f "$sanitized"
        return 1
    fi

    rm -f "$sanitized"
    printf '%s\n' "$count" > "$RKN_STATE_DIR/tspu_count.txt"
    rkn_log_update "TSPUBLOCK updated: $count entries"
    printf '%s\n' "$count"
    return 0
}

rkn_update_govips_list() {
    local raw sanitized count
    raw=$(mktemp)
    sanitized=$(mktemp)

    if ! rkn_fetch_url "https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset" "$raw"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    if ! rkn_sanitize_gov_file "$raw" "$sanitized"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    rm -f "$raw"

    if ! count=$(rkn_replace_ipset_from_file GOVIPS hash:net 2000000 "$sanitized"); then
        rm -f "$sanitized"
        return 1
    fi

    rm -f "$sanitized"
    printf '%s\n' "$count" > "$RKN_STATE_DIR/gov_count.txt"
    rkn_log_update "GOVIPS updated: $count entries"
    printf '%s\n' "$count"
    return 0
}

rkn_update_lists_parallel() {
    rkn_ensure_dirs
    rkn_ensure_ipset_exists TSPUIPS hash:net 2000000
    rkn_ensure_ipset_exists GOVIPS hash:net 2000000

    local tspu_out gov_out rc=0 tspu_count gov_count
    tspu_out=$(mktemp)
    gov_out=$(mktemp)

    (rkn_update_tspublock_list > "$tspu_out") &
    local pid1=$!
    (rkn_update_govips_list > "$gov_out") &
    local pid2=$!

    if ! wait "$pid1"; then
        rkn_warn "Ошибка обновления TSPUBLOCK"
        rkn_log_update "ERROR updating TSPUBLOCK"
        rc=1
    fi
    if ! wait "$pid2"; then
        rkn_warn "Ошибка обновления GOVIPS"
        rkn_log_update "ERROR updating GOVIPS"
        rc=1
    fi

    tspu_count=$(tail -n1 < "$tspu_out" 2>/dev/null || echo 0)
    gov_count=$(tail -n1 < "$gov_out" 2>/dev/null || echo 0)
    rm -f "$tspu_out" "$gov_out"

    if (( rc == 0 )); then
        rkn_success "TSPUBLOCK: $tspu_count, GOVIPS: $gov_count"
    fi
    return $rc
}

rkn_with_lock() {
    local lock_file=$1
    shift
    rkn_ensure_dirs
    (
        flock -w 60 9 || { echo "lock-timeout"; exit 99; }
        "$@"
    ) 9>"$lock_file"
}

rkn_apply_all_inner() {
    rkn_restore_ipset_state
    rkn_setup_tspublock_rules
    rkn_setup_govips_rules
    "$RKN_GEOIP_APPLY_SCRIPT" apply >/dev/null
    rkn_save_ipset_state
    rkn_log_action "Full apply completed"
}

rkn_apply_all() {
    rkn_with_lock "$RKN_UPDATE_LOCK_FILE" rkn_apply_all_inner
}

rkn_update_all_inner() {
    local rc=0
    rkn_log_update "=== update started ==="
    if ! rkn_update_lists_parallel; then
        rc=1
    fi
    rkn_setup_tspublock_rules
    rkn_setup_govips_rules
    "$RKN_GEOIP_APPLY_SCRIPT" apply >/dev/null
    rkn_save_ipset_state
    rkn_log_update "=== update completed ==="
    return $rc
}

rkn_update_all() {
    rkn_with_lock "$RKN_UPDATE_LOCK_FILE" rkn_update_all_inner
}

# --- systemd юниты ---
rkn_write_systemd_units() {
    cat > "$RKN_BOOT_SERVICE" <<EOF
[Unit]
Description=RKN Watcher boot restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RKN_MAIN_SCRIPT apply --quiet

[Install]
WantedBy=multi-user.target
EOF

    cat > "$RKN_UPDATE_SERVICE" <<EOF
[Unit]
Description=RKN Watcher scheduled update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RKN_MAIN_SCRIPT update --quiet
EOF

    cat > "$RKN_UPDATE_TIMER" <<'EOF'
[Unit]
Description=RKN Watcher daily update timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=20m
Unit=rkn-watcher-update.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
}

rkn_enable_or_disable_timer() {
    local auto
    auto=$(rkn_get_setting AUTO_UPDATE y)
    if [[ "$auto" == "y" ]]; then
        systemctl enable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    else
        systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    fi
}

# --- Проверка поддержки ipset ядром ---
rkn_ipset_supported() {
    local test_set
    test_set="RKN_TEST_$(date +%s)"
    if ipset create "$test_set" hash:ip family inet maxelem 8 -exist >/dev/null 2>&1; then
        ipset destroy "$test_set" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

# --- Установка/обновление защиты ---
rkn_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

rkn_save_installed_packages_manifest() {
    local new_packages=("$@")
    mkdir -p "$(dirname "$RKN_PKG_MANIFEST")"

    python3 - "$RKN_PKG_MANIFEST" "${new_packages[@]}" <<'PY'
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

rkn_install_dependencies() {
    local missing=()
    local pkg
    for pkg in "${RKN_REQUIRED_PACKAGES[@]}"; do
        if ! rkn_package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        rkn_success "Все необходимые зависимости уже установлены"
        return 0
    fi
    rkn_info "Будут установлены зависимости: ${missing[*]}"
    apt_update || true
    apt_install "${missing[@]}" || true
    rkn_save_installed_packages_manifest "${missing[@]}"
    rkn_success "Зависимости установлены"
}

rkn_install_or_upgrade() {
    check_root
    local had_existing_config="n"
    [[ -f "$RKN_SETTINGS_FILE" || -f "$RKN_WHITELIST_FILE" || -f "$RKN_BLACKLIST_FILE" ]] && had_existing_config="y"

    rkn_ensure_dirs
    rkn_install_dependencies

    if ! rkn_ipset_supported; then
        echo
        rkn_error "Ядро не поддерживает ipset (нет модуля xt_set)."
        echo "Блокировка через iptables+ipset работать не будет."
        read -r -p "Всё равно продолжить установку (без применения правил)? (y/N): " cont_ipset
        if [[ ! "${cont_ipset:-n}" =~ ^[Yy]$ ]]; then
            rkn_warn "Установка отменена."
            return 1
        fi
    fi

    rkn_write_default_settings_if_missing
    rkn_write_default_json_if_missing
    rkn_embed_python_helpers

    # Копируем сам скрипт в каталог установки (для systemd и CLI)
    local source
    source=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ "$source" != "$RKN_MAIN_SCRIPT" ]]; then
        cp "$source" "$RKN_MAIN_SCRIPT" 2>/dev/null || true
    fi
    chmod +x "$RKN_MAIN_SCRIPT" 2>/dev/null || true
    ln -sf "$RKN_MAIN_SCRIPT" "$RKN_BIN_PATH" 2>/dev/null || true

    rkn_write_systemd_units

    rkn_ensure_ipset_exists TSPUIPS hash:net 2000000
    rkn_ensure_ipset_exists GOVIPS hash:net 2000000

    local filter_ports log_rst auto_update enable_geo enable_tspu enable_gov use_existing
    use_existing="n"
    if [[ "$had_existing_config" == "y" ]]; then
        read -r -p "Сохранить текущие настройки, если они уже есть? (y/n): " use_existing || true
        use_existing=$(rkn_normalize_yesno "$use_existing")
    fi

    if [[ "$use_existing" != "y" ]]; then
        echo
        echo "Настройка области применения GeoIP:"
        echo "1) Все порты"
        echo "2) Один порт"
        echo "3) Несколько портов"
        read -r -p "Выберите вариант (1-3): " choice
        case "$choice" in
            2)
                read -r -p "Введите порт: " filter_ports
                rkn_validate_ports_csv "$filter_ports" || { rkn_error "Некорректный порт"; return 1; }
                filter_ports=$(rkn_normalize_ports_csv "$filter_ports")
                ;;
            3)
                read -r -p "Введите порты через запятую: " filter_ports
                rkn_validate_ports_csv "$filter_ports" || { rkn_error "Некорректный список портов"; return 1; }
                filter_ports=$(rkn_normalize_ports_csv "$filter_ports")
                ;;
            *)
                filter_ports="all"
                ;;
        esac

        read -r -p "Включить логирование RST-пакетов? (y/n): " log_rst
        read -r -p "Включить автообновление через systemd timer? (y/n): " auto_update
        read -r -p "Включить TSPUBLOCK? (y/n): " enable_tspu
        read -r -p "Включить GOVIPS? (y/n): " enable_gov
        read -r -p "Включить GeoIP сразу? (y/n): " enable_geo

        rkn_set_setting FILTER_PORTS "$filter_ports"
        rkn_set_setting LOG_RST "$(rkn_normalize_yesno "$log_rst")"
        rkn_set_setting AUTO_UPDATE "$(rkn_normalize_yesno "$auto_update")"
        rkn_set_setting ENABLE_TSPUBLOCK "$(rkn_normalize_yesno "$enable_tspu")"
        rkn_set_setting ENABLE_GOVIPS "$(rkn_normalize_yesno "$enable_gov")"
        local geo_flag
        if [[ $(rkn_normalize_yesno "$enable_geo") == y ]]; then geo_flag="true"; else geo_flag="false"; fi
        "$RKN_CONFIG_TOOL" set-enabled "$geo_flag" >/dev/null
    fi

    rkn_enable_or_disable_timer

    rkn_info "Загрузка блок-листов..."
    if ! rkn_update_all; then
        rkn_warn "Часть списков не обновилась. Существующие данные сохранены."
        rkn_apply_all || true
    fi

    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
    rkn_success "Установка/обновление RKN Watcher завершены"
}

# --- Удаление ---
rkn_remove_managed_firewall() {
    rkn_remove_rule_all INPUT -j TSPUBLOCK || true
    rkn_remove_rule_all INPUT -j GOVBLOCK || true
    rkn_remove_rule_all INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK || true

    local chain
    for chain in "${RKN_MANAGED_CHAINS[@]}"; do
        iptables -F "$chain" >/dev/null 2>&1 || true
        iptables -X "$chain" >/dev/null 2>&1 || true
    done

    local set_name
    for set_name in "${RKN_MANAGED_IPSETS[@]}"; do
        ipset destroy "$set_name" >/dev/null 2>&1 || true
    done
}

rkn_read_manifest_packages() {
    local path="$RKN_PKG_MANIFEST"
    [[ -f "$path" ]] || return 0
    awk 'NF {print $0}' "$path"
}

rkn_remove_installer_packages() {
    local packages=("$@")
    local installed=()
    local pkg

    for pkg in "${packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        if rkn_package_installed "$pkg"; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        rkn_info "Нет пакетов, установленных именно этим установщиком"
        return 0
    fi

    echo
    rkn_warn "Дополнительно можно удалить пакеты, которые установщик доустановил ранее: ${installed[*]}"
    read -r -p "Удалить эти пакеты тоже? (y/n): " answer
    case "${answer:-n}" in
        y|Y|yes|YES)
            export DEBIAN_FRONTEND=noninteractive
            apt-get remove -y "${installed[@]}" || true
            apt-get autoremove -y || true
            rkn_success "Пакеты удалены"
            ;;
        *)
            rkn_info "Удаление пакетов пропущено"
            ;;
    esac
}

rkn_uninstall_all() {
    check_root

    local confirm=""
    if [[ "${RKN_ASSUME_YES:-0}" == "1" ]]; then
        confirm="YES"
    else
        read -r -p "Для полного удаления RKN Watcher введите YES: " confirm || true
    fi

    if [[ "$confirm" != "YES" ]]; then
        rkn_warn "Удаление отменено"
        return 0
    fi

    systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    systemctl disable --now rkn-watcher-boot.service >/dev/null 2>&1 || true
    rm -f "$RKN_BOOT_SERVICE" "$RKN_UPDATE_SERVICE" "$RKN_UPDATE_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true

    rkn_remove_managed_firewall

    rm -f "$RKN_BIN_PATH"
    rm -rf "$RKN_INSTALL_DIR" "$RKN_CONFIG_DIR" "$RKN_DATA_DIR" "$RKN_LOG_DIR"

    # Опциональное удаление доустановленных пакетов
    local packages=()
    mapfile -t packages < <(rkn_read_manifest_packages)
    if [[ ${#packages[@]} -gt 0 ]]; then
        rkn_remove_installer_packages "${packages[@]}"
    fi

    rkn_success "RKN Watcher удалён"
}

# --- Статус и просмотр ---
rkn_show_status() {
    local mode=${1:-interactive}
    local auto_update log_rst filter_ports tspu gov geo_enabled
    auto_update=$(rkn_get_setting AUTO_UPDATE y)
    log_rst=$(rkn_get_setting LOG_RST n)
    filter_ports=$(rkn_get_setting FILTER_PORTS all)
    tspu=$(rkn_get_setting ENABLE_TSPUBLOCK y)
    gov=$(rkn_get_setting ENABLE_GOVIPS y)
    geo_enabled=$({ "$RKN_CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)

    if [[ "$mode" == "interactive" ]]; then
        cls
        rkn_title
        echo -e "${CYAN}${RKN_APP_NAME} ${RKN_VERSION} — статус${NC}"
        rkn_title
        echo
    fi

    echo "TSPUBLOCK enabled : $tspu"
    echo "GOVIPS enabled    : $gov"
    echo "GeoIP enabled     : $geo_enabled"
    echo "Filter ports      : $filter_ports"
    echo "RST logging       : $log_rst"
    echo "Auto update       : $auto_update"
    echo
    echo "TSPUIPS entries   : $(rkn_ipset_count TSPUIPS)"
    echo "GOVIPS entries    : $(rkn_ipset_count GOVIPS)"
    echo "GeoIP allow IPs   : $(rkn_ipset_count GEOIP_ALLOW_IPS)"
    echo "GeoIP deny IPs    : $(rkn_ipset_count GEOIP_DENY_IPS)"
    echo "GeoIP countries   : $(rkn_ipset_count GEOIP_COUNTRIES_ALLOW)"
    echo
    if systemctl is-enabled rkn-watcher-update.timer >/dev/null 2>&1; then echo "Timer: enabled"; else echo "Timer: disabled"; fi
    if systemctl is-active rkn-watcher-update.timer >/dev/null 2>&1; then echo "Timer state: active"; fi
    echo

    if [[ "$mode" == "interactive" ]]; then
        read -r -p "Нажмите Enter для продолжения..." _ || true
    fi
}

rkn_show_rules() {
    cls
    rkn_title
    echo -e "${CYAN}iptables / ipset${NC}"
    rkn_title
    echo
    iptables -L INPUT -v -n 2>/dev/null | sed -n '1,40p' || true
    echo
    local chain
    for chain in TSPUBLOCK GOVBLOCK RKN_GEOIP_HOOK GEOIP_DROP; do
        echo "=== $chain ==="
        iptables -L "$chain" -v -n 2>/dev/null || echo "chain absent"
        echo
    done
    local set_name
    for set_name in TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW; do
        echo "=== $set_name ==="
        ipset list "$set_name" 2>/dev/null | sed -n '1,20p' || echo "set absent"
        echo
    done
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

rkn_show_logs() {
    while true; do
        cls
        rkn_title
        echo -e "${CYAN}Логи${NC}"
        rkn_title
        echo
        echo "1) update.log"
        echo "2) actions.log"
        echo "3) geoip.log"
        echo "4) Очистить все логи"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) cls; tail -n 100 "$RKN_UPDATE_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ || true ;;
            2) cls; tail -n 100 "$RKN_ACTION_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ || true ;;
            3) cls; tail -n 100 "$RKN_GEOIP_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ || true ;;
            4)
                : > "$RKN_UPDATE_LOG"
                : > "$RKN_ACTION_LOG"
                : > "$RKN_GEOIP_LOG"
                rkn_success "Логи очищены"
                sleep 1
                ;;
            0) break ;;
            *) rkn_warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

rkn_show_geoip_config() {
    cls
    rkn_title
    echo -e "${CYAN}Конфигурация GeoIP${NC}"
    rkn_title
    echo
    echo "--- whitelist.json ---"
    "$RKN_CONFIG_TOOL" show whitelist || true
    echo
    echo "--- blacklist.json ---"
    "$RKN_CONFIG_TOOL" show blacklist || true
    echo
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

rkn_reapply_rules() {
    if rkn_apply_all; then
        rkn_success "Правила успешно применены"
    else
        rkn_error "Не удалось применить правила"
    fi
    sleep 1
}

rkn_set_filter_ports_interactive() {
    local value
    read -r -p "Введите all или список портов через запятую: " value
    rkn_validate_ports_csv "$value" || { rkn_error "Некорректное значение"; sleep 1; return 1; }
    value=$(rkn_normalize_ports_csv "$value")
    rkn_set_setting FILTER_PORTS "$value"
    rkn_apply_all
    rkn_success "FILTER_PORTS обновлён: $value"
    sleep 1
}

rkn_toggle_setting_yesno() {
    local key=$1 label=$2 current
    current=$(rkn_get_setting "$key" n)
    local new
    if [[ "$current" == "y" ]]; then new="n"; else new="y"; fi
    rkn_set_setting "$key" "$new"
    rkn_apply_all
    rkn_success "$label: $new"
    sleep 1
}

rkn_run_config_tool_and_apply() {
    local output
    if ! output=$("$RKN_CONFIG_TOOL" "$@" 2>&1); then
        rkn_error "$output"
        sleep 1
        return 1
    fi
    rkn_apply_all
    rkn_success "$output"
    sleep 1
}

rkn_geoip_menu() {
    while true; do
        cls
        rkn_title
        echo -e "${CYAN}Настройка GeoIP${NC}"
        rkn_title
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
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1)
                local current_enabled
                current_enabled=$("$RKN_CONFIG_TOOL" get-enabled 2>/dev/null | tail -n1)
                if [[ "$current_enabled" == "true" ]]; then
                    rkn_run_config_tool_and_apply set-enabled false
                else
                    rkn_run_config_tool_and_apply set-enabled true
                fi
                ;;
            2)
                read -r -p "Код страны (например, FI): " value
                rkn_validate_country_code "$value" || { rkn_error "Некорректный код"; sleep 1; continue; }
                rkn_run_config_tool_and_apply add-country "$value"
                ;;
            3)
                read -r -p "Код страны: " value
                rkn_validate_country_code "$value" || { rkn_error "Некорректный код"; sleep 1; continue; }
                rkn_run_config_tool_and_apply remove-country "$value"
                ;;
            4)
                read -r -p "IP или CIDR: " value
                rkn_validate_ip_or_cidr "$value" || { rkn_error "Некорректный IP/CIDR"; sleep 1; continue; }
                value=$(rkn_normalize_ip_or_cidr "$value")
                rkn_run_config_tool_and_apply add-ip "$value"
                ;;
            5)
                read -r -p "IP или CIDR: " value
                rkn_validate_ip_or_cidr "$value" || { rkn_error "Некорректный IP/CIDR"; sleep 1; continue; }
                value=$(rkn_normalize_ip_or_cidr "$value")
                rkn_run_config_tool_and_apply remove-ip "$value"
                ;;
            6)
                read -r -p "Порт: " value
                rkn_validate_single_port "$value" || { rkn_error "Некорректный порт"; sleep 1; continue; }
                rkn_run_config_tool_and_apply add-port "$value"
                ;;
            7)
                read -r -p "Порт: " value
                rkn_validate_single_port "$value" || { rkn_error "Некорректный порт"; sleep 1; continue; }
                rkn_run_config_tool_and_apply remove-port "$value"
                ;;
            8)
                read -r -p "IP или CIDR: " value
                rkn_validate_ip_or_cidr "$value" || { rkn_error "Некорректный IP/CIDR"; sleep 1; continue; }
                value=$(rkn_normalize_ip_or_cidr "$value")
                rkn_run_config_tool_and_apply add-deny-ip "$value"
                ;;
            9)
                read -r -p "IP или CIDR: " value
                rkn_validate_ip_or_cidr "$value" || { rkn_error "Некорректный IP/CIDR"; sleep 1; continue; }
                value=$(rkn_normalize_ip_or_cidr "$value")
                rkn_run_config_tool_and_apply remove-deny-ip "$value"
                ;;
            10)
                read -r -p "Порт: " value
                rkn_validate_single_port "$value" || { rkn_error "Некорректный порт"; sleep 1; continue; }
                rkn_run_config_tool_and_apply add-deny-port "$value"
                ;;
            11)
                read -r -p "Порт: " value
                rkn_validate_single_port "$value" || { rkn_error "Некорректный порт"; sleep 1; continue; }
                rkn_run_config_tool_and_apply remove-deny-port "$value"
                ;;
            12) rkn_show_geoip_config ;;
            0) break ;;
            *) rkn_warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

rkn_settings_menu() {
    while true; do
        cls
        rkn_title
        echo -e "${CYAN}Настройки${NC}"
        rkn_title
        echo
        echo "1) Изменить FILTER_PORTS"
        echo "2) Вкл/выкл LOG_RST"
        echo "3) Вкл/выкл AUTO_UPDATE"
        echo "4) Пере-применить правила"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) rkn_set_filter_ports_interactive ;;
            2) rkn_toggle_setting_yesno LOG_RST "LOG_RST" ;;
            3) rkn_toggle_setting_yesno AUTO_UPDATE "AUTO_UPDATE"; rkn_enable_or_disable_timer ;;
            4) rkn_reapply_rules ;;
            0) break ;;
            *) rkn_warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

rkn_blocklists_menu() {
    while true; do
        cls
        rkn_title
        echo -e "${CYAN}Блок-листы${NC}"
        rkn_title
        echo
        echo "1) Вкл/выкл TSPUBLOCK"
        echo "2) Вкл/выкл GOVIPS"
        echo "3) Обновить оба списка"
        echo "4) Показать правила / ipset"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) rkn_toggle_setting_yesno ENABLE_TSPUBLOCK "TSPUBLOCK" ;;
            2) rkn_toggle_setting_yesno ENABLE_GOVIPS "GOVIPS" ;;
            3)
                if rkn_update_all; then rkn_success "Обновление завершено"; else rkn_warn "Обновление завершено с ошибками"; fi
                sleep 1
                ;;
            4) rkn_show_rules ;;
            0) break ;;
            *) rkn_warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

# --- Главное меню защиты ---
rkn_protect_menu() {
    while true; do
        cls
        rkn_title
        echo -e "${CYAN}${RKN_APP_NAME} ${RKN_VERSION} — защита ноды${NC}"
        rkn_title
        echo
        if rkn_is_installed; then
            echo "1) Блок-листы"
            echo "2) GeoIP"
            echo "3) Настройки"
            echo "4) Статус"
            echo "5) Логи"
            echo "6) Переустановить / обновить"
            echo "7) Удалить"
            echo "0) Назад"
        else
            echo "1) Установить"
            echo "0) Назад"
        fi
        echo
        read -r -p "Выберите пункт: " choice
        if rkn_is_installed; then
            case "$choice" in
                1) rkn_blocklists_menu ;;
                2) rkn_geoip_menu ;;
                3) rkn_settings_menu ;;
                4) rkn_show_status ;;
                5) rkn_show_logs ;;
                6) rkn_install_or_upgrade ;;
                7) rkn_uninstall_all ;;
                0) return ;;
                *) rkn_warn "Неверный выбор"; sleep 1 ;;
            esac
        else
            case "$choice" in
                1) rkn_install_or_upgrade ;;
                0) return ;;
                *) rkn_warn "Неверный выбор"; sleep 1 ;;
            esac
        fi
    done
}
# ==============================================================================
# МОДУЛЬ D: МУЛЬТИ-ТЕСТЫ И ДИАГНОСТИКА (объединено из обоих скриптов)
# ==============================================================================
run_multitest() {
    (
        set +e
        set +o pipefail
        trap - INT

        need_cmd curl curl || true
        need_cmd wget wget || true
        need_cmd traceroute traceroute || true
        need_cmd jq jq || true

        while true; do
            show_header
            echo -e "${CYAN}── ДОСТУПНЫЕ ТЕСТЫ ──${NC}\n"
            echo " 1) IP Region / Геолокация"
            echo " 9) sysbench CPU"
            echo "10) sysbench Memory"
            echo "11) Network Bench (100MB)"
            echo "12) SSL/TLS check"
            echo "13) Traceroute yandex.ru"
            echo "14) Ping yandex.ru"
            echo "99) Мультитест: все тесты по очереди (Enter/s/q)"
            echo " 0) Назад"
            read -r -p "Выбор: " choice || choice=0
            echo ""
            case $choice in
              1) mt_run_one 1; pause_prompt ;;
              9) mt_run_one 9; pause_prompt ;;
              10) mt_run_one 10; pause_prompt ;;
              11) mt_run_one 11; pause_prompt ;;
              12) mt_run_one 12; pause_prompt ;;
              13) mt_run_one 13; pause_prompt ;;
              14) mt_run_one 14; pause_prompt ;;
              99) mt_run_all ;;
              0) return ;;
              *) echo "Неверный выбор"; sleep 1 ;;
            esac
        done
    )
}

# --- Запуск одного теста по номеру (актуализировано по saveksme/multitest v1.1) ---
mt_run_one() {
    case "$1" in
        1) curl -fsSL --proto '=https' --tlsv1.2 https://ipapi.co/json 2>/dev/null | jq '.' 2>/dev/null || curl -fsSL --proto '=https' --tlsv1.2 https://ipinfo.io 2>/dev/null || echo "Ошибка получения данных." ;;
        9) need_cmd sysbench sysbench || true; sysbench cpu --cpu-max-prime=20000 run || true ;;
        10) need_cmd sysbench sysbench || true; sysbench memory run || true ;;
        11) echo "Тест скорости: файлы 100MB"; wget -qO /dev/null http://speedtest.tele2.net/100MB.zip || wget -qO /dev/null http://ipv4.download.thinkbroadband.com/100MB.zip || true ;;
        12) { openssl s_client -connect google.com:443 -tls1_2 </dev/null 2>&1 | grep -q "Protocol" && echo "TLS 1.2 OK"; } || echo "TLS 1.2 недоступен"; { openssl s_client -connect google.com:443 -tls1_3 </dev/null 2>&1 | grep -q "Protocol" && echo "TLS 1.3 OK"; } || echo "TLS 1.3 недоступен" ;;
        13) traceroute -n yandex.ru || tracepath yandex.ru || true ;;
        14) ping -c 4 yandex.ru || true ;;
    esac
}

# --- Мультитест: все тесты по очереди с выбором (актуализировано по saveksme/multitest v1.1) ---
mt_run_all() {
    local names=(
        "IP Region"
        "sysbench CPU — тест процессора"
        "sysbench Memory — тест оперативной памяти"
        "Network Bench — скорость (100MB)"
        "SSL/TLS check"
        "Traceroute yandex.ru"
        "Ping yandex.ru"
    )
    local ids=(1 9 10 11 12 13 14)
    local total=${#names[@]}
    echo -e "  ${YELLOW}Enter${NC} — запустить | ${YELLOW}s${NC} — пропустить | ${YELLOW}q${NC} — выход"
    echo -e "  ${GRAY}Ctrl+C во время теста — пропустить текущий и продолжить${NC}"
    local i num action
    for ((i=0; i<total; i++)); do
        num=$((i+1))
        echo ""
        echo -e "${CYAN}━━━━ [${num}/${total}] ${names[$i]} ━━━━${NC}"
        echo -ne "  ${YELLOW}Enter${NC} — запустить | ${YELLOW}s${NC} — пропустить | ${YELLOW}q${NC} — выход: "
        read -r action
        case "$action" in
            s|S) echo "  Пропущено."; continue ;;
            q|Q) echo -e "\n${GREEN}Мультитест прерван. Выполнено тестов: $((num-1))/${total}${NC}"; return ;;
        esac
        sleep 1
        # В подоболочке: Ctrl+C убивает только текущий тест
        ( trap - INT; mt_run_one "${ids[$i]}" )
        echo ""
    done
    echo -e "${GREEN}Все тесты завершены! (${total}/${total})${NC}"
}

# РЕГИСТРАЦИЯ ГЛОБАЛЬНЫХ КОМАНД
# ==============================================================================
register_global_commands() {
    local script_path="${SCRIPT_PATH:-$(readlink -f "$0" 2>/dev/null || echo "$0")}"

    local dest=/usr/local/bin/safe-remnanode-setup tmp
    [[ -f "$script_path" && "$script_path" != /dev/* ]] || { echo 'Запустите установщик из локального файла.' >&2; return 1; }
    if [[ "$script_path" != "$dest" && "$script_path" != "$RKN_MAIN_SCRIPT" ]]; then
        tmp=$(mktemp /usr/local/bin/.safe-remnanode.XXXXXXXX) || return 1
        if ! install -m 0755 "$script_path" "$tmp" || ! mv -fT "$tmp" "$dest"; then
            rm -f -- "$tmp"
            return 1
        fi
    fi
    [[ -x "$dest" ]] || return 1
    local alias path
    for alias in remnanode rkn-watcher; do
        path="/usr/local/bin/$alias"
        if [[ -e "$path" || -L "$path" ]]; then
            [[ "$(readlink "$path" 2>/dev/null)" == "$dest" ]] || { echo "Существующая команда $path оставлена без изменений." >&2; continue; }
        else
            ln -s "$dest" "$path" || return 1
        fi
    done
}

# ==============================================================================
# ЭКСПРЕСС-РЕЖИМ: ПОЛНАЯ УСТАНОВКА (СЕРВЕР + НОДА + ЗАЩИТА)
# ==============================================================================
express_install() {
    cls
    echo -e "${GREEN}"
    echo "  ========================================================"
    echo "  🚀 ЭКСПРЕСС-УСТАНОВКА: СЕРВЕР + НОДА + ЗАЩИТА"
    echo "  ========================================================"
    echo -e "${NC}"
    echo -e "${YELLOW}Будет выполнено (по шагам):${NC}"
    echo "  1) Базовая настройка сервера (обновление, Docker, BBR, sysctl)"
    echo "  2) Установка ноды Remnawave (интерактивная настройка)"
    echo "  3) Установка защиты RKN-Watcher (блок-листы + GeoIP)"
    echo ""
    read -r -p "Продолжить полную установку? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Отменено.${NC}"; return; }

    # --- ШАГ 1: Сервер ---
    echo -e "\n${CYAN}════════════ ШАГ 1/3: НАСТРОЙКА СЕРВЕРА ════════════${NC}"
    echo -e "${INFO_T} Проверка Docker. Обновление ОС и sysctl доступны отдельно в меню сервера."
    if ! command -v docker >/dev/null; then install_docker_apt || return 1; fi
    docker compose version >> "$(log_file)" 2>&1 || return 1
    echo -e "${SUCCESS_T} Шаг 1 завершён."

    # --- ШАГ 2: Нода ---
    echo -e "\n${CYAN}════════════ ШАГ 2/3: УСТАНОВКА НОДЫ ════════════${NC}"
    read -r -p "Перейти к установке ноды? [Y/n]: " go_node
    go_node=${go_node:-Y}
    if [[ $go_node =~ ^[Yy] ]]; then
        if ! rn_initial_setup; then
            echo -e "${WARNING_T} Установка ноды не завершилась (см. лог). Можно повторить позже из главного меню."
            return 1
        fi
    else
        echo -e "${YELLOW}Шаг 2 пропущен.${NC}"
    fi

    # --- ШАГ 3: Защита ---
    echo -e "\n${CYAN}════════════ ШАГ 3/3: УСТАНОВКА ЗАЩИТЫ ════════════${NC}"
    read -r -p "Перейти к установке защиты RKN-Watcher? [y/N]: " go_rkn
    go_rkn=${go_rkn:-N}
    if [[ $go_rkn =~ ^[Yy] ]]; then
        if ! rkn_install_or_upgrade; then
            echo -e "${WARNING_T} Установка защиты не завершилась (см. лог). Можно повторить позже из главного меню."
            return 1
        fi
    else
        echo -e "${YELLOW}Шаг 3 пропущен.${NC}"
    fi

    register_global_commands || return 1

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "🎉   ЭКСПРЕСС-УСТАНОВКА ЗАВЕРШЕНА!   🎉"
    echo -e "   Команды: ${CYAN}safe-remnanode-setup${NC} / ${CYAN}remnanode${NC} / ${CYAN}rkn-watcher${NC}"
    echo -e "   Лог: ${BLUE}$LOG_FILE${NC}"
    echo -e "${GREEN}========================================================${NC}"
    pause_prompt
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================
main_menu() {
    while true; do
        show_header
        echo -e "${WHITE}ГЛАВНОЕ МЕНЮ:${NC}\n"
        echo " 1. 🚀 Экспресс: полная установка (сервер + нода + защита)"
        echo " 2. 🖥️  Настройка сервера (обновление, Docker, BBR, sysctl)"
        echo " 3. 📦 Установка ноды Remnawave"
        echo " 4. 🛡️  Установка защиты RKN-Watcher"
        echo ""
        echo " 5. 🔧 Управление нодой (домен, SSL, Xray, порты, логи...)"
        echo " 6. 🛡️  Управление защитой (блок-листы, GeoIP, настройки)"
        echo ""
        echo " 7. 🧪 Диагностика и мульти-тесты сервера"
        echo " 8. 🌐 Управление IPv6 (вкл/выкл + откат)"
        echo " 9. 🔥 Статус UFW"
        echo ""
        echo " 0. Выйти"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        read -r -p "Выбор: " choice || choice=0
        case $choice in
            1) express_install ;;
            2)
                if check_root; then base_setup; else echo "Нужен root"; pause_prompt; fi
                ;;
            3)
                if check_root; then rn_initial_setup; else echo "Нужен root"; pause_prompt; fi
                ;;
            4)
                if check_root; then rkn_install_or_upgrade; else echo "Нужен root"; pause_prompt; fi
                ;;
            5) rn_node_menu ;;
            6) rkn_protect_menu ;;
            7) run_multitest ;;
            8)
                if check_root; then ipv6_menu; else echo "Нужен root"; pause_prompt; fi
                ;;
            9) manage_ufw ;;
            0) log "Exit"; exit 0 ;;
            *) echo "Неверно"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# CLI И ТОЧКА ВХОДА
# ==============================================================================
print_usage() {
    cat <<EOF
🛡️ SAFE REMNANODE SETUP v${UNIVERSAL_VERSION}
Объединяет: Setup-and-Test-Server-Ubuntu-24 + setup-remna-node + RKN-Watcher

Использование: $0 [команда]

Команды:
  install-cli       установить локальную копию и команды-синонимы
  menu              интерактивное главное меню (по умолчанию)
  express           полная установка: сервер + нода + защита
  server            настройка сервера (база, Docker, BBR, sysctl)
  node              установка ноды Remnawave
  node-menu         меню управления нодой
  node-logs [зона]  настроить логи и (опционально) путь TLS-сертификата в контейнере
  node-transports <tls> <xhttp[/tcp|/udp]> <hy2>  применить порты без пересоздания контейнеров
  node-check-ports  проверить локальные слушатели Xray для трёх транспортов
  protect           установка/обновление защиты RKN-Watcher
  protect-menu      меню управления защитой
  protect-update    обновить блок-листы TSPUBLOCK/GOVIPS
  protect-apply     пере-применить правила защиты
  protect-status    статус защиты
  protect-uninstall полное удаление защиты
  multitest         диагностика и мульти-тесты
  ipv6              управление IPv6

Команды-синонимы (при запуске как remnanode / rkn-watcher):
  remnanode install|menu ...   → управление нодой
  rkn-watcher install|update|apply|status|uninstall|menu → защита
EOF
}

main() {
    local cmd=${1:-menu} basename_cmd=${0##*/}
    case "$cmd" in -h|--help|help) print_usage; return 0 ;; esac
    check_root >&2 || return 1
    case "$cmd:$basename_cmd" in
        protect-status:*|status:rkn-watcher*) rkn_show_status noninteractive; return $? ;;
        node-check-ports:*) rn_check_transport_ports; return $? ;;
    esac
    SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    init_logging
    check_os
    detect_arch
    trap 'echo -e "\n${YELLOW}Прервано${NC}"; exit 130' INT

    # Совместимость с оригинальными командами по имени файла
    if [[ "$basename_cmd" == "remnanode"* ]]; then
        case "$cmd" in
            install|setup) rn_initial_setup; return $? ;;
            menu|"") rn_node_menu; return 0 ;;
        esac
    fi
    if [[ "$basename_cmd" == "rkn-watcher"* ]]; then
        case "$cmd" in
            install) rkn_install_or_upgrade; return 0 ;;
            update) rkn_update_all; return $? ;;
            apply) rkn_apply_all; return $? ;;
            status) rkn_show_status noninteractive; return 0 ;;
            uninstall) rkn_uninstall_all; return 0 ;;
            menu|"") rkn_protect_menu; return 0 ;;
        esac
    fi

    case "$cmd" in
        install-cli) register_global_commands && setup_general_logrotate ;;
        menu|"") main_menu ;;
        express) express_install ;;
        server) check_root && base_setup ;;
        node) rn_initial_setup ;;
        node-menu) rn_node_menu ;;
        node-logs) rn_apply_node_logging "${@:2}" ;;
        node-transports) rn_set_existing_transport_ports "${@:2}" ;;
        protect) rkn_install_or_upgrade ;;
        protect-menu) rkn_protect_menu ;;
        protect-update) rkn_update_all ;;
        protect-apply) rkn_apply_all ;;
        protect-status) rkn_show_status noninteractive ;;
        protect-uninstall) rkn_uninstall_all ;;
        multitest) run_multitest ;;
        ipv6) ipv6_menu ;;
        -h|--help|help) print_usage ;;
        *)
            echo -e "${ERROR_T} Неизвестная команда: $cmd"
            print_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
