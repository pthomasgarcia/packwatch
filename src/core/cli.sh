#!/usr/bin/env bash
# ==============================================================================
# MODULE: cli.sh
# ==============================================================================
# Responsibilities:
#   - CLI argument parsing and usage/help output
#
# Usage:
#   Source this file in your main script:
#     source "$SCRIPT_DIR/cli.sh"
#
#   Then use:
#     cli::parse_arguments "$@"
#     cli::show_usage
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Available App Keys for Display
# ------------------------------------------------------------------------------

# Get available app keys from config files for display.
# Usage: cli::get_available_app_keys_for_display
cli::get_available_app_keys_for_display() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        return
    fi

    local config_files=()
    while IFS= read -r -d '' file; do
        config_files+=("$file")
    done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.json" -not -name ".*" -not -name "_*" -type f -print0)

    if [[ ${#config_files[@]} -eq 0 ]]; then
        return
    fi

    for file_path in "${config_files[@]}"; do
        # Use jq to safely extract app_key and name. Fallback to filename if needed.
        local app_info
        app_info=$(jq -r '{key: .app_key, name: .application.name} | "\(.key)---_---\(.name)"' "$file_path" 2>/dev/null)
        if [[ -n "$app_info" ]]; then
            local key="${app_info%%---_---*}"
            local name="${app_info#*---_---}"
            if [[ "$name" == "null" || -z "$name" ]]; then name="$key"; fi
            echo "$key ($name)"
        fi
    done | sort
}

# ------------------------------------------------------------------------------
# SECTION: Usage/Help Output
# ------------------------------------------------------------------------------

# Display script usage information.
# Usage: cli::show_usage
cli::show_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [APP_KEYS...]

Check for updates to various applications and optionally install them.

Options:
    -h, --help          Show this help message and exit
    -v, --verbose       Enable verbose output and debug information
    -n, --dry-run       Check for updates but don't download or install
    --cache-duration N  Cache duration in seconds (default: 300)
    --create-config     Create default modular configuration files and exit
    --version           Show script version and exit

Examples:
    $SCRIPT_NAME                    # Check all default configured apps
    $SCRIPT_NAME Ghostty Tabby      # Check specific apps only (using their KEYs)
    $SCRIPT_NAME -v -n              # Verbose dry-run mode

Supported Application Keys (defined in your JSON config files in '$CONFIG_DIR'):
EOF

    while read -r line; do
        loggers::print_message "    $line"
    done < <(cli::get_available_app_keys_for_display)

    cat <<EOF

Configuration directory: '$CONFIG_DIR'
This script is an engine. All application definitions are loaded from the
JSON configuration files in the above directory. Use the --create-config
option to generate default files.

Cache directory: '$CACHE_DIR'
Dependencies: sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release getent
For VeraCrypt: Manually verify and import its GPG key.
For Flatpak apps: Install Flatpak - refer to https://flatpak.org/setup/.
EOF
}

# ------------------------------------------------------------------------------
# SECTION: CLI Argument Parsing
# ------------------------------------------------------------------------------

# Parse command-line arguments.
# Usage: cli::parse_arguments "$@"
cli::parse_arguments() {
    local apps_specified_on_cmdline=0
    local input_app_keys_from_cli_temp=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            cli::show_usage
            exit 0
            ;;
        -v | --verbose)
            VERBOSE=1
            shift
            ;;
        -n | --dry-run)
            DRY_RUN=1
            shift
            ;;
        --cache-duration)
            if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                errors::handle_error "VALIDATION_ERROR" "Option --cache-duration requires a positive integer."
                exit 1
            fi
            CACHE_DURATION="$2"
            shift 2
            ;;
        --create-config)
            configs::create_default_files
            loggers::print_message "Default configuration created/updated in: '$CONFIG_DIR'"
            exit 0
            ;;
        --version)
            echo "$SCRIPT_VERSION"
            exit 0
            ;;
        -*)
            errors::handle_error "VALIDATION_ERROR" "Unknown option: '$1'"
            cli::show_usage >&2
            exit 1
            ;;
        *)
            input_app_keys_from_cli_temp+=("$1")
            apps_specified_on_cmdline=1
            shift
            ;;
        esac
    done

    if [[ "$apps_specified_on_cmdline" -eq 1 ]]; then
        input_app_keys_from_cli=("${input_app_keys_from_cli_temp[@]}")
    fi
}

# ==============================================================================
# END OF MODULE
# ==============================================================================