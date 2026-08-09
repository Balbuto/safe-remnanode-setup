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
#   - Безопасные загрузки: только HTTPS, опциональная проверка SHA256
#   - Логирование всех действий + бэкапы изменяемых файлов
#   - Регистрация глобальных команд: safe-remnanode-setup / remnanode / rkn-watcher
#   - Автоперезапуск с реального терминала при запуске через curl | bash
# ==============================================================================

set -Eeuo pipefail

# --- ЖЁСТКАЯ ПРОВЕРКА ПРАВ ROOT (до инициализации всего остального) ---
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[✗] Ошибка: Скрипт должен быть запущен от имени root! Используйте: sudo $0\033[0m" >&2
    exit 1
fi

# --- Ссылка на сырой код скрипта в репозитории (для удалённой регистрации) ---
UNIVERSAL_SCRIPT_URL="https://raw.githubusercontent.com/Balbuto/safe-remnanode-setup/main/safe-remnanode-setup.sh"
UNIVERSAL_VERSION="1.1.0"

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'
MAGENTA='\033[0;35m'; NC='\033[0m'

# --- Символы ---
CHECK_MARK="✅"; CROSS_MARK="❌"; WARNING="⚠️"; INFO="ℹ️"
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
    for path in "/var/log/remna-universal.log" "/tmp/remna-universal.log" "$HOME/remna-universal.log"; do
        if touch "$path" 2>/dev/null; then
            LOG_FILE="$path"
            log "Лог: $LOG_FILE"
            return 0
        fi
    done
    LOG_FILE="/dev/null"
    echo -e "${WARNING} Логирование в файл отключено, использую /dev/null" >&2
}

log_file() { echo "${LOG_FILE:-/dev/null}"; }

# Ротация общего лога скрипта (ранее не ротировался)
setup_general_logrotate() {
    cat > /etc/logrotate.d/remna-universal <<'EOF'
/var/log/remna-universal.log {
    daily
    size 50M
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
# БЕЗОПАСНАЯ ЗАГРУЗКА ВНЕШНИХ СКРИПТОВ (только HTTPS + опциональный SHA256)
# ==============================================================================
secure_download() {
    local url="$1" dest="$2" expected_sha="${3:-}"
    echo -e "${INFO} Скачивание: ${CYAN}$url${NC}"

    if [[ ! "$url" =~ ^https:// ]]; then
        echo -e "${CROSS_MARK} ${RED}Заблокировано: только HTTPS разрешён${NC}"
        return 1
    fi
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o "$dest" "$url"; then
        echo -e "${CROSS_MARK} Не удалось скачать $url"
        return 1
    fi
    local sha; sha=$(sha256sum "$dest" | awk '{print $1}')
    echo -e "  SHA256: ${YELLOW}$sha${NC}"
    echo -e "  Размер: $(wc -c < "$dest") байт"
    if [[ -n "$expected_sha" ]]; then
        if [[ "$sha" != "$expected_sha" ]]; then
            echo -e "${CROSS_MARK} ${RED}Хэш не совпал! Ожидалось: $expected_sha${NC}"
            rm -f "$dest"; return 1
        else
            echo -e "${CHECK_MARK} Хэш совпал"
        fi
    else
        echo -e "${WARNING} Верификация хэша отключена — скрипт запускается без проверки."
    fi
    chmod +x "$dest"; return 0
}

# run_verified_script "Name" "url" "sha" -- arg1 arg2 ...
run_verified_script() {
    local name="$1" url="$2" expected_sha="${3:-}"
    shift 3
    if [[ "${1:-}" == "--" ]]; then shift; fi
    local args=("$@")
    local tmp
    tmp="/tmp/verified-$(echo "$name" | tr ' /' '_')-$$.sh"
    echo -e "\n${CYAN}━━━━━━━━ $name ━━━━━━━━${NC}"
    if secure_download "$url" "$tmp" "$expected_sha"; then
        log "Running verified script: $name $url ${args[*]:-}"
        bash "$tmp" "${args[@]}"
        local rc=$?
        rm -f "$tmp"; return $rc
    else
        echo -e "${CROSS_MARK} Пропуск $name"; return 1
    fi
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
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        usermod -aG docker "$SUDO_USER" 2>/dev/null || true
        log "Пользователь $SUDO_USER добавлен в группу docker"
    fi
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

# UFW-менеджер (Balbuto/ufw-manager)
manage_ufw() {
    show_header; check_root || { pause_prompt; return; }
    local UFW_DIR="$HOME/network-managers/ufw-manager"
    mkdir -p "$(dirname "$UFW_DIR")"
    if [[ ! -d "$UFW_DIR/.git" ]]; then
        echo "Клонирую Balbuto/ufw-manager..."
        git clone https://github.com/Balbuto/ufw-manager.git "$UFW_DIR" || { echo -e "${CROSS_MARK} Не удалось клонировать ufw-manager"; pause_prompt; return; }
    else (cd "$UFW_DIR" && git fetch --all -q) || true; fi
    cd "$UFW_DIR"; echo -e "\nПоследние коммиты:"; git log --oneline -5 2>/dev/null || true; echo ""
    read -r -p "Проверить diff перед запуском? [Y/n] " d; d=${d:-Y}
    if [[ $d =~ ^[Yy] ]]; then git diff HEAD 2>/dev/null || true; read -p "Запустить ufw-manager.sh? (y/N): " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]] || { cd ~; return; }; fi
    export SSH_CLIENT="${SSH_CLIENT:-0.0.0.0 22 0}"
    bash ./ufw-manager.sh || true
    cd ~
}
# ==============================================================================
# МОДУЛЬ B: УСТАНОВКА И УПРАВЛЕНИЕ НОДОЙ REMNAWAVE (из setup_node.sh v1.7.2)
# ==============================================================================
RN_APP_DIR="/opt/remnanode"
RN_LOG_DIR="/var/log/remnanode"
RN_LOG_FILE="/var/log/remnanode_install.log"
RN_XRAY_BIN_DIR="/opt/remnanode/bin"
RN_XRAY_FILE="$RN_XRAY_BIN_DIR/xray"
RN_CERTS_DIR="/opt/remnanode/certs"
RN_WWW_DIR="/var/www/html"

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
    if [ -f /etc/sysctl.d/99-remnanode.conf ]; then
        cp /etc/sysctl.d/99-remnanode.conf /etc/sysctl.d/99-remnanode.conf.bak
    fi
    # КОНФЛИКТ-ФИКС: /etc/sysctl.d/99-server.conf (профиль из модуля настройки сервера)
    # применяется sysctl ПОСЛЕ 99-remnanode.conf (лексический порядок) и перекрывал бы
    # ключевые настройки профиля ноды (somaxconn, conntrack, буферы и т.п.).
    # Отключаем его с бэкапом, чтобы профиль ноды применялся полностью.
    if [ -f /etc/sysctl.d/99-server.conf ]; then
        cp -a /etc/sysctl.d/99-server.conf "/etc/sysctl.d/99-server.conf.bak.$(date +%s)"
        rm -f /etc/sysctl.d/99-server.conf
        rn_log "${WARNING_T} /etc/sysctl.d/99-server.conf отключён (конфликт профилей), бэкап сохранён."
    fi
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

    sysctl --system >> "$RN_LOG_FILE" 2>&1 || true
    rn_log "${SUCCESS_T} Сетевые параметры ядра и системные лимиты успешно обновлены."
}

# --- Установка зависимостей ноды (с переиспользованием установленного Docker) ---
rn_install_dependencies() {
    rn_log "${INFO_T} Установка необходимых пакетов..."
    apt_update || true
    apt_install curl wget jq unzip tar cron logrotate ufw certbot ca-certificates gnupg python3-pip perl openssl || true

    if ! command -v docker &> /dev/null; then
        rn_log "${INFO_T} Docker не найден — установка через официальный репозиторий..."
        install_docker_apt || { rn_log "${ERROR_T} Не удалось установить Docker!"; return 1; }
    else
        rn_log "${SUCCESS_T} Docker уже установлен."
    fi
}

# --- Менеджер версий Xray-Core ---
rn_select_xray_version() {
    rn_log "${INFO_T} Получение версий Xray-Core с GitHub..."
    local releases_json
    releases_json=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases 2>/dev/null || echo "")

    if [ -z "$releases_json" ]; then
        rn_log "${WARNING_T} Не удалось получить список версий с API GitHub. Будет установлена встроенная в контейнер версия."
        RN_XRAY_VERSION_CHOICE="built-in"
        return
    fi

    local versions
    # || true: если jq отсутствует (редкий край), не роняем скрипт под set -e
    versions=$(echo "$releases_json" | jq -r '.[] | "\(.tag_name) (Pre-release: \(.prerelease))"' 2>/dev/null || true)

    echo -e "\n${BLUE}✨ ВЫБОР ВЕРСИИ XRAY-CORE${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    local i=1
    declare -A version_map

    echo -e " 1) Использовать версию из контейнера (по умолчанию)"
    version_map[1]="built-in"

    while IFS= read -r line; do
        if [ $i -ge 10 ]; then break; fi
        local tag_name; tag_name=$(echo "$line" | awk '{print $1}')
        local is_pre; is_pre=$(echo "$line" | grep -q "Pre-release: true" && echo "yes" || echo "no")

        local display_tag="$tag_name"
        if [ "$is_pre" = "yes" ]; then
            display_tag="${tag_name} ${RED}[Pre-release]${NC}"
        else
            display_tag="${tag_name} ${GREEN}[Stable]${NC}"
        fi

        echo -e " $((i+1))) Xray-Core $display_tag"
        version_map[$((i+1))]="$tag_name"
        ((i++))
    done <<< "$versions"

    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -r -p "Выберите номер версии [1]: " version_num
    version_num=${version_num:-1}

    RN_XRAY_VERSION_CHOICE="${version_map[$version_num]:-built-in}"
    rn_log "${SUCCESS_T} Выбран вариант: ${CYAN}$RN_XRAY_VERSION_CHOICE${NC}"

    if [ "$RN_XRAY_VERSION_CHOICE" != "built-in" ]; then
        if ! rn_download_xray_core "$RN_XRAY_VERSION_CHOICE"; then
            rn_log "${WARNING_T} Не удалось загрузить выбранную версию — будет использована встроенная в контейнер."
            RN_XRAY_VERSION_CHOICE="built-in"
        fi
    fi
}

rn_download_xray_core() {
    local version="$1"
    rn_log "${INFO_T} Загрузка Xray-Core ${version} для архитектуры ${ARCH_XRAY}..."

    mkdir -p "$RN_XRAY_BIN_DIR"
    local temp_dir; temp_dir=$(mktemp -d)

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH_XRAY}.zip"

    if ! wget -q --show-progress -O "$temp_dir/xray.zip" "$download_url"; then
        rn_log "${ERROR_T} Не удалось скачать Xray-Core!"
        rm -rf "$temp_dir"
        return 1
    fi

    unzip -q -o "$temp_dir/xray.zip" -d "$temp_dir"
    mv "$temp_dir/xray" "$RN_XRAY_FILE"
    chmod +x "$RN_XRAY_FILE"

    mv "$temp_dir/geoip.dat" "$RN_XRAY_BIN_DIR/geoip.dat" 2>/dev/null || true
    mv "$temp_dir/geosite.dat" "$RN_XRAY_BIN_DIR/geosite.dat" 2>/dev/null || true

    rm -rf "$temp_dir"
    rn_log "${SUCCESS_T} Xray-Core успешно сохранен в $RN_XRAY_FILE"
}

# --- Логирование и ротация логов на хосте ---
rn_setup_logging_and_rotation() {
    rn_log "${INFO_T} Настройка папок логов и автоматической ротации..."

    mkdir -p "$RN_LOG_DIR/node"
    mkdir -p "$RN_LOG_DIR/nginx"

    local logrotate_config="/etc/logrotate.d/remnanode"

    cat > "$logrotate_config" <<EOF
$RN_LOG_DIR/node/*.log $RN_LOG_DIR/nginx/*.log {
    daily
    size 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    sharedscripts
    postrotate
        docker restart remnawave-nginx 2>/dev/null || true
    endscript
}
EOF

    chmod 644 "$logrotate_config"
    rn_log "${SUCCESS_T} Лог-файлы будут записываться на хосте в каталог ${BLUE}$RN_LOG_DIR${NC}"
    rn_log "${SUCCESS_T} Logrotate настроен: ротация ежедневная / при достижении 50MB, хранение 7 архивов."
}

rn_extract_base_domain() {
    local domain="$1"
    echo "$domain" | awk -F. '{ if (NF <= 2) print $0; else print $(NF-1)"."$NF }'
}

# --- Универсальный выпуск SSL (Cloudflare DNS / Standalone / Gcore DNS) ---
rn_issue_ssl_certificates_multi() {
    local domain="$1"

    echo -e "\n${BLUE}🔐 ВЫБОР МЕТОДА ВЫПУСКА SSL СЕРТИФИКАТА${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo " 1) Cloudflare API (DNS-01, с поддержкой wildcard *.домен)"
    echo " 2) Certbot Standalone (HTTP-01, проверка по 80 порту - стандартно)"
    echo " 3) Gcore DNS API (DNS-01, с поддержкой wildcard *.домен)"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -r -p "Выберите метод выпуска [2]: " ssl_method
    ssl_method=${ssl_method:-2}

    local base_domain; base_domain=$(rn_extract_base_domain "$domain")
    local wildcard_domain="*.$base_domain"

    read -r -p "Введите ваш email для Let's Encrypt: " le_email
    while [ -z "$le_email" ]; do
        read -r -p "${RED}Email обязателен для получения SSL: ${NC}" le_email
    done

    mkdir -p "$RN_CERTS_DIR"

    case $ssl_method in
        1)
            rn_log "${INFO_T} Подготовка к выпуску сертификата через Cloudflare API (DNS-01)..."
            apt_install python3-certbot-dns-cloudflare || true

            echo -e "\nВыберите метод авторизации Cloudflare:"
            echo " 1) Через API Token (Рекомендуется, более безопасно)"
            echo " 2) Через Global API Key (Устаревший метод)"
            read -r -p "Ваш выбор [1]: " cf_auth_method
            cf_auth_method=${cf_auth_method:-1}

            mkdir -p ~/.secrets/certbot

            if [ "$cf_auth_method" -eq 1 ]; then
                read -r -p "Введите ваш Cloudflare API Token: " cf_token
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $cf_token
EOL
            else
                read -r -p "Введите ваш Cloudflare Email: " cf_email
                read -r -p "Введите ваш Global API Key: " cf_key
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $cf_email
dns_cloudflare_api_key = $cf_key
EOL
            fi

            chmod 600 ~/.secrets/certbot/cloudflare.ini

            rn_log "${INFO_T} Запуск выпуска Wildcard-сертификата (*.${base_domain})..."
            if certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                cp "/etc/letsencrypt/live/$base_domain/fullchain.pem" "$RN_CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$base_domain/privkey.pem" "$RN_CERTS_DIR/privkey.pem"
                rn_log "${SUCCESS_T} Wildcard SSL сертификат успешно выпущен через Cloudflare DNS!"
            else
                rn_log "${ERROR_T} Ошибка выпуска сертификата через Cloudflare API! Проверьте лог $RN_LOG_FILE"
                return 1
            fi
            ;;

        2)
            rn_log "${INFO_T} Выпуск сертификата в Standalone режиме (HTTP-01)..."

            systemctl stop nginx 2>/dev/null || true
            docker stop remnawave-nginx 2>/dev/null || true

            if command -v ufw &> /dev/null; then
                ufw allow 80/tcp comment 'HTTP for Certbot verification' >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            fi

            rn_log "${INFO_T} Проверка освобождения порта 80 перед запуском certbot..."
            local port_80_wait=15
            local port_80_free=0
            local i
            for ((i=1; i<=port_80_wait; i++)); do
                if ! ss -tln 2>/dev/null | awk '$4 ~ /:80$/ {busy=1} END {exit busy}'; then
                    port_80_free=1
                    break
                fi
                sleep 1
            done
            if [ "$port_80_free" -ne 1 ]; then
                rn_log "${ERROR_T} Порт 80 всё ещё занят после остановки контейнеров. Освободите его вручную и повторите выпуск SSL."
                return 1
            fi
            rn_log "${SUCCESS_T} Порт 80 свободен. Запускаем certbot --standalone..."

            if certbot certonly \
                --standalone \
                -d "$domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$RN_CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$domain/privkey.pem" "$RN_CERTS_DIR/privkey.pem"
                rn_log "${SUCCESS_T} SSL сертификат успешно выпущен в Standalone режиме!"
            else
                rn_log "${ERROR_T} Не удалось выпустить SSL сертификат! Ознакомьтесь с логом $RN_LOG_FILE"
                return 1
            fi
            ;;

        3)
            rn_log "${INFO_T} Подготовка к выпуску сертификата через Gcore DNS API (DNS-01)..."

            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                rn_log "${INFO_T} Установка плагина certbot-dns-gcore..."
                python3 -m pip install --break-system-packages certbot-dns-gcore >> "$RN_LOG_FILE" 2>&1 || \
                python3 -m pip install certbot-dns-gcore >> "$RN_LOG_FILE" 2>&1
            fi

            read -r -p "Введите ваш Gcore API Token: " gcore_token

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $gcore_token
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            rn_log "${INFO_T} Запуск выпуска Wildcard-сертификата (*.${base_domain}) через Gcore..."
            if certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$RN_LOG_FILE" 2>&1; then

                cp "/etc/letsencrypt/live/$base_domain/fullchain.pem" "$RN_CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$base_domain/privkey.pem" "$RN_CERTS_DIR/privkey.pem"
                rn_log "${SUCCESS_T} Wildcard SSL сертификат успешно выпущен через Gcore DNS!"
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

    chmod 600 "$RN_CERTS_DIR/"*

    local active_domain="$domain"
    if [ "$ssl_method" -eq 1 ] || [ "$ssl_method" -eq 3 ]; then
        active_domain="$base_domain"
    fi

    local renew_hook_file="/etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh"
    mkdir -p "$(dirname "$renew_hook_file")"
    cat > "$renew_hook_file" <<EOF
#!/bin/bash
if [ -d "/etc/letsencrypt/live/$active_domain" ]; then
    cp "/etc/letsencrypt/live/$active_domain/fullchain.pem" "$RN_CERTS_DIR/fullchain.pem"
    cp "/etc/letsencrypt/live/$active_domain/privkey.pem" "$RN_CERTS_DIR/privkey.pem"
    chmod 600 "$RN_CERTS_DIR/"*
    docker restart remnanode 2>/dev/null || true
fi
EOF
    chmod +x "$renew_hook_file"
}

# --- Маскировочные шаблоны (Selfsteal + мутатор Mrvibecodic/node-templates) ---
rn_generate_masked_template() {
    local decoy_domain="$1"
    local chosen_template_arg="${2:-}"

    rn_log "${INFO_T} Загрузка профессиональных шаблонов маскировки Mrvibecodic/node-templates..."

    mkdir -p "$RN_WWW_DIR"
    local temp_zip; temp_zip=$(mktemp)

    local templates_url="https://github.com/Mrvibecodic/node-templates/archive/refs/heads/main.zip"
    if ! wget -q -O "$temp_zip" "$templates_url"; then
        rn_log "${WARNING_T} Не удалось скачать шаблоны Mrvibecodic, генерируем базовую уникальную HTML заглушку."
        rn_create_fallback_html "$decoy_domain"
        rm -f "$temp_zip"
        return
    fi

    local temp_unzip; temp_unzip=$(mktemp -d)
    unzip -q -o "$temp_zip" -d "$temp_unzip"

    local repo_root="$temp_unzip/node-templates-main"
    if [ ! -d "$repo_root" ]; then
        rn_log "${WARNING_T} Ошибка структуры архива. Генерируем базовую HTML заглушку."
        rn_create_fallback_html "$decoy_domain"
        rm -rf "$temp_unzip" "$temp_zip"
        return
    fi

    local templates=("endless-verify" "esports-stream-template" "levelup-hub" "playza-game-catalog" "rybaliti-2.0" "screenwire-digest" "vibrai-photo-editor" "worldzoo-stream-template")

    local selected_template=""
    if [ -n "$chosen_template_arg" ]; then
        selected_template="$chosen_template_arg"
    else
        selected_template="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    rn_log "${INFO_T} Выбран профессиональный шаблон маскировки: ${CYAN}$selected_template${NC}"

    local temp_out; temp_out=$(mktemp -d)

    rn_log "${INFO_T} Запуск мутатора уникальности кода 'uniquify-theme'..."
    if bash "$repo_root/uniquify-theme.sh" \
        -s "$repo_root/$selected_template" \
        -o "$temp_out" \
        --seed "$(openssl rand -hex 16)" \
        --no-zip \
        --no-install-deps >> "$RN_LOG_FILE" 2>&1; then

        rm -rf "${RN_WWW_DIR:?}"/* 2>/dev/null || true
        mkdir -p "$RN_WWW_DIR"
        cp -r "$temp_out"/* "$RN_WWW_DIR/"
        rn_log "${SUCCESS_T} Маскировочный сайт успешно сгенерирован и полностью уникализирован по хэшам и классам!"
    else
        rn_log "${WARNING_T} Ошибка работы мутатора uniquify-theme. Копируем файлы без мутации."
        rm -rf "${RN_WWW_DIR:?}"/* 2>/dev/null || true
        mkdir -p "$RN_WWW_DIR"
        cp -r "$repo_root/$selected_template"/* "$RN_WWW_DIR/"
    fi

    rm -rf "$temp_unzip" "$temp_zip" "${temp_out:-}"
}

rn_create_fallback_html() {
    local domain="$1"
    mkdir -p "$RN_WWW_DIR"
    local rand_id; rand_id=$(openssl rand -hex 8)
    cat > "$RN_WWW_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="server-hash" content="${rand_id}">
    <title>Сайт на реконструкции</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: #f8f9fa; color: #212529; margin: 0; }
        .container { text-align: center; padding: 2rem; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); background: white; }
        h1 { font-size: 24px; margin-bottom: 8px; }
        p { color: #6c757d; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Сайт временно недоступен</h1>
        <p>На данном ресурсе ведутся запланированные технические работы. Пожалуйста, зайдите позже.</p>
    </div>
</body>
</html>
EOF
}

# --- Развертывание Docker Compose ---
rn_deploy_compose() {
    local protocol="$1"
    local node_port="$2"
    local secret_key="$3"

    mkdir -p "$RN_APP_DIR"
    cd "$RN_APP_DIR"

    cat > .env <<EOF
### REMNANODE CONFIG ###
NODE_PORT=$node_port
SECRET_KEY=$secret_key
XTLS_API_PORT=61000
EOF
    # SECRET_KEY — чувствительные данные: файл не должен быть читаем другими
    chmod 600 .env

    local snakeoil_cert="$RN_CERTS_DIR/snakeoil.pem"
    local snakeoil_key="$RN_CERTS_DIR/snakeoil.key"
    if [ ! -f "$snakeoil_cert" ]; then
        mkdir -p "$RN_CERTS_DIR"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$snakeoil_key" \
            -out "$snakeoil_cert" \
            -subj "/CN=localhost" >> "$RN_LOG_FILE" 2>&1
        chmod 600 "$snakeoil_key" "$snakeoil_cert"
    fi

    cat > docker-compose.yml <<EOF
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
    volumes:
      - /dev/shm:/dev/shm:rw
      - $RN_LOG_DIR/node:/var/log/supervisor
$( [ "$protocol" = "tls" ] || [ "$protocol" = "xhttp" ] && echo "      - $RN_CERTS_DIR:/etc/xray/certs:ro" )
$( [ "$RN_XRAY_VERSION_CHOICE" != "built-in" ] && echo "      - $RN_XRAY_FILE:/usr/local/bin/xray" )
$( [ "$RN_XRAY_VERSION_CHOICE" != "built-in" ] && [ -f "$RN_XRAY_BIN_DIR/geoip.dat" ] && echo "      - $RN_XRAY_BIN_DIR/geoip.dat:/usr/local/share/xray/geoip.dat" )
$( [ "$RN_XRAY_VERSION_CHOICE" != "built-in" ] && [ -f "$RN_XRAY_BIN_DIR/geosite.dat" ] && echo "      - $RN_XRAY_BIN_DIR/geosite.dat:/usr/local/share/xray/geosite.dat" )

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - $RN_WWW_DIR:/var/www/html:ro
      - $RN_LOG_DIR/nginx:/var/log/nginx
      - $RN_CERTS_DIR/snakeoil.pem:/etc/nginx/ssl/snakeoil.pem:ro
      - $RN_CERTS_DIR/snakeoil.key:/etc/nginx/ssl/snakeoil.key:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

    if [ "$protocol" = "reality" ]; then
        cat > nginx.conf <<EOF
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $RN_DECOY_DOMAIN;
    ssl_certificate "/etc/nginx/ssl/snakeoil.pem";
    ssl_certificate_key "/etc/nginx/ssl/snakeoil.key";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    else
        cat > nginx.conf <<EOF
server {
    listen unix:/dev/shm/nginx.sock proxy_protocol default_server;
    server_name _;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    rn_log "${INFO_T} Запуск контейнеров Docker..."
    docker compose down &>/dev/null || true
    if docker compose up -d >> "$RN_LOG_FILE" 2>&1; then
        rn_log "${SUCCESS_T} Контейнеры успешно развернуты и запущены!"
    else
        rn_log "${ERROR_T} Ошибка запуска контейнеров! Проверьте логи: $RN_LOG_FILE"
        return 1
    fi
}

# --- Фаервол (UFW) для ноды ---
rn_configure_firewall() {
    local node_port="$1"
    local panel_ip="$2"

    rn_log "${INFO_T} Настройка брандмауэра UFW..."

    ufw default deny incoming >> "$RN_LOG_FILE" 2>&1 || true
    ufw default allow outgoing >> "$RN_LOG_FILE" 2>&1 || true

    local ssh_port=22
    if command -v ss &>/dev/null; then
        local detected_port; detected_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -n 1)
        if [ -n "$detected_port" ]; then
            ssh_port="$detected_port"
        fi
    fi
    rn_log "${INFO_T} Разрешаем активный порт SSH: ${CYAN}$ssh_port${NC}"
    ufw allow "$ssh_port"/tcp comment 'SSH Port' >> "$RN_LOG_FILE" 2>&1 || true

    rn_log "${INFO_T} Разрешаем порты HTTP (80) и HTTPS (443) для Xray/Nginx..."
    {
        ufw allow 80/tcp comment 'HTTP / Certbot'
        ufw allow 443/tcp comment 'Xray Incoming TCP'
        ufw allow 443/udp comment 'Xray Incoming UDP'
    } >> "$RN_LOG_FILE" 2>&1 || true

    if [ -f "$RN_APP_DIR/.xray_ports" ]; then
        local custom_ports; custom_ports=$(tr '\n' ' ' < "$RN_APP_DIR/.xray_ports" | xargs)
        local port
        for port in $custom_ports; do
            if [ -n "$port" ]; then
                rn_log "${INFO_T} Открытие в UFW кастомного порта Xray: ${CYAN}$port${NC}"
                {
                    ufw allow "$port"/tcp comment 'Xray Custom Port TCP'
                    ufw allow "$port"/udp comment 'Xray Custom Port UDP'
                } >> "$RN_LOG_FILE" 2>&1 || true
            fi
        done
    fi

    rn_log "${INFO_T} Ограничиваем порт управления ${CYAN}$node_port${NC} только для IP панели: ${GREEN}$panel_ip${NC}"
    {
        ufw allow from "$panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel'
        ufw --force enable
        ufw reload
    } >> "$RN_LOG_FILE" 2>&1 || true

    rn_log "${SUCCESS_T} Брандмауэр UFW успешно настроен!"
}

# --- Первоначальная установка ноды (полный интерактивный флоу) ---
rn_initial_setup() {
    cls
    rn_log "${INFO_T} Запуск первоначальной настройки и установки ноды..."

    if [ -f "$RN_APP_DIR/docker-compose.yml" ]; then
        echo -e "${WARNING_T} Нода уже установлена. Повторная установка ПЕРЕЗАПИШЕТ"
        echo -e "${WARNING_T} secret key и конфигурацию — панель потеряет текущую ноду."
        read -r -p "Всё равно продолжить? (y/N): " reinstall
        [[ "${reinstall:-n}" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Отменено.${NC}"; return; }
    fi

    mkdir -p "$RN_APP_DIR"
    rm -f "$RN_APP_DIR/.xray_ports"

    echo ""
    echo -e "${BLUE}⚙️  ЭТАП 1: СЕТЕВАЯ ОПТИМИЗАЦИЯ И ЗАВИСИМОСТИ${NC}"
    read -r -p "Применить сетевую оптимизацию (BBR + sysctl профиль по ОЗУ)? [Y/n]: " do_opt; do_opt=${do_opt:-Y}
    if [[ $do_opt =~ ^[Yy] ]]; then rn_optimize_network; fi
    if ! rn_install_dependencies; then
        rn_log "${ERROR_T} Установка зависимостей не удалась — установка ноды прервана."
        pause_prompt
        return 1
    fi

    echo ""
    echo -e "${BLUE}⚙️  ЭТАП 2: ВЕРСИЯ XRAY-CORE${NC}"
    read -r -p "Выбрать версию Xray-Core (список с GitHub)? [Y/n]: " do_xray; do_xray=${do_xray:-Y}
    if [[ $do_xray =~ ^[Yy] ]]; then rn_select_xray_version; fi

    rn_setup_logging_and_rotation

    echo -e "\n${BLUE}🔌 НАСТРОЙКА ИДЕНТИФИКАЦИИ И СВЯЗИ С ПАНЕЛЬЮ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    read -r -p "Введите IP адрес панели Remnawave (для настройки UFW): " panel_ip
    while [[ ! "$panel_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
        read -r -p "${RED}Неверный формат IP. Введите корректный IPv4 панели: ${NC}" panel_ip
    done

    read -r -p "Введите домен вашей ноды (например, node.example.com): " node_domain
    while [ -z "$node_domain" ]; do
        read -r -p "${RED}Домен ноды не может быть пустым: ${NC}" node_domain
    done
    RN_NODE_DOMAIN="$node_domain"

    read -r -p "Порт управления нодой (для панели) [2222]: " node_port
    node_port=${node_port:-2222}

    echo -e "\n${YELLOW}Вставьте сертификат ноды (secret key), выданный в панели Remnawave${NC}"
    echo -e "${GRAY}(Для окончания ввода нажмите Enter дважды подряд):${NC}"
    local certificate=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$certificate" ]; then
                break
            fi
        else
            certificate="${certificate}${line}\n"
        fi
    done

    local secret_key_value; secret_key_value=$(echo -e "$certificate" | xargs)
    while [ -z "$secret_key_value" ]; do
        rn_log "${ERROR_T} Сертификат не может быть пустым!"
        return 1
    done

    echo -e "\n${BLUE}⚙️  ВХОДЯЩИЕ ПОРТЫ ДЛЯ КЛИЕНТОВ XRAY${NC}"
    echo -e "По умолчанию порты 80 и 443 будут открыты автоматически."
    read -r -p "Желаете открыть дополнительные входящие порты для Xray в UFW? (через пробел, например: 8443 2053) [Нет]: " add_ports_choice
    add_ports_choice=${add_ports_choice:-""}
    if [ -n "$add_ports_choice" ]; then
        local clean_ports; clean_ports=$(echo "$add_ports_choice" | tr ',' ' ' | xargs)
        local p
        for p in $clean_ports; do
            if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                echo "$p" >> "$RN_APP_DIR/.xray_ports"
                rn_log "${SUCCESS_T} Порт $p добавлен в список автооткрытия."
            fi
        done
    fi

    echo -e "\nВыберите тип шифрования клиентского трафика:"
    echo " 1) VLESS Reality (маскировочный сайт / Selfsteal)"
    echo " 2) VLESS+TLS (классический TLS с вашим доменом ноды)"
    echo " 3) VLESS+TLS+xHTTP (новый высокопроизводительный транспортный протокол Xray)"
    read -r -p "Ваш выбор [1]: " proto_choice
    proto_choice=${proto_choice:-1}

    local protocol="reality"
    if [ "$proto_choice" -eq 2 ]; then
        protocol="tls"
    elif [ "$proto_choice" -eq 3 ]; then
        protocol="xhttp"
    fi

    if [ "$protocol" = "reality" ]; then
        read -r -p "Домен маскировки (decoy domain) [github.com]: " decoy_domain
        RN_DECOY_DOMAIN=${decoy_domain:-github.com}
        rn_generate_masked_template "$RN_DECOY_DOMAIN"
    else
        rn_generate_masked_template "$RN_NODE_DOMAIN"
        rn_issue_ssl_certificates_multi "$RN_NODE_DOMAIN" || { pause_prompt; return 1; }
    fi

    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" || { pause_prompt; return 1; }
    rn_configure_firewall "$node_port" "$panel_ip"

    echo "$panel_ip" > "$RN_APP_DIR/.panel_ip"
    echo "$protocol" > "$RN_APP_DIR/.protocol"
    echo "$RN_NODE_DOMAIN" > "$RN_APP_DIR/.node_domain"

    # Регистрация глобальных команд
    register_global_commands

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
    while [ -z "$new_domain" ]; do
        read -r -p "${RED}Домен не может быть пустым: ${NC}" new_domain
    done
    RN_NODE_DOMAIN="$new_domain"
    echo "$RN_NODE_DOMAIN" > "$RN_APP_DIR/.node_domain"

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$RN_APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$RN_APP_DIR/.protocol" 2>/dev/null || echo "tls")

    rn_generate_masked_template "$RN_NODE_DOMAIN"

    if [ "$protocol" = "tls" ] || [ "$protocol" = "xhttp" ]; then
        rn_issue_ssl_certificates_multi "$RN_NODE_DOMAIN" || { pause_prompt; return 1; }
    fi

    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" || { pause_prompt; return 1; }

    rn_log "${SUCCESS_T} Домен ноды успешно изменен на $RN_NODE_DOMAIN, конфигурация обновлена!"
    pause_prompt
}

# --- Установка кастомной версии Xray Core ---
rn_update_xray_core_only() {
    cls
    echo -e "${BLUE}⚡ УСТАНОВКА/ОБНОВЛЕНИЕ КАСТОМНОЙ ВЕРСИИ XRAY-CORE${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"

    if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
        rn_log "${ERROR_T} Нода еще не установлена! Пожалуйста, выполните первоначальную настройку."
        pause_prompt
        return
    fi

    rn_select_xray_version

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$RN_APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$RN_APP_DIR/.protocol" 2>/dev/null || echo "reality")
    RN_NODE_DOMAIN=$(cat "$RN_APP_DIR/.node_domain" 2>/dev/null || echo "localhost")

    rn_deploy_compose "$protocol" "$node_port" "$secret_key_value" || { pause_prompt; return 1; }

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
    while [[ ! "$new_panel_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
        read -r -p "${RED}Неверный формат IP. Введите корректный IPv4: ${NC}" new_panel_ip
    done

    local node_port; node_port=$(grep "NODE_PORT" "$RN_APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")

    if [ -n "$old_panel_ip" ]; then
        rn_log "${INFO_T} Удаление старого правила UFW для IP панели: ${YELLOW}$old_panel_ip${NC}"
        ufw delete allow from "$old_panel_ip" to any port "$node_port" proto tcp >> "$RN_LOG_FILE" 2>&1 || true
    fi

    rn_log "${INFO_T} Добавление правила UFW для нового IP панели: ${GREEN}$new_panel_ip${NC}"
    ufw allow from "$new_panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel' >> "$RN_LOG_FILE" 2>&1 || true
    ufw reload >> "$RN_LOG_FILE" 2>&1 || true

    echo "$new_panel_ip" > "$RN_APP_DIR/.panel_ip"

    rn_log "${SUCCESS_T} Разрешенный IP панели изменен на $new_panel_ip. Порт $node_port защищен UFW!"
    pause_prompt
}

# --- Полное удаление ноды с откатом изменений ---
rn_uninstall_and_rollback() {
    cls
    echo -e "${RED}⚠️  ВНИМАНИЕ! ПОЛНОЕ УДАЛЕНИЕ НОДЫ И ОТКАТ СИСТЕМЫ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo -e "${RED}Это действие полностью остановит ноду, сотрет все конфигурационные файлы,${NC}"
    echo -e "${RED}логи, маскировочные сайты, Docker-образы и вернет брандмауэр UFW/оптимизации в исходное состояние.${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -r -p "Вы уверены, что хотите продолжить? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Удаление отменено.${NC}"
        sleep 1
        return
    fi

    rn_log "${INFO_T} Остановка контейнеров Docker..."
    if [ -f "$RN_APP_DIR/docker-compose.yml" ]; then
        cd "$RN_APP_DIR"
        docker compose down -v >> "$RN_LOG_FILE" 2>&1 || true

        rn_log "${INFO_T} Извлечение и динамическое удаление образов Docker..."
        local images; images=$(grep -E '^[[:space:]]*image:' "$RN_APP_DIR/docker-compose.yml" | awk '{print $2}' | tr -d '"' | tr -d "'")
        local img
        for img in $images; do
            rn_log "${INFO_T} Удаление образа Docker: ${CYAN}$img${NC}"
            docker rmi "$img" >> "$RN_LOG_FILE" 2>&1 || true
        done
    fi

    rn_log "${INFO_T} Удаление системных оптимизаций sysctl и лимитов..."
    rm -f /etc/sysctl.d/99-remnanode.conf
    rm -f /etc/sysctl.d/99-remnanode-ipv6.conf
    rm -f /etc/security/limits.d/99-remnanode.conf
    sysctl --system >> "$RN_LOG_FILE" 2>&1 || true

    rn_log "${INFO_T} Сброс и деактивация брандмауэра UFW..."
    if command -v ufw &>/dev/null; then
        ufw --force reset >> "$RN_LOG_FILE" 2>&1 || true
    fi

    rn_log "${INFO_T} Очистка файлов и каталогов..."
    rm -rf "$RN_APP_DIR"
    rm -rf "$RN_LOG_DIR"
    rm -rf "$RN_WWW_DIR"
    rm -f /etc/logrotate.d/remnanode
    rm -f /etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh
    rm -f /usr/local/bin/remnanode

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${SUCCESS_T} Нода Remnanode и её Docker-образы успешно удалены!"
    echo -e "Все сетевые и системные параметры возвращены в исходное состояние."
    echo -e "${GREEN}========================================================${NC}\n"

    pause_prompt
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
            local node_acc_size; node_acc_size=$(du -sh "$RN_LOG_DIR/node/xray.out.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local node_err_size; node_err_size=$(du -sh "$RN_LOG_DIR/node/xray.err.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_acc_size; nginx_acc_size=$(du -sh "$RN_LOG_DIR/nginx/access.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_err_size; nginx_err_size=$(du -sh "$RN_LOG_DIR/nginx/error.log" 2>/dev/null | awk '{print $1}' || echo "0B")

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
                    tail -n 100 -f "$RN_LOG_DIR/node/xray.out.log" || true
                    ;;
                2)
                    cls
                    echo -e "${BLUE}Показ лога error.log (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$RN_LOG_DIR/node/xray.err.log" || true
                    ;;
                3)
                    cls
                    echo -e "${BLUE}Показ лога Nginx (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$RN_LOG_DIR/nginx/access.log" || true
                    ;;
                4)
                    cls
                    echo -e "${BLUE}Показ Docker-логов remnanode (Выход: Ctrl+C)...${NC}\n"
                    docker compose -f "$RN_APP_DIR/docker-compose.yml" logs -f --tail=100 || true
                    ;;
                5)
                    echo -e "${INFO_T} Запуск принудительной ротации логов..."
                    if logrotate -f /etc/logrotate.d/remnanode; then
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
        echo -e "   - Port управления нодой:  ${CYAN}$node_port${NC} (Открыт в UFW только для IP панели: ${GREEN}$panel_ip${NC})"
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

                local is_range="no"
                if [[ "$input_port" =~ ^([0-9]+):([0-9]+)$ ]]; then
                    is_range="yes"
                    local start_port="${BASH_REMATCH[1]}"
                    local end_port="${BASH_REMATCH[2]}"
                    if [ "$start_port" -lt 1 ] || [ "$end_port" -gt 65535 ] || [ "$start_port" -gt "$end_port" ]; then
                        rn_log "${ERROR_T} Некорректный диапазон портов."
                        pause_prompt
                        continue
                    fi
                elif [[ "$input_port" =~ ^[0-9]+$ ]]; then
                    if [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
                        rn_log "${ERROR_T} Некорректный номер порта."
                        pause_prompt
                        continue
                    fi
                else
                    rn_log "${ERROR_T} Некорректный ввод порта."
                    pause_prompt
                    continue
                fi

                if [ "$is_range" = "yes" ]; then
                    echo "$start_port:$end_port" >> "$RN_APP_DIR/.xray_ports"
                    {
                        ufw allow "$start_port:$end_port"/tcp comment 'Xray Custom Port Range TCP'
                        ufw allow "$start_port:$end_port"/udp comment 'Xray Custom Port Range UDP'
                    } >> "$RN_LOG_FILE" 2>&1 || true
                    rn_log "${SUCCESS_T} Диапазон портов $start_port:$end_port добавлен в UFW!"
                else
                    echo "$input_port" >> "$RN_APP_DIR/.xray_ports"
                    {
                        ufw allow "$input_port"/tcp comment 'Xray Custom Port TCP'
                        ufw allow "$input_port"/udp comment 'Xray Custom Port UDP'
                    } >> "$RN_LOG_FILE" 2>&1 || true
                    rn_log "${SUCCESS_T} Порт $input_port добавлен в UFW!"
                fi
                ufw reload >> "$RN_LOG_FILE" 2>&1 || true
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
                if [ "$del_num" -ge 1 ] && [ "$del_num" -le "${#port_list[@]}" ]; then
                    local target="${port_list[$((del_num-1))]}"
                    sed -i "/^${target}$/d" "$RN_APP_DIR/.xray_ports"
                    if [[ "$target" =~ ^([0-9]+):([0-9]+)$ ]]; then
                        ufw delete allow "$target"/tcp >> "$RN_LOG_FILE" 2>&1 || true
                        ufw delete allow "$target"/udp >> "$RN_LOG_FILE" 2>&1 || true
                    else
                        ufw delete allow "$target"/tcp >> "$RN_LOG_FILE" 2>&1 || true
                        ufw delete allow "$target"/udp >> "$RN_LOG_FILE" 2>&1 || true
                    fi
                    ufw reload >> "$RN_LOG_FILE" 2>&1 || true
                    rn_log "${SUCCESS_T} Порт $target удален из UFW."
                else
                    rn_log "${ERROR_T} Неверный номер."
                fi
                pause_prompt
                ;;
            3)
                ufw reload >> "$RN_LOG_FILE" 2>&1 || true
                rn_log "${SUCCESS_T} Правила UFW перезагружены."
                pause_prompt
                ;;
            0)
                return
                ;;
        esac
    done
}

# --- Смена маскировочного шаблона (Selfsteal) ---
rn_change_decoy_template_menu() {
    while true; do
        cls
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🎭 СМЕНА МАСКИРОВОЧНОГО ШАБЛОНА САЙТА (SELFSTEAL)"
        echo "  ========================================================"
        echo -e "${NC}"

        if [ ! -f "$RN_APP_DIR/docker-compose.yml" ]; then
            rn_log "${ERROR_T} Нода еще не установлена! Маскировка недоступна."
            pause_prompt
            return
        fi

        local node_domain; node_domain=$(cat "$RN_APP_DIR/.node_domain" 2>/dev/null || echo "localhost")

        echo -e "📌 Домен вашей ноды: ${CYAN}$node_domain${NC}"
        echo -e "--------------------------------------------------------"
        echo " 1) 🔄 Сменить шаблон на СЛУЧАЙНЫЙ (Рандомно)"
        echo " 2) 🎨 Выбрать КОНКРЕТНЫЙ шаблон из списка"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -r -p "Выберите действие [0-2]: " temp_choice
        temp_choice=${temp_choice:-0}

        local templates=("endless-verify" "esports-stream-template" "levelup-hub" "playza-game-catalog" "rybaliti-2.0" "screenwire-digest" "vibrai-photo-editor" "worldzoo-stream-template")
        local templates_ru=("Страница верификации (endless-verify)" "Киберспортивный портал (esports-stream-template)" "Игровой хаб для геймеров (levelup-hub)" "Каталог онлайн-игр (playza-game-catalog)" "Блог/Форум о рыбалке (rybaliti-2.0)" "Новостной IT-дайджест (screenwire-digest)" "Онлайн-фоторедактор (vibrai-photo-editor)" "Стримы из зоопарков (worldzoo-stream-template)")

        case $temp_choice in
            1)
                rn_generate_masked_template "$node_domain"
                docker restart remnawave-nginx >> "$RN_LOG_FILE" 2>&1 || true
                rn_log "${SUCCESS_T} Маскировочный шаблон успешно изменен на случайный и перезапущен!"
                pause_prompt
                ;;
            2)
                echo -e "\n${BLUE}Доступные профессиональные шаблоны:${NC}"
                local i
                for i in "${!templates[@]}"; do
                    echo -e " $((i+1))) ${templates_ru[$i]}"
                done
                echo -e "${GRAY}--------------------------------------------------${NC}"
                read -r -p "Выберите номер шаблона [1]: " template_num
                template_num=${template_num:-1}
                local index=$((template_num - 1))

                if [ $index -ge 0 ] && [ $index -lt ${#templates[@]} ]; then
                    local chosen="${templates[$index]}"
                    rn_generate_masked_template "$node_domain" "$chosen"
                    docker restart remnawave-nginx >> "$RN_LOG_FILE" 2>&1 || true
                    rn_log "${SUCCESS_T} Маскировочный сайт успешно изменен на '${chosen}' и перезапущен!"
                else
                    rn_log "${ERROR_T} Неверный номер шаблона."
                fi
                pause_prompt
                ;;
            0)
                return
                ;;
        esac
    done
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
        echo " 6) 🎭 Смена маскировочного шаблона сайта (Selfsteal)"
        echo " 7) 📊 Диагностика и просмотр логов ноды"
        echo " 8) 🗑️  Полное удаление ноды с откатом всех изменений"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -r -p "Выберите действие [0-8]: " menu_choice
        menu_choice=${menu_choice:-0}

        case $menu_choice in
            1) rn_initial_setup ;;
            2) rn_change_domain_and_ssl ;;
            3) rn_update_xray_core_only ;;
            4) rn_change_panel_ip ;;
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

        # Верификация SHA256 внешних скриптов отключена по требованию:
        # тесты запускаются сразу, только по HTTPS (см. secure_download).
        while true; do
            show_header
            echo -e "${CYAN}── ДОСТУПНЫЕ ТЕСТЫ ──${NC}\n"
            echo " 1) IP Region / Геолокация"
            echo " 2) Censorcheck — геоблок"
            echo " 3) Censorcheck — DPI"
            echo " 4) iPerf3 — RU сервера"
            echo " 5) iPerf3 — bench.tlab.pw (РФ)"
            echo " 6) YABS"
            echo " 7) IP Check Place"
            echo " 8) IPQuality"
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
              2) mt_run_one 2; pause_prompt ;;
              3) mt_run_one 3; pause_prompt ;;
              4) mt_run_one 4; pause_prompt ;;
              5) mt_run_one 5; pause_prompt ;;
              6) mt_run_one 6; pause_prompt ;;
              7) mt_run_one 7; pause_prompt ;;
              8) mt_run_one 8; pause_prompt ;;
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
        2) run_verified_script "Censorcheck" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "" -- --mode geoblock || true ;;
        3) run_verified_script "Censorcheck DPI" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "" -- --mode dpi || true ;;
        4) need_cmd iperf3 iperf3 || true; run_verified_script "iPerf3 RU" "https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh" "" || true ;;
        5) need_cmd iperf3 iperf3 || true; run_verified_script "iPerf3 tlab (РФ)" "https://bench.tlab.pw" "" || true ;;
        6) run_verified_script "YABS" "https://yabs.sh" "" -- -4 || true ;;
        7) run_verified_script "IP Check Place" "https://ip.check.place/script/check.sh" "" -- -l ru || true ;;
        8) run_verified_script "IPQuality" "https://check.place/script/check.sh" "" -- -l ru -I || true ;;
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
        "Censorcheck — проверка геоблока"
        "Censorcheck — DPI (серверы РФ)"
        "iPerf3 — тест до российских серверов"
        "iPerf3 — bench.tlab.pw (РФ)"
        "YABS — бенчмарк сервера"
        "IP Check Place — блокировки зарубежными сервисами"
        "IPQuality"
        "sysbench CPU — тест процессора"
        "sysbench Memory — тест оперативной памяти"
        "Network Bench — скорость (100MB)"
        "SSL/TLS check"
        "Traceroute yandex.ru"
        "Ping yandex.ru"
    )
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
        ( trap - INT; mt_run_one "$num" )
        echo ""
    done
    echo -e "${GREEN}Все тесты завершены! (${total}/${total})${NC}"
}

# РЕГИСТРАЦИЯ ГЛОБАЛЬНЫХ КОМАНД
# ==============================================================================
register_global_commands() {
    local script_path="${SCRIPT_PATH:-$(readlink -f "$0" 2>/dev/null || echo "$0")}"

    # Удалённый запуск (curl | bash): сохраняем физический файл в /usr/local/bin
    if [[ "$script_path" =~ /dev/fd/ || "$script_path" == "bash" || "$script_path" == "stdin" || ! -f "$script_path" ]]; then
        echo -e "${INFO_T} Обнаружен удалённый запуск. Сохраняю скрипт в систему..."
        mkdir -p /usr/local/bin
        if wget -q -O "/usr/local/bin/safe-remnanode-setup" "$UNIVERSAL_SCRIPT_URL"; then
            chmod +x /usr/local/bin/safe-remnanode-setup
            SCRIPT_PATH="/usr/local/bin/safe-remnanode-setup"
        fi
    fi

    if [[ -f "$script_path" && "$script_path" != "/usr/local/bin/safe-remnanode-setup" ]]; then
        # Если запущена УСТАНОВЛЕННАЯ копия из /opt/rkn-watcher (systemd-юниты защиты),
        # не перезаписываем ею более свежую копию пользователя в /usr/local/bin.
        if [[ "$script_path" == "$RKN_MAIN_SCRIPT" && -f "/usr/local/bin/safe-remnanode-setup" ]]; then
            :
        else
            cp "$script_path" /usr/local/bin/safe-remnanode-setup 2>/dev/null || true
        fi
    fi
    chmod +x /usr/local/bin/safe-remnanode-setup 2>/dev/null || true

    # Совместимые команды: remnanode → меню ноды, rkn-watcher → меню защиты
    ln -sf /usr/local/bin/safe-remnanode-setup /usr/local/bin/remnanode 2>/dev/null || true
    ln -sf /usr/local/bin/safe-remnanode-setup /usr/local/bin/rkn-watcher 2>/dev/null || true
    echo -e "${SUCCESS_T} Команды зарегистрированы: ${CYAN}safe-remnanode-setup${NC}, ${CYAN}remnanode${NC}, ${CYAN}rkn-watcher${NC}"
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
    echo -e "${INFO_T} Выполняется: обновление системы, базовый софт, Docker, BBR, авто-hardening..."
    apt_update || true
    apt_upgrade_full || true
    apt_autoclean
    apt_install mc net-tools ncdu iftop curl wget git ca-certificates gnupg lsb-release || true
    if ! command -v docker &>/dev/null; then
        install_docker_apt || echo -e "${WARNING_T} Docker не установился — проверьте лог"
    fi
    enable_bbr_cake
    apply_sysctl_auto
    apt_install irqbalance || true
    systemctl enable --now irqbalance >>"$(log_file)" 2>&1 || true
    echo -e "${SUCCESS_T} Шаг 1 завершён."
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${WARNING_T} Система требует перезагрузки (рекомендуется перед установкой ноды)."
        read -r -p "Перезагрузить сейчас? (y/N): " rr
        if [[ "${rr:-n}" =~ ^[Yy]$ ]]; then
            echo "Перезагрузка... После перезагрузки запустите: sudo safe-remnanode-setup express"
            reboot
        fi
    fi

    # --- ШАГ 2: Нода ---
    echo -e "\n${CYAN}════════════ ШАГ 2/3: УСТАНОВКА НОДЫ ════════════${NC}"
    read -r -p "Перейти к установке ноды? [Y/n]: " go_node
    go_node=${go_node:-Y}
    if [[ $go_node =~ ^[Yy] ]]; then
        if ! rn_initial_setup; then
            echo -e "${WARNING_T} Установка ноды не завершилась (см. лог). Можно повторить позже из главного меню."
        fi
    else
        echo -e "${YELLOW}Шаг 2 пропущен.${NC}"
    fi

    # --- ШАГ 3: Защита ---
    echo -e "\n${CYAN}════════════ ШАГ 3/3: УСТАНОВКА ЗАЩИТЫ ════════════${NC}"
    read -r -p "Перейти к установке защиты RKN-Watcher? [Y/n]: " go_rkn
    go_rkn=${go_rkn:-Y}
    if [[ $go_rkn =~ ^[Yy] ]]; then
        if ! rkn_install_or_upgrade; then
            echo -e "${WARNING_T} Установка защиты не завершилась (см. лог). Можно повторить позже из главного меню."
        fi
    else
        echo -e "${YELLOW}Шаг 3 пропущен.${NC}"
    fi

    register_global_commands

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
        echo " 9. 🔥 UFW-менеджер (Balbuto/ufw-manager)"
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
  menu              интерактивное главное меню (по умолчанию)
  express           полная установка: сервер + нода + защита
  server            настройка сервера (база, Docker, BBR, sysctl)
  node              установка ноды Remnawave
  node-menu         меню управления нодой
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
    SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    init_logging
    setup_general_logrotate || true
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    check_os
    detect_arch
    trap 'echo -e "\n${YELLOW}Прервано${NC}"; exit 130' INT

    local cmd=${1:-menu}
    local basename_cmd
    basename_cmd=$(basename "$0")

    # Регистрация глобальных команд при каждом запуске (как в оригинальном setup_node.sh)
    register_global_commands

    # Совместимость с оригинальными командами по имени файла
    if [[ "$basename_cmd" == "remnanode"* ]]; then
        case "$cmd" in
            install|setup) rn_initial_setup; return 0 ;;
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
        menu|"") main_menu ;;
        express) express_install ;;
        server) check_root && base_setup ;;
        node) rn_initial_setup ;;
        node-menu) rn_node_menu ;;
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

main "$@"
