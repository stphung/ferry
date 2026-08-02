# bash completion for ferry

_ferry() {
    local cur prev cmds
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cmds="setup markers doctor check sync status resync attic schedule app activity config-set uninstall"

    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "$cmds --help --version" -- "$cur")
        return
    fi

    case ${COMP_WORDS[1]} in
        sync)     mapfile -t COMPREPLY < <(compgen -W "-n --dry-run -v --verbose" -- "$cur") ;;
        resync)
            if [ "$prev" = --mode ]; then
                mapfile -t COMPREPLY < <(compgen -W "path1 path2 newer older larger smaller" -- "$cur")
            else
                mapfile -t COMPREPLY < <(compgen -W "-n --dry-run --yes --mode" -- "$cur")
            fi
            ;;
        markers)  mapfile -t COMPREPLY < <(compgen -W "--yes" -- "$cur") ;;
        attic)    mapfile -t COMPREPLY < <(compgen -W "list restore prune" -- "$cur") ;;
        schedule) mapfile -t COMPREPLY < <(compgen -W "install remove status" -- "$cur") ;;
        app)      mapfile -t COMPREPLY < <(compgen -W "install remove status" -- "$cur") ;;
        status)   mapfile -t COMPREPLY < <(compgen -W "--porcelain" -- "$cur") ;;
        activity) mapfile -t COMPREPLY < <(compgen -W "-n --porcelain" -- "$cur") ;;
        doctor)   mapfile -t COMPREPLY < <(compgen -W "--porcelain" -- "$cur") ;;
        config-set) mapfile -t COMPREPLY < <(compgen -W "PATH1 PATH2 ATTIC MAX_DELETE TRANSFERS CHECKERS TPSLIMIT RETRIES LOW_LEVEL_RETRIES INTERVAL LOG_KEEP ATTIC_KEEP_DAYS NOTIFY" -- "$cur") ;;
        uninstall) mapfile -t COMPREPLY < <(compgen -W "--purge --yes" -- "$cur") ;;
    esac
}

complete -F _ferry ferry
