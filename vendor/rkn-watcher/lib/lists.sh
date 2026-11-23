#!/usr/bin/env bash
# Блок-листы: загрузка, санитизация, атомарная замена ipset, sanity-гейт.

sanitize_tspu_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" "${output}.v6" <<'PY'
import ipaddress, sys
src, dst4, dst6 = sys.argv[1:4]
v4, v6 = set(), set()
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue
        (v4 if net.version == 4 else v6).add(str(net))
for path, entries in ((dst4, v4), (dst6, v6)):
    with open(path, 'w', encoding='utf-8') as fh:
        for item in sorted(entries):
            fh.write(item + '\n')
PY
}

sanitize_gov_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" "${output}.v6" <<'PY'
import ipaddress, re, sys
src, dst4, dst6 = sys.argv[1:4]
pattern = re.compile(r'^add\s+blacklist-v4\s+([0-9./]+)')
v4, v6 = set(), set()
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        match = pattern.match(line)
        if not match:
            continue
        try:
            net = ipaddress.ip_network(match.group(1), strict=False)
        except ValueError:
            continue
        (v4 if net.version == 4 else v6).add(str(net))
with open(dst4, 'w', encoding='utf-8') as fh:
    for item in sorted(v4):
        fh.write(item + '\n')
with open(dst6, 'w', encoding='utf-8') as fh:
    for item in sorted(v6):
        fh.write(item + '\n')
PY
}

# Атомарная замена набора: temp set + swap. Коды возврата проверяются явно.
replace_ipset_from_file() {
    local target=$1
    local type=$2
    local maxelem=$3
    local file=$4
    local family=${5:-inet}
    local temp="${target}_TMP"
    local restore_file count
    restore_file=$(mktemp)
    count=0

    {
        printf 'create %s %s family %s maxelem %s -exist\n' "$temp" "$type" "$family" "$maxelem"
        printf 'flush %s\n' "$temp"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf 'add %s %s\n' "$temp" "$line"
            count=$((count + 1))
        done < "$file"
    } > "$restore_file"

    if (( count == 0 )); then
        rm -f "$restore_file"
        log_update "ERROR: empty list for $target, old set preserved"
        return 1
    fi

    if ! ipset restore -exist < "$restore_file"; then
        rm -f "$restore_file"
        ipset destroy "$temp" >/dev/null 2>&1 || true
        log_update "ERROR: ipset restore failed for $target"
        return 1
    fi
    rm -f "$restore_file"

    if ! ensure_ipset_exists "$target" "$type" "$maxelem" "$family"; then
        ipset destroy "$temp" >/dev/null 2>&1 || true
        log_update "ERROR: cannot create $target"
        return 1
    fi
    if ! ipset swap "$temp" "$target"; then
        ipset destroy "$temp" >/dev/null 2>&1 || true
        log_update "ERROR: ipset swap failed for $target"
        return 1
    fi
    ipset destroy "$temp" >/dev/null 2>&1 || true
    printf '%s\n' "$count"
}

fetch_url() {
    local url=$1 out=$2
    local hint=""
    # Условный GET: если источник не изменился, curl вернёт 304 и файл не тронется.
    if [[ -f "$out" ]]; then
        hint=$(mktemp)
        curl -fsS -w '%{http_code}' -z "$out" --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
            -o "$out.new" "$url" > "$hint" 2>/dev/null || {
            local code
            code=$(cat "$hint" 2>/dev/null || echo 000)
            rm -f "$hint" "$out.new"
            if [[ "$code" == "304" ]]; then
                return 0
            fi
            printf 'HTTP %s' "$code" >> "${out}.err"
            return 1
        }
        rm -f "$hint"
        if [[ -s "$out.new" ]]; then
            mv "$out.new" "$out"
        else
            rm -f "$out.new"
        fi
        return 0
    fi
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "$url" -o "$out"
}

# Защита от «схлопывания» источника: слишком маленький или подозрительно
# выросший список не применяем, старое содержимое остаётся в работе.
list_is_sane() {
    local name=$1 new_count=$2 old_file=$3
    local old_count=0
    if [[ "${RKN_ALLOW_LIST_SHRINK:-0}" == "1" ]]; then
        log_update "sanity check bypassed for $name (RKN_ALLOW_LIST_SHRINK=1)"
        printf 'ok\n'
        return 0
    fi
    [[ -f "$old_file" ]] && old_count=$(parse_number "$(cat "$old_file" 2>/dev/null || echo 0)")
    if (( old_count == 0 )); then
        printf 'ok\n'
        return 0
    fi
    local min=$(( old_count * MIN_SHRINK_PERCENT / 100 ))
    local max=$(( old_count * MAX_GROW_FACTOR ))
    if (( new_count < min )); then
        printf 'small\n'
        return 1
    fi
    if (( new_count > max )); then
        printf 'large\n'
        return 1
    fi
    printf 'ok\n'
    return 0
}

update_tspublock_list() {
    local raw v4 count6 sanity
    raw="$LIST_CACHE_DIR/tspu.raw"
    v4=$(mktemp)
    ensure_dirs
    : > "$raw"

    if ! fetch_url "$TSPU_URL" "$raw"; then
        local err=""
        [[ -f "${raw}.err" ]] && err=$(cat "${raw}.err") && rm -f "${raw}.err"
        rm -f "$v4"
        log_update "ERROR downloading TSPUBLOCK: ${err:-curl failure}"
        error "Не удалось скачать TSPUBLOCK ${err:+($err)}"
        return 1
    fi
    if [[ ! -s "$raw" ]]; then
        rm -f "$v4"
        log_update "ERROR: downloaded TSPUBLOCK is empty"
        return 1
    fi

    sanitize_tspu_file "$raw" "$v4"
    if ! count=$(replace_ipset_from_file TSPUIPS hash:net 2000000 "$v4"); then
        rm -f "$v4" "${v4}.v6"
        return 1
    fi

    sanity=$(list_is_sane TSPUIPS "$count" "$STATE_DIR/tspu_count.txt") || {
        log_update "ERROR: TSPUBLOCK sanity check failed ($sanity): new=$count old=$(cat "$STATE_DIR/tspu_count.txt" 2>/dev/null || echo 0)"
        error "TSPUBLOCK: список изменился подозрительно (новых записей $count). Старый набор сохранён."
        error "Если изменение ожидаемое, повторите с RKN_ALLOW_LIST_SHRINK=1"
        rm -f "$v4" "${v4}.v6"
        return 1
    }

    count6=0
    if [[ -s "${v4}.v6" ]] && has_ip6tables; then
        count6=$(replace_ipset_from_file TSPUIPS6 hash:net 2000000 "${v4}.v6" inet6 || echo 0)
    fi
    rm -f "$v4" "${v4}.v6"

    printf '%s\n' "$count" > "$STATE_DIR/tspu_count.txt"
    log_update "TSPUBLOCK updated: $count entries (IPv6: $count6)"
    printf '%s\n' "$count"
    return 0
}

update_govips_list() {
    local raw v4 count count6 sanity
    raw="$LIST_CACHE_DIR/gov.raw"
    v4=$(mktemp)
    ensure_dirs
    : > "$raw"

    if ! fetch_url "$GOV_URL" "$raw"; then
        local err=""
        [[ -f "${raw}.err" ]] && err=$(cat "${raw}.err") && rm -f "${raw}.err"
        rm -f "$v4"
        log_update "ERROR downloading GOVIPS: ${err:-curl failure}"
        error "Не удалось скачать GOVIPS ${err:+($err)}"
        return 1
    fi
    if [[ ! -s "$raw" ]]; then
        rm -f "$v4"
        log_update "ERROR: downloaded GOVIPS is empty"
        return 1
    fi

    sanitize_gov_file "$raw" "$v4"
    if ! count=$(replace_ipset_from_file GOVIPS hash:net 2000000 "$v4"); then
        rm -f "$v4" "${v4}.v6"
        return 1
    fi

    sanity=$(list_is_sane GOVIPS "$count" "$STATE_DIR/gov_count.txt") || {
        log_update "ERROR: GOVIPS sanity check failed ($sanity): new=$count old=$(cat "$STATE_DIR/gov_count.txt" 2>/dev/null || echo 0)"
        error "GOVIPS: список изменился подозрительно (новых записей $count). Старый набор сохранён."
        rm -f "$v4" "${v4}.v6"
        return 1
    }

    count6=0
    if [[ -s "${v4}.v6" ]] && has_ip6tables; then
        count6=$(replace_ipset_from_file GOVIPS6 hash:net 2000000 "${v4}.v6" inet6 || echo 0)
    fi
    rm -f "$v4" "${v4}.v6"

    printf '%s\n' "$count" > "$STATE_DIR/gov_count.txt"
    log_update "GOVIPS updated: $count entries (IPv6: $count6)"
    printf '%s\n' "$count"
    return 0
}

_update_lists_parallel() {
    ensure_dirs
    ensure_ipset_exists TSPUIPS hash:net 2000000 inet
    ensure_ipset_exists GOVIPS hash:net 2000000 inet

    local tspu_out gov_out rc=0 tspu_count gov_count
    tspu_out=$(mktemp)
    gov_out=$(mktemp)
    local tmpfiles=("$tspu_out" "$gov_out")
    trap 'rm -f "${tmpfiles[@]}"' RETURN

    ( update_tspublock_list > "$tspu_out" ) &
    local pid1=$!
    ( update_govips_list > "$gov_out" ) &
    local pid2=$!

    if ! wait "$pid1"; then
        warn "Ошибка обновления TSPUBLOCK (подробности в $UPDATE_LOG)"
        rc=1
    fi
    if ! wait "$pid2"; then
        warn "Ошибка обновления GOVIPS (подробности в $UPDATE_LOG)"
        rc=1
    fi

    tspu_count=$(tail -n1 "$tspu_out" 2>/dev/null || echo 0)
    gov_count=$(tail -n1 "$gov_out" 2>/dev/null || echo 0)

    if (( rc == 0 )); then
        success "TSPUBLOCK: $tspu_count, GOVIPS: $gov_count"
    fi
    return $rc
}


_apply_all() {
    local opts=("$@")
    restore_ipset_state
    setup_tspublock_rules || return 1
    setup_govips_rules || return 1
    if ((${#opts[@]})); then
        "$GEOIP_APPLY_SCRIPT" apply "${opts[@]}" || return 1
    else
        "$GEOIP_APPLY_SCRIPT" apply || return 1
    fi
    save_ipset_state
    log_action "Full apply completed"
}

apply_all() {
    snapshot_state >/dev/null 2>&1 || true
    with_lock "$UPDATE_LOCK_FILE" _apply_all "$@"
}

_update_all() {
    local rc=0
    log_update "=== update started ==="
    if ! _update_lists_parallel; then
        rc=1
    fi
    setup_tspublock_rules || rc=1
    setup_govips_rules || rc=1
    if ! "$GEOIP_APPLY_SCRIPT" apply; then
        rc=1
    fi
    save_ipset_state
    if (( rc == 0 )); then
        log_update "=== update completed ==="
    else
        log_update "=== update completed with errors ==="
        notify_failure "update"
    fi
    return $rc
}

update_all() {
    snapshot_state >/dev/null 2>&1 || true
    with_lock "$UPDATE_LOCK_FILE" _update_all
}
