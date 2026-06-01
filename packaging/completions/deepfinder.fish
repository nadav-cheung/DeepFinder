# Fish completion for deepfinder
#
# Installation:
#   cp deepfinder.fish ~/.config/fish/completions/
#   or from source: deepfinder --completion fish | source

# Top-level commands
set -l commands daemon config install uninstall

# Top-level options
set -l options --json --0 --sort --limit --offset --reverse --verbose --serve --port --help --version

# Daemon actions
set -l daemon_actions start stop restart status

# Config actions
set -l config_actions get set list reset

# Config keys
set -l config_keys excludedPaths excludedVolumes indexBatchSize maxResults configVersion

# Disable file completion by default
complete -c deepfinder -f

# Top-level query: complete files (useful when typing a search path/filename)
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '(__fish_complete_path)' \
    -d "File search query"

# Top-level commands
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a "$commands"

# Top-level options
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--json' -d "Output results as JSON"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--0' -d "Output results separated by null bytes"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--sort' -d "Sort by: name, size, date"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--limit' -d "Maximum number of results"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--offset' -d "Number of results to skip"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--reverse' -d "Reverse sort order"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--verbose' -d "Show match type and relevance score"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--serve' -d "Start HTTP search service"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--port' -d "Port for --serve mode (default: 7654)"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--help' -d "Show help text and exit"
complete -c deepfinder -n "not __fish_seen_subcommand_from $commands" \
    -a '--version' -d "Show version and exit"

# --sort values
complete -c deepfinder -n "__fish_seen_argument -s sort -l sort" \
    -a "name size date"

# Daemon subcommand completions
complete -c deepfinder -n "__fish_seen_subcommand_from daemon; and not __fish_seen_subcommand_from $daemon_actions" \
    -a "$daemon_actions"

# Config subcommand completions
complete -c deepfinder -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_actions" \
    -a "$config_actions"

# Config keys (after 'get' or 'set')
complete -c deepfinder -n "__fish_seen_subcommand_from get set; and __fish_seen_subcommand_from config" \
    -a "$config_keys" -d "Configuration key"

# After install/uninstall/list/reset, no further completions
complete -c deepfinder -n "__fish_seen_subcommand_from install uninstall" -f
complete -c deepfinder -n "__fish_seen_subcommand_from list reset; and __fish_seen_subcommand_from config" -f
