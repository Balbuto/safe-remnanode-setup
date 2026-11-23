#!/usr/bin/env bash
# Development entry point. The standalone installer is generated from the same modules.
set -Eeuo pipefail

remna_load_source_tree() {
    local entry name
    local -a modules=()
    entry=$(readlink -f -- "${BASH_SOURCE[0]}") || return 1
    REMNA_SOURCE_ROOT=$(dirname -- "$entry") || return 1
    mapfile -t modules < "$REMNA_SOURCE_ROOT/lib/modules.list" || return 1
    for name in "${modules[@]}"; do
        [[ "$name" =~ ^[a-z]+$ ]] || return 1
        # shellcheck disable=SC1090 # Module order and paths come from this local source tree.
        source "$REMNA_SOURCE_ROOT/lib/$name.sh" || return 1
    done
}

remna_load_source_tree || { printf '%s\n' 'Не удалось загрузить модульные исходники Safe RemnaNode.' >&2; exit 1; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
