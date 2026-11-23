#!/usr/bin/env bash
# systemd-юниты и таймер, logrotate, символическая ссылка, бэкапы конфигурации.

write_systemd_units() {
    cat > "$BOOT_SERVICE" <<EOF
[Unit]
Description=RKN Watcher boot restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MAIN_SCRIPT apply --quiet
# hardening: сервису нужен только сетевой доступ через netfilter
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR $LOG_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
StateDirectory=

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UPDATE_SERVICE" <<EOF
[Unit]
Description=RKN Watcher scheduled update
After=network-online.target
Wants=network-online.target
OnFailure=rkn-watcher-failure@%n.service

[Service]
Type=oneshot
ExecStart=$MAIN_SCRIPT update --quiet
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR $LOG_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
TimeoutStartSec=15min
EOF

    cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=RKN Watcher daily update timer

[Timer]
OnCalendar=*-*-* 03:00:00
# Рассеивание нагрузки на источники списков и на iptables-локи
RandomizedDelaySec=1h
AccuracySec=1m
Persistent=true
Unit=rkn-watcher-update.service

[Install]
WantedBy=timers.target
EOF

    cat > "$FAILURE_SERVICE" <<EOF
[Unit]
Description=RKN Watcher failure hook for %i

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "[%s] unit %i failed" >> $ACTION_LOG'
EOF

    systemctl daemon-reload >/dev/null 2>&1 || warn "systemctl daemon-reload не удался (нет systemd?)"
    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
}

write_logrotate_config() {
    cat > "$LOGROTATE_FILE" <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
}

enable_or_disable_timer() {
    local auto
    auto=$(get_bool_setting AUTO_UPDATE y) || auto=n
    if [[ "$auto" == "y" ]]; then
        systemctl enable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    else
        systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    fi
}

create_launcher() {
    ln -sf "$MAIN_SCRIPT" "$BIN_PATH"
    chmod 0755 "$MAIN_SCRIPT"
}

copy_self_to_install_dir() {
    local source
    source=$(readlink -f "$0")
    if [[ "$source" != "$MAIN_SCRIPT" ]]; then
        install -m 0755 "$source" "$MAIN_SCRIPT"
    fi
    chmod 0755 "$MAIN_SCRIPT"
}

backup_config() {
    ensure_dirs
    local backup dir
    backup="$DATA_DIR/backups/rkn-watcher-config-$(date '+%Y%m%d-%H%M%S').tgz"
    dir=$(dirname "$backup")
    mkdir -p "$dir"
    tar czf "$backup" -C / etc/rkn-watcher 2>/dev/null || { warn "Не удалось создать бэкап конфигурации"; return 0; }
    chmod 0600 "$backup"
    ls -1t "$dir"/*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f
    info "Бэкап конфигурации: $backup"
}

# --- установка, удаление и очистка firewall -----------------------------------

install_or_upgrade() {
    check_root
    local had_existing_config="n"
    [[ -f "$SETTINGS_FILE" || -f "$WHITELIST_FILE" || -f "$BLACKLIST_FILE" ]] && had_existing_config="y"

    require_commands apt-get python3 systemctl flock
    install_dependencies
    ensure_dirs
    if [[ "$had_existing_config" == "y" ]]; then
        backup_config
    fi
    copy_self_to_install_dir
    write_default_settings_if_missing
    write_default_json_if_missing
    copy_helper_scripts
    normalize_existing_json_files || true
    create_launcher
    write_systemd_units
    write_logrotate_config
    enable_or_disable_timer

    ensure_ipset_exists TSPUIPS hash:net 2000000 inet
    ensure_ipset_exists GOVIPS hash:net 2000000 inet

    local filter_ports log_rst auto_update enable_geo enable_tspu enable_gov use_existing port_policy noninteractive
    use_existing="n"
    noninteractive="n"
    [[ "${RKN_ASSUME_YES:-0}" == "1" ]] && noninteractive="y"
    if [[ "$noninteractive" == "y" ]]; then
        # Автоматический режим: конфигурацию не трогаем, только обновляем код.
        if [[ "$had_existing_config" == "y" ]]; then
            use_existing="y"
        else
            filter_ports="all"
            set_setting FILTER_PORTS "$filter_ports"
            set_setting LOG_RST "n"
            set_setting AUTO_UPDATE "y"
            set_setting ENABLE_TSPUBLOCK "y"
            set_setting ENABLE_GOVIPS "y"
            set_setting PORT_POLICY "geoip_only"
            "$CONFIG_TOOL" set-enabled false >/dev/null || true
        fi
    fi

    if [[ "$noninteractive" != "y" && "$had_existing_config" == "y" ]]; then
        read -r -p "Сохранить текущие настройки, если они уже есть? (y/n): " use_existing || true
        use_existing=$(normalize_yesno "$use_existing")
    fi

    if [[ "$use_existing" != "y" ]]; then
        echo
        echo "Настройка области применения GeoIP:"
        echo "1) Все порты"
        echo "2) Один порт"
        echo "3) Несколько портов"
        read -r -p "Выберите вариант (1-3): " choice || choice=1
        case "$choice" in
            2)
                read -r -p "Введите порт: " filter_ports || filter_ports=""
                validate_ports_csv "$filter_ports" || { error "Некорректный порт"; exit 1; }
                filter_ports=$(normalize_ports_csv "$filter_ports") || exit 1
                ;;
            3)
                read -r -p "Введите порты через запятую: " filter_ports || filter_ports=""
                validate_ports_csv "$filter_ports" || { error "Некорректный список портов"; exit 1; }
                filter_ports=$(normalize_ports_csv "$filter_ports") || exit 1
                ;;
            *)
                filter_ports="all"
                ;;
        esac

        echo
        echo "Политика по портам (PORT_POLICY):"
        echo "1) geoip_only — GeoIP фильтрует порты из FILTER_PORTS, остальные открыты (по умолчанию)"
        echo "2) strict     — открыты только порты из FILTER_PORTS, всё остальное закрывается"
        read -r -p "Выберите вариант (1-2): " choice_policy || choice_policy=1
        case "${choice_policy:-1}" in
            2) port_policy="strict" ;;
            *) port_policy="geoip_only" ;;
        esac

        read -r -p "Включить логирование RST-пакетов? (y/n): " log_rst || log_rst="n"
        read -r -p "Включить автообновление через systemd timer? (y/n): " auto_update || auto_update="y"
        read -r -p "Включить TSPUBLOCK? (y/n): " enable_tspu || enable_tspu="y"
        read -r -p "Включить GOVIPS? (y/n): " enable_gov || enable_gov="y"
        read -r -p "Включить GeoIP сразу? (y/n): " enable_geo || enable_geo="n"

        set_setting FILTER_PORTS "$filter_ports"
        set_setting PORT_POLICY "$port_policy"
        set_setting LOG_RST "$(normalize_yesno "$log_rst")"
        set_setting AUTO_UPDATE "$(normalize_yesno "$auto_update")"
        set_setting ENABLE_TSPUBLOCK "$(normalize_yesno "$enable_tspu")"
        set_setting ENABLE_GOVIPS "$(normalize_yesno "$enable_gov")"
        "$CONFIG_TOOL" set-enabled "$( [[ $(normalize_yesno "$enable_geo") == y ]] && echo true || echo false )" >/dev/null
    fi

    enable_or_disable_timer

    info "Загрузка блок-листов..."
    if ! update_all; then
        warn "Часть списков не обновилась. Существующие данные сохранены."
        apply_all || true
    fi

    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
    success "Установка/обновление завершены"
}

remove_managed_firewall() {
    local l3 chain set_name
    for l3 in 4 6; do
        [[ "$l3" == "6" ]] && ! has_ip6tables && continue
        remove_rule_all "$l3" INPUT -j TSPUBLOCK
        remove_rule_all "$l3" INPUT -j GOVBLOCK
        remove_rule_all "$l3" INPUT -j TSPUBLOCK6
        remove_rule_all "$l3" INPUT -j GOVBLOCK6
        remove_rule_all "$l3" INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK
        for chain in "${MANAGED_CHAINS[@]}" TSPUBLOCK6 GOVBLOCK6; do
            local cmd
            case "$l3" in 6) cmd=ipt6 ;; *) cmd=ipt ;; esac
            "$cmd" -F "$chain" >/dev/null 2>&1 || true
            "$cmd" -X "$chain" >/dev/null 2>&1 || true
        done
    done

    for set_name in "${MANAGED_IPSETS[@]}" "${MANAGED_IPSETS_V6[@]}"; do
        ipset destroy "$set_name" >/dev/null 2>&1 || true
    done
}

uninstall_all() {
    check_root

    local confirm=""
    if [[ "${RKN_ASSUME_YES:-0}" == "1" ]]; then
        confirm="YES"
    else
        read -r -p "Для полного удаления введите YES: " confirm || confirm=""
    fi

    if [[ "$confirm" != "YES" ]]; then
        warn "Удаление отменено"
        return 0
    fi

    # Конфигурацию и логи не выбрасываем молча: без них восстановление стоит дорого.
    if [[ "${RKN_KEEP_BACKUP:-1}" != "0" ]]; then
        backup_config || true
    fi

    systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    systemctl disable --now rkn-watcher-boot.service >/dev/null 2>&1 || true
    rm -f "$BOOT_SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$FAILURE_SERVICE"
    systemctl daemon-reload >/dev/null 2>&1 || true

    remove_managed_firewall

    rm -f "$BIN_PATH" "$LOGROTATE_FILE"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    success "RKN Watcher удалён"
    if [[ "${RKN_KEEP_BACKUP:-1}" != "0" ]]; then
        info "Бэкап конфигурации оставлен в /var/root или $DATA_DIR (см. вывод выше)"
    fi
}

# ---------------------------------------------------------------------------
# Статус / диагностика
# ---------------------------------------------------------------------------
