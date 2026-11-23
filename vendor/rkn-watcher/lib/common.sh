#!/usr/bin/env bash
# Вывод, экран, логирование, проверки окружения и общие утилиты.
# Подключается первым (см. lib/config.sh): остальные модули используют info/warn/error.

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERR]${NC} $*" >&2; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
subtitle() { echo -e "${MAGENTA}───────────────────────────────────────────────────────────────${NC}"; }

# clear только в терминале: иначе ломает вывод через tee/journal
clear_screen() { [[ -t 1 ]] && clear || true; }

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$CACHE_DIR" "$COUNTRY_CACHE_DIR" \
        "$LIST_CACHE_DIR" "$STATE_DIR" "$SNAPSHOT_DIR" "$LOCK_DIR" "$LOG_DIR"
}

log_line() {
    local file=$1
    shift
    ensure_dirs
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$file"
}

log_action() { log_line "$ACTION_LOG" "$*"; }
log_update() { log_line "$UPDATE_LOG" "$*"; }

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Скрипт должен запускаться от root"
        exit 1
    fi
}

#!/usr/bin/env bash
# Общие утилиты: вывод, логи, нормализация и валидация значений, работа с settings.conf.
# Модуль подключается после определения путей и констант в rkn-watcher.sh.

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_commands() {
    local missing=0
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            error "Не найдена команда: $cmd"
            missing=1
        fi
    done
    return $missing
}

resolve_sources() {
    local dir
    SOURCE_CONFIG_TOOL=""
    SOURCE_GEOIP_APPLY=""
    for dir in "$SCRIPT_DIR" "$INSTALL_DIR"; do
        if [[ -z "$SOURCE_CONFIG_TOOL" && -f "$dir/config_tool.py" ]]; then
            SOURCE_CONFIG_TOOL="$dir/config_tool.py"
        fi
        if [[ -z "$SOURCE_GEOIP_APPLY" && -f "$dir/geoip_apply.py" ]]; then
            SOURCE_GEOIP_APPLY="$dir/geoip_apply.py"
        fi
    done
    return 0
}

normalize_yesno() {
    case "${1:-n}" in
        y|Y|yes|YES|Yes|true|TRUE|1|on|ON|да) echo "y" ;;
        *) echo "n" ;;
    esac
}

# Единая нормализация boolean для settings.conf: legacy-значения true/1/on
# не должны молча выключать блокировку.
normalize_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        y|yes|1|true|on|да) printf 'y\n' ;;
        n|no|0|false|off|нет|"") printf 'n\n' ;;
        *) return 1 ;;
    esac
}

get_bool_setting() {
    local key=$1
    local default=${2:-n}
    local raw value
    raw=$(get_setting "$key" "$default")
    if ! value=$(normalize_bool "$raw"); then
        error "Некорректное boolean-значение '$raw' для $key в $SETTINGS_FILE"
        return 1
    fi
    printf '%s\n' "$value"
}

validate_country_code() {
    [[ ${1:-} =~ ^[A-Za-z]{2}$ ]]
}

validate_ports_csv() {
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
for part in parts:
    if not part.isdigit():
        sys.exit(1)
    port = int(part)
    if port < 1 or port > 65535:
        sys.exit(1)
sys.exit(0)
PY
}

validate_single_port() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if not value.isdigit():
    sys.exit(1)
port = int(value)
sys.exit(0 if 1 <= port <= 65535 else 1)
PY
}

normalize_ports_csv() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if not value or value == 'all':
    print('all')
    raise SystemExit(0)
ports = sorted({int(p.strip()) for p in value.split(',') if p.strip()})
print(','.join(str(p) for p in ports))
PY
}

# Allow/deny-списки принимают IPv4 и IPv6: семейство определяется автоматически,
# IPv6 уходит в отдельные inet6-наборы (см. geoip_apply.py).
validate_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
try:
    if '/' in value:
        ipaddress.ip_network(value, strict=False)
    else:
        ipaddress.ip_address(value)
except Exception:
    raise SystemExit(1)
PY
}

normalize_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
if '/' in value:
    print(ipaddress.ip_network(value, strict=False))
else:
    print(ipaddress.ip_address(value))
PY
}

get_setting() {
    local key=$1
    local default=${2:-}
    if [[ -f "$SETTINGS_FILE" ]]; then
        local line
        # при дублировании ключа действует последнее значение — как в shell-конфигах
        line=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); last=$0 } END { if (last != "") print last }' "$SETTINGS_FILE" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            line=${line#\"}
            line=${line%\"}
            line=${line#\'}
            line=${line%\'}
            printf '%s\n' "$line"
            return 0
        fi
    fi
    printf '%s\n' "$default"
}

set_setting() {
    local key=$1
    local value=$2
    ensure_dirs
    python3 - "$SETTINGS_FILE" "$SETTINGS_LOCK_FILE" "$key" "$value" <<'PY'
import fcntl, os, sys, tempfile
path, lock_path, key, value = sys.argv[1:5]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(lock_path, 'a', encoding='utf-8') as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    lines = []
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    out = []
    found = False
    for line in lines:
        if line.startswith(f'{key}=') or line.startswith(f'{key} ='):
            out.append(f'{key}="{value}"')
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f'{key}="{value}"')
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.settings.', text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write('\n'.join(out).rstrip() + '\n')
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
PY
    chmod 0600 "$SETTINGS_FILE" 2>/dev/null || true
}

is_installed() {
    [[ -f "$MAIN_SCRIPT" && -f "$CONFIG_TOOL" && -f "$GEOIP_APPLY_SCRIPT" ]]
}

write_default_settings_if_missing() {
    ensure_dirs
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        umask 077
        cat > "$SETTINGS_FILE" <<'EOF'
FILTER_PORTS="all"
PORT_POLICY="geoip_only"
LOG_RST="n"
AUTO_UPDATE="y"
ENABLE_TSPUBLOCK="y"
ENABLE_GOVIPS="y"
NETFILTER_BACKEND="auto"
SNAPSHOT_KEEP="10"
SNAPSHOT_MAX_AGE_DAYS="30"
EOF
        chmod 0600 "$SETTINGS_FILE"
    fi
}

write_default_json_if_missing() {
    ensure_dirs
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        cat > "$WHITELIST_FILE" <<'EOF'
{
    "enabled": false,
    "countries": [],
    "ips": [],
    "ports": []
}
EOF
        chmod 0644 "$WHITELIST_FILE"
    fi

    if [[ ! -f "$BLACKLIST_FILE" ]]; then
        cat > "$BLACKLIST_FILE" <<'EOF'
{
    "ips": [],
    "ports": []
}
EOF
        chmod 0644 "$BLACKLIST_FILE"
    fi
}

copy_helper_scripts() {
    ensure_dirs
    resolve_sources
    if [[ ! -f "$SOURCE_CONFIG_TOOL" ]]; then
        error "Не найден helper-файл config_tool.py (искал в $SCRIPT_DIR и $INSTALL_DIR)"
        error "Обновление кода: скачайте архив релиза и запустите ./installer.sh install из него"
        exit 1
    fi
    if [[ ! -f "$SOURCE_GEOIP_APPLY" ]]; then
        error "Не найден helper-файл geoip_apply.py (искал в $SCRIPT_DIR и $INSTALL_DIR)"
        exit 1
    fi
    if [[ "$SOURCE_CONFIG_TOOL" != "$CONFIG_TOOL" ]]; then
        install -m 0755 "$SOURCE_CONFIG_TOOL" "$CONFIG_TOOL"
    fi
    if [[ "$SOURCE_GEOIP_APPLY" != "$GEOIP_APPLY_SCRIPT" ]]; then
        install -m 0755 "$SOURCE_GEOIP_APPLY" "$GEOIP_APPLY_SCRIPT"
    fi
    # страховка: даже если файл пришёл «как есть» (git без exec-bit), он должен запускаться
    chmod 0755 "$CONFIG_TOOL" "$GEOIP_APPLY_SCRIPT"
    copy_lib_modules
}

# Модули lib/*.sh: при обновлении кода их нужно скопировать в /opt/rkn-watcher/lib,
# иначе установленная версия останется со старыми модулями (или без них).
copy_lib_modules() {
    local source_dir="$SCRIPT_DIR/lib"
    if [[ ! -d "$source_dir" ]]; then
        source_dir="$INSTALL_DIR/lib"
    fi
    if [[ ! -f "$source_dir/config.sh" ]]; then
        error "Не найден каталог модулей lib/ (искал в $SCRIPT_DIR/lib и $INSTALL_DIR/lib)"
        error "Скопируйте каталог lib/ рядом с rkn-watcher.sh и повторите install"
        exit 1
    fi
    install -d -m 0755 "$INSTALL_DIR/lib"
    local module
    for module in "$source_dir"/*.sh; do
        [[ -f "$module" ]] || continue
        if [[ "$module" != "$INSTALL_DIR/lib/$(basename "$module")" ]]; then
            install -m 0755 "$module" "$INSTALL_DIR/lib/"
        fi
    done
    chmod 0755 "$INSTALL_DIR/lib"/*.sh
    log_action "lib modules installed from $source_dir"
}

# Раньше функция только печатала конфиг и не сохраняла нормализованные
# значения. Теперь нормализация действительно пишется на диск.
normalize_existing_json_files() {
    local output
    if ! output=$("$CONFIG_TOOL" normalize 2>&1); then
        warn "Не удалось нормализовать конфигурацию GeoIP: $output"
        return 1
    fi
    chmod 0644 "$WHITELIST_FILE" "$BLACKLIST_FILE" 2>/dev/null || true
    [[ -n "$output" ]] && log_action "config normalized: $output"
    return 0
}

with_lock() {
    local lock_file=$1
    shift
    ensure_dirs
    (
        flock -w 60 9 || { echo "lock-timeout"; exit 99; }
        "$@"
    ) 9>"$lock_file"
}

# Внешний хук уведомления о сбое (RKN_ON_FAILURE_HOOK=/usr/local/bin/notify.sh).
notify_failure() {
    local what=$1
    if [[ -n "${RKN_ON_FAILURE_HOOK:-}" && -x "${RKN_ON_FAILURE_HOOK}" ]]; then
        "$RKN_ON_FAILURE_HOOK" "$what" || true
    fi
}

