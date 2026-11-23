#!/usr/bin/env bash
# ==============================================================================
# МОДУЛЬ B: УСТАНОВКА И УПРАВЛЕНИЕ НОДОЙ REMNAWAVE (из setup_node.sh v1.7.2)
# ==============================================================================

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
