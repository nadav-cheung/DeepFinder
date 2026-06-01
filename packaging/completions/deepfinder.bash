# Bash completion for deepfinder
#
# Installation:
#   source <(deepfinder --completion bash)
#   or copy to: /usr/local/etc/bash_completion.d/deepfinder.bash

_deepfinder() {
    local cur prev words cword subcmd subsubcmd
    _init_completion || return

    # Top-level commands and options
    local commands="daemon config install uninstall"
    local options="--json --0 --sort --limit --offset --reverse --verbose --serve --port --help --version"

    # Determine the subcommand context
    local i subcmd_idx=0
    for ((i=1; i < cword; i++)); do
        case "${words[i]}" in
            daemon|config|install|uninstall)
                subcmd="${words[i]}"
                subcmd_idx=$i
                break
                ;;
        esac
    done

    # If we have a subcommand, handle its completions
    if [[ -n "$subcmd" ]]; then
        case "$subcmd" in
            daemon)
                # Daemon actions
                local daemon_actions="start stop restart status"
                # Check if we need a daemon action
                local j action_provided=false
                for ((j=subcmd_idx+1; j < cword; j++)); do
                    case "${words[j]}" in
                        start|stop|restart|status)
                            subsubcmd="${words[j]}"
                            action_provided=true
                            break
                            ;;
                    esac
                done

                if [[ "$action_provided" == "false" ]]; then
                    COMPREPLY=($(compgen -W "$daemon_actions" -- "$cur"))
                    return
                fi
                # No further completions after daemon action
                COMPREPLY=()
                return
                ;;
            config)
                local config_actions="get set list reset"
                local config_keys="excludedPaths excludedVolumes indexBatchSize maxResults configVersion"

                local j action_provided=false
                for ((j=subcmd_idx+1; j < cword; j++)); do
                    case "${words[j]}" in
                        get|set|list|reset)
                            subsubcmd="${words[j]}"
                            action_provided=true
                            break
                            ;;
                    esac
                done

                if [[ "$action_provided" == "false" ]]; then
                    COMPREPLY=($(compgen -W "$config_actions" -- "$cur"))
                    return
                fi

                case "$subsubcmd" in
                    get|set)
                        # Count how many args we have after the action
                        local args_after=0
                        local k
                        for ((k=j+1; k < cword; k++)); do
                            # Skip options
                            if [[ "${words[k]}" != -* ]]; then
                                ((args_after++))
                            fi
                        done
                        if [[ "$args_after" -eq 0 ]]; then
                            # Complete config key
                            COMPREPLY=($(compgen -W "$config_keys" -- "$cur"))
                            return
                        fi
                        ;;
                    list|reset)
                        # No further arguments
                        COMPREPLY=()
                        return
                        ;;
                esac
                ;;
            install|uninstall)
                # No further arguments
                COMPREPLY=()
                return
                ;;
        esac
    fi

    # No subcommand yet: complete top-level commands and options
    COMPREPLY=($(compgen -W "$commands $options" -- "$cur"))
}

complete -F _deepfinder deepfinder
