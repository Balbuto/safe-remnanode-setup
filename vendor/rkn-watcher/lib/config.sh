#!/usr/bin/env bash
# Пути, константы и загрузка остальных модулей.
# Подключается первым: остальные модули рассчитывают на эти переменные.
# shellcheck disable=SC2034  # значения используются модулями, подключаемыми динамически

VERSION="3.2.1"
APP_NAME="RKN Watcher"


INSTALL_DIR="/opt/rkn-watcher"
CONFIG_DIR="/etc/rkn-watcher"
DATA_DIR="/var/lib/rkn-watcher"
CACHE_DIR="$DATA_DIR/cache"
COUNTRY_CACHE_DIR="$CACHE_DIR/countries"
LIST_CACHE_DIR="$CACHE_DIR/lists"
STATE_DIR="$DATA_DIR/state"
SNAPSHOT_DIR="$DATA_DIR/snapshots"
LOCK_DIR="$DATA_DIR/locks"
LOG_DIR="/var/log/rkn-watcher"

MAIN_SCRIPT="$INSTALL_DIR/rkn-watcher.sh"
CONFIG_TOOL="$INSTALL_DIR/config_tool.py"
GEOIP_APPLY_SCRIPT="$INSTALL_DIR/geoip_apply.py"
BIN_PATH="/usr/local/bin/rkn-watcher"
SCRIPT_DIR="$RKN_ROOT"
SETTINGS_FILE="$CONFIG_DIR/settings.conf"
WHITELIST_FILE="$CONFIG_DIR/whitelist.json"
BLACKLIST_FILE="$CONFIG_DIR/blacklist.json"
IPSET_STATE_FILE="$STATE_DIR/ipset.conf"
UPDATE_LOCK_FILE="$LOCK_DIR/update.lock"
SETTINGS_LOCK_FILE="$LOCK_DIR/settings.lock"
UPDATE_LOG="$LOG_DIR/update.log"
ACTION_LOG="$LOG_DIR/actions.log"
GEOIP_LOG="$LOG_DIR/geoip.log"

BOOT_SERVICE="/etc/systemd/system/rkn-watcher-boot.service"
UPDATE_SERVICE="/etc/systemd/system/rkn-watcher-update.service"
UPDATE_TIMER="/etc/systemd/system/rkn-watcher-update.timer"
FAILURE_SERVICE="/etc/systemd/system/rkn-watcher-failure@.service"
LOGROTATE_FILE="/etc/logrotate.d/rkn-watcher"

TSPU_URL="https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt"
GOV_URL="https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset"

IPT_WAIT="5"
MIN_SHRINK_PERCENT=50
MAX_GROW_FACTOR=5
DEFAULT_KEEP_SNAPSHOTS=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

MANAGED_IPSETS=(TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW)
MANAGED_IPSETS_V6=(TSPUIPS6 GOVIPS6 GEOIP_ALLOW_IPS6 GEOIP_DENY_IPS6 GEOIP_COUNTRIES_ALLOW6)
MANAGED_CHAINS=(TSPUBLOCK GOVBLOCK GEOIP_DROP RKN_GEOIP_HOOK RKN_DENY RKN_PROTECT)
MANAGED_CHAINS_V6=(TSPUBLOCK6 GOVBLOCK6 RKN_GEOIP_HOOK6)
SNAPSHOT_MAX_AGE_DAYS=30


# --- поиск и загрузка модулей -------------------------------------------------
LIB_DIR="$RKN_ROOT/lib"
[[ -d "$LIB_DIR" ]] || LIB_DIR="$INSTALL_DIR/lib"

# Порядок важен: common определяет вывод и логи, которыми пользуются остальные.
RKN_MODULES=(common firewall snapshots lists services ui cli)

rkn_load_modules() {
    local module
    for module in "${RKN_MODULES[@]}"; do
        if [[ ! -f "$LIB_DIR/$module.sh" ]]; then
            printf '[ERR] Отсутствует модуль %s\n' "$LIB_DIR/$module.sh" >&2
            exit 1
        fi
        # shellcheck disable=SC1090
        source "$LIB_DIR/$module.sh"
    done
}
