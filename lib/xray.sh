#!/usr/bin/env bash
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
