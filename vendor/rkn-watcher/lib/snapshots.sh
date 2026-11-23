#!/usr/bin/env bash
# Снапшоты правил и ipset, откат, ротация по возрасту и количеству.

snapshot_state() {
    ensure_dirs
    local stamp dir
    stamp=$(date '+%Y%m%d-%H%M%S')
    dir="$SNAPSHOT_DIR/$stamp"
    mkdir -p "$dir"
    "$(_netfilter_tool iptables -save)" > "$dir/rules.v4" 2>/dev/null || true
    if has_ip6tables; then
        "$(_netfilter_tool ip6tables -save)" > "$dir/rules.v6" 2>/dev/null || true
    fi
    ipset save > "$dir/sets" 2>/dev/null || true
    printf '%s\n' "$stamp" > "$SNAPSHOT_DIR/LAST"
    _prune_snapshots
    log_action "snapshot created: $stamp"
    printf '%s\n' "$stamp"
}

# Сколько последних снапшотов хранить и сколько дней держать остальные.
snapshot_limits() {
    local keep days
    keep=$(get_setting SNAPSHOT_KEEP "$DEFAULT_KEEP_SNAPSHOTS")
    days=$(get_setting SNAPSHOT_MAX_AGE_DAYS "$SNAPSHOT_MAX_AGE_DAYS")
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=$DEFAULT_KEEP_SNAPSHOTS
    [[ "$days" =~ ^[0-9]+$ ]] || days=$SNAPSHOT_MAX_AGE_DAYS
    printf '%s %s\n' "$keep" "$days"
}

_prune_snapshots() {
    local keep days
    read -r keep days <<< "$(snapshot_limits)"

    # 1) моложе N дней — не трогаем ничего, даже если их больше keep
    # 2) старше N дней удаляем
    # 3) но не меньше keep последних оставляем всегда
    local dirs=() d
    while IFS= read -r d; do
        [[ -n "$d" ]] && dirs+=("$d")
    done < <(ls -1dt "$SNAPSHOT_DIR"/*/ 2>/dev/null)

    (( ${#dirs[@]} == 0 )) && return 0

    local index=0 removed=0
    for d in "${dirs[@]}"; do
        index=$((index + 1))
        if (( index <= keep )); then
            continue
        fi
        # каталог старше допустимого возраста — удаляем
        if [[ -n "$(find "$d" -maxdepth 0 -mtime "+$days" 2>/dev/null)" ]]; then
            rm -rf "$d"
            removed=$((removed + 1))
        fi
    done
    (( removed > 0 )) && log_action "pruned $removed snapshots (keep=$keep, max_age=${days}d)"
    return 0
}

snapshot_list() {
    local dirs=() d
    while IFS= read -r d; do
        [[ -n "$d" ]] && dirs+=("$d")
    done < <(ls -1dt "$SNAPSHOT_DIR"/*/ 2>/dev/null)
    if (( ${#dirs[@]} == 0 )); then
        info "Снапшотов нет"
        return 0
    fi
    local d size
    for d in "${dirs[@]}"; do
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        printf '%s  %s\n' "$(basename "$d")" "${size:-?}"
    done
}

rollback_state() {
    local target=${1:-}
    local dir
    if [[ -z "$target" ]]; then
        [[ -f "$SNAPSHOT_DIR/LAST" ]] || { error "Снапшотов нет"; return 1; }
        target=$(cat "$SNAPSHOT_DIR/LAST")
    fi
    dir="$SNAPSHOT_DIR/$target"
    [[ -d "$dir" ]] || { error "Снапшот $target не найден"; return 1; }
    if [[ -f "$dir/rules.v4" ]]; then
        ipt_restore < "$dir/rules.v4" || { error "iptables-restore не удался"; return 1; }
    fi
    if [[ -f "$dir/rules.v6" ]] && has_ip6tables; then
        ipt6_restore < "$dir/rules.v6" || warn "ip6tables-restore не удался"
    fi
    if [[ -f "$dir/sets" ]]; then
        ipset restore -exist < "$dir/sets" || warn "ipset restore не удался"
    fi
    log_action "rollback to snapshot $target"
    success "Откат к снапшоту $target выполнен"
}
