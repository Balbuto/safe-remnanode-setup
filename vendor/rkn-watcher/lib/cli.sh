#!/usr/bin/env bash
# Разбор аргументов командной строки и main().

wants_flag() {
    local flag=$1
    shift
    local arg
    for arg in "$@"; do
        [[ "$arg" == "$flag" ]] && return 0
    done
    return 1
}

main() {
    local args=() arg cmd=""
    for arg in "$@"; do
        case "$arg" in
            --quiet|--dry-run|--json|--yes|--force) ;;
            *) if [[ -z "$cmd" ]]; then cmd="$arg"; fi ;;
        esac
        args+=("$arg")
    done
    cmd=${cmd:-menu}

    if wants_flag --version "$@"; then
        echo "$APP_NAME $VERSION"
        return 0
    fi

    case "$cmd" in
        -h|--help|help)
            print_usage
            return 0
            ;;
    esac

    if wants_flag --yes "$@"; then
        export RKN_ASSUME_YES=1
        export RKN_SKIP_DEP_INSTALL="${RKN_SKIP_DEP_INSTALL:-0}"
    fi

    # status/metrics/doctor не требуют root
    case "$cmd" in
        status|metrics|doctor)
            ;;
        *)
            check_root
            ;;
    esac

    local quiet="n"
    wants_flag --quiet "$@" && quiet="y"

    case "$cmd" in
        install)
            install_or_upgrade
            ;;
        update)
            if update_all; then
                [[ "$quiet" == "y" ]] || success "Update completed"
            else
                [[ "$quiet" == "y" ]] || warn "Update completed with errors"
                return 1
            fi
            ;;
        apply)
            local apply_opts=()
            wants_flag --dry-run "$@" && apply_opts+=("--dry-run")
            wants_flag --force "$@" && apply_opts+=("--force")
            # dry-run не должен менять системные снапшоты и ipset
            if ((${#apply_opts[@]})) && wants_flag --dry-run "$@"; then
                with_lock "$UPDATE_LOCK_FILE" _apply_all "${apply_opts[@]}"
            elif ((${#apply_opts[@]})); then
                apply_all "${apply_opts[@]}"
            else
                apply_all
            fi
            ;;
        status)
            if wants_flag --json "$@"; then
                show_status json
            else
                show_status noninteractive
            fi
            ;;
        doctor)
            cmd_doctor
            ;;
        metrics)
            show_metrics
            ;;
        allow-my-ip)
            local ip=""
            for arg in "$@"; do
                [[ "$arg" == allow-my-ip || "$arg" == --* ]] && continue
                ip="$arg"
                break
            done
            allow_my_ip "$ip"
            ;;
        block-ip)
            block_ip "$(printf '%s' "${*:2}" | awk '{print $1}')"
            ;;
        unblock-ip)
            unblock_ip "$(printf '%s' "${*:2}" | awk '{print $1}')"
            ;;
        snapshot)
            snapshot_state
            ;;
        snapshots|snapshot-list)
            snapshot_list
            ;;
        rollback)
            local stamp=""
            for arg in "$@"; do
                [[ "$arg" == rollback || "$arg" == --* ]] && continue
                stamp="$arg"
                break
            done
            rollback_state "$stamp"
            ;;
        uninstall)
            uninstall_all
            ;;
        menu)
            main_menu
            ;;
        *)
            error "Неизвестная команда: $cmd"
            print_usage
            return 1
            ;;
    esac
}
