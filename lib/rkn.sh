#!/usr/bin/env bash
# ==============================================================================
# Интеграция RKN Watcher: комплект поставляется с установщиком
# ==============================================================================
RKN_INSTALL_DIR="/opt/rkn-watcher"
RKN_CONFIG_DIR="/etc/rkn-watcher"
RKN_MAIN_SCRIPT="$RKN_INSTALL_DIR/rkn-watcher.sh"
RKN_BIN_PATH="/usr/local/bin/rkn-watcher"
RKN_BACKUP_ROOT="/var/backups"

# @rkn-bundle@

if [[ -n "$REMNA_SOURCE_ROOT" ]]; then
    RKN_VERSION=$(< "$REMNA_SOURCE_ROOT/vendor/rkn-watcher/VERSION") || return 1
    RKN_UPSTREAM_REVISION=$(< "$REMNA_SOURCE_ROOT/vendor/rkn-watcher/UPSTREAM_COMMIT") || return 1
fi

rkn_copy_vendor_bundle() (
    set -o pipefail
    umask 077
    local vendor="$1" destination="$2" stage file
    local -a files=(LICENSE UPSTREAM_COMMIT VERSION config_tool.py geoip_apply.py installer.sh
        lib/{cli,common,config,firewall,lists,services,snapshots,ui}.sh rkn-watcher.sh)
    [[ ! -L "$vendor/lib" ]] || return 1
    stage=$(mktemp -d) || return 1
    trap 'rm -rf -- "$stage"' EXIT
    mkdir "$stage/lib" || return 1
    for file in "${files[@]}" SHA256SUMS; do
        [[ -f "$vendor/$file" && ! -L "$vendor/$file" ]] || return 1
        cp -p -- "$vendor/$file" "$stage/$file" || return 1
    done
    # Recompute the exact manifest (including membership/order) on the staged copy.
    (cd "$stage" && sha256sum -- "${files[@]}" | cmp -s SHA256SUMS -) || return 1
    cp -a -- "$stage/." "$destination/"
)

rkn_unpack_bundle() (
    set -o pipefail
    umask 077
    local destination="$1" archive
    if [[ -n "$REMNA_SOURCE_ROOT" ]]; then
        rkn_copy_vendor_bundle "$REMNA_SOURCE_ROOT/vendor/rkn-watcher" "$destination"
        return $?
    fi
    archive=$(mktemp) || return 1
    trap 'rm -f -- "$archive"' EXIT
    rkn_bundle_payload | base64 --decode > "$archive" || return 1
    printf '%s  %s\n' "$RKN_BUNDLE_SHA256" "$archive" | sha256sum --check --status || return 1
    tar --no-same-owner -xzf "$archive" -C "$destination"
)

rkn_install_or_upgrade() (
    check_root || return 1
    local original_umask
    original_umask=$(umask)
    umask 077
    local stage current_launcher backup f
    local -a preserve=()
    if [[ -e "$RKN_BIN_PATH" || -L "$RKN_BIN_PATH" ]]; then
        current_launcher=$(readlink -f -- "$RKN_BIN_PATH") || return 1
        if [[ "$current_launcher" != "$RKN_MAIN_SCRIPT" && "$current_launcher" != /usr/local/bin/safe-remnanode-setup ]]; then
            printf 'Чужая команда %s оставлена без изменений. Освободите путь перед установкой.\n' "$RKN_BIN_PATH" >&2
            return 1
        fi
    fi
    stage=$(mktemp -d) || return 1
    trap 'rm -rf -- "$stage"' EXIT
    if ! rkn_unpack_bundle "$stage"; then
        printf '%s\n' 'Комплект RKN Watcher не прошёл проверку. Установка остановлена.' >&2
        return 1
    fi
    if [[ -f "$RKN_MAIN_SCRIPT" || -d "$RKN_CONFIG_DIR" ]]; then
        for f in "$RKN_INSTALL_DIR" "$RKN_CONFIG_DIR" "$RKN_BIN_PATH" /etc/logrotate.d/rkn-watcher \
            /etc/systemd/system/rkn-watcher-{boot.service,update.service,update.timer,failure@.service}; do
            if [[ -e "$f" || -L "$f" ]]; then preserve+=("${f#/}"); fi
        done
        mkdir -p -- "$RKN_BACKUP_ROOT" || return 1
        backup=$(mktemp -d "$RKN_BACKUP_ROOT/safe-rkn-watcher.XXXXXXXX") || return 1
        if ! tar -czf "$backup/files.tgz" -C / -- "${preserve[@]}"; then
            printf '%s\n' 'Не удалось создать резервную копию. Обновление остановлено.' >&2
            return 1
        fi
        printf 'Резервная копия RKN Watcher: %s/files.tgz\n' "$backup"
        export RKN_ASSUME_YES=1
    fi
    printf 'Устанавливаю RKN Watcher %s из встроенного коммита %.12s\n' "$RKN_VERSION" "$RKN_UPSTREAM_REVISION"
    umask "$original_umask"
    "$stage/installer.sh" install
)

rkn_run_installed() {
    if [[ ! -x "$RKN_MAIN_SCRIPT" ]] || [[ "$(readlink -f -- "$RKN_MAIN_SCRIPT")" == "$(readlink -f -- "$0")" ]]; then
        printf '%s\n' 'RKN Watcher не установлен. Для установки: sudo safe-remnanode-setup protect' >&2
        return 1
    fi
    "$RKN_MAIN_SCRIPT" "$@"
}
