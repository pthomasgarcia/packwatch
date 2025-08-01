#!/usr/bin/env bash
# ==============================================================================
# MODULE: interfaces.sh
# ==============================================================================
# Responsibilities:
#   - User interaction (headers, prompts)
#
# Usage:
#   Source this file in your main script:
#     source "$SCRIPT_DIR/interfaces.sh"
#
#   Then use:
#     interfaces::display_header "AppName" 1 5
#     interfaces::confirm_prompt "Proceed?" "Y"
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Application Header Display
# ------------------------------------------------------------------------------

# Display a standardized application header.
# Usage: interfaces::display_header "AppName" 1 5
interfaces::display_header() {
    local app_name="$1"
    local current="$2"
    local total="$3"

    loggers::print_message ""
    loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    loggers::print_message "$(_bold "$(_color_cyan "[$current/$total] $app_name")")"
    loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ------------------------------------------------------------------------------
# SECTION: Yes/No Confirmation Prompt
# ------------------------------------------------------------------------------

# Prompt the user for a yes/no confirmation.
# Usage: interfaces::confirm_prompt "Proceed?" "Y"
#   message         - Prompt message
#   default_resp_char - 'Y' or 'N' (default: 'N')
# Returns 0 for yes, 1 for no.
interfaces::confirm_prompt() {
    local message="$1"
    local default_resp_char="${2:-N}" # 'Y' or 'N'
    local prompt_suffix=""
    local response

    if [[ "$default_resp_char" == "Y" ]]; then
        prompt_suffix=" (Y/n): "
    else
        prompt_suffix=" (y/N): "
    fi

    # Use /dev/tty to ensure prompt works under sudo or piped input
    read -rp "$(_bold "$message")$prompt_suffix" response < /dev/tty || true

    local lower_response
    lower_response="${response,,}"

    case "$lower_response" in
        "y" | "yes") return 0 ;;
        "n" | "no") return 1 ;;
        "") [[ "$default_resp_char" == "Y" ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# ==============================================================================
# END OF MODULE
# ==============================================================================