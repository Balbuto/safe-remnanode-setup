#!/usr/bin/env bash
# РЕГИСТРАЦИЯ ГЛОБАЛЬНЫХ КОМАНД
# ==============================================================================
remna_cli_payload() {
    if [[ -n "$REMNA_SOURCE_ROOT" ]]; then
        if ! python3 "$REMNA_SOURCE_ROOT/tools/build_standalone.py" --check >/dev/null; then
            printf '%s\n' 'Сначала соберите однофайловый установщик: python3 tools/build_standalone.py' >&2
            return 1
        fi
        printf '%s\n' "$REMNA_SOURCE_ROOT/safe-remnanode-setup.sh"
    else
        printf '%s\n' "${SCRIPT_PATH:-$(readlink -f "$0" 2>/dev/null || echo "$0")}"
    fi
}

register_global_commands() {
    local script_path
    script_path=$(remna_cli_payload) || return 1

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
            6) rkn_run_installed menu ;;
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
  protect-version   версия встроенного комплекта RKN Watcher
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
    case "$cmd" in
        -h|--help|help) print_usage; return 0 ;;
        protect-version) printf 'RKN Watcher %s (bundled; %s)\n' "$RKN_VERSION" "$RKN_UPSTREAM_REVISION"; return 0 ;;
    esac
    check_root >&2 || return 1
    case "$cmd:$basename_cmd" in
        protect-status:*|status:rkn-watcher*) rkn_run_installed status "${@:2}"; return $? ;;
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
    if [[ "$basename_cmd" == rkn-watcher* ]]; then
        case "$cmd" in
            install) rkn_install_or_upgrade; return $? ;;
            update|apply|status|uninstall|menu|doctor|metrics|snapshots) rkn_run_installed "$cmd" "${@:2}"; return $? ;;
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
        protect-menu) rkn_run_installed menu ;;
        protect-update) rkn_run_installed update "${@:2}" ;;
        protect-apply) rkn_run_installed apply "${@:2}" ;;
        protect-status) rkn_run_installed status "${@:2}" ;;
        protect-uninstall) rkn_run_installed uninstall "${@:2}" ;;
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
