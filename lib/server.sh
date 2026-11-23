#!/usr/bin/env bash
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
