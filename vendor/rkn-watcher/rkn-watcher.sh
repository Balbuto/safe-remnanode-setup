#!/usr/bin/env bash
# RKN Watcher — точка входа. Логика — в lib/*.sh (см. lib/config.sh).
set -euo pipefail
# fail-fast внутри $(...): иначе сбой ipset в command substitution маскируется
shopt -s inherit_errexit 2>/dev/null || true

RKN_ROOT="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ ! -f "$RKN_ROOT/lib/config.sh" && -f /opt/rkn-watcher/lib/config.sh ]]; then
    RKN_ROOT="/opt/rkn-watcher"
fi
# shellcheck disable=SC1091
source "$RKN_ROOT/lib/config.sh"
rkn_load_modules
resolve_sources

main "$@"
