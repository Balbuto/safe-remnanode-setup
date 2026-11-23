#!/usr/bin/env bash
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
