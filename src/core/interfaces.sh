#!/usr/bin/env bash
# shellcheck source=src/core/globals.sh
# ==============================================================================
# MODULE: interfaces.sh
# ==============================================================================
# Responsibilities:
#   - User interaction (headers, prompts, summaries, notifications)
#   - Informing user about execution modes
#   - User-facing error and debug messages
#
# Dependencies:
#   - counters.sh
#   - globals.sh
#   - loggers.sh
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/interfaces.sh"
#
#   Then use:
#     interfaces::display_header "AppName" 1 5
#     interfaces::confirm_prompt "Proceed?" "Y"
#     interfaces::notify_execution_mode
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Color and Formatting Helpers
# ------------------------------------------------------------------------------
# User-facing progress/status message (to STDOUT), with optional color constant.
# Usage: interfaces::print_ui_line "  " "✓ " "Success!" "${COLOR_GREEN}"
interfaces::print_ui_line() {
    local indent="$1" # e.g., "  "
    local prefix="$2" # e.g., "✓ "
    local message="$3"
    local color_constant="${4:-}" # Directly accepts the ANSI color constant (e.g., ${COLOR_GREEN})

    if [[ -n "$color_constant" ]]; then
        printf "%s%s%b%s%b\n" "$indent" "$prefix" "$color_constant" "$message" "$FORMAT_RESET"
    else
        printf "%s%s%s\n" "$indent" "$prefix" "$message"
    fi
}

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
    interfaces::_print_separator
    loggers::print_message "${FORMAT_BOLD}${COLOR_CYAN}[$current/$total] $app_name${FORMAT_RESET}"
    interfaces::_print_separator
}

# Helper to print a standardized separator line
interfaces::_print_separator() {
    loggers::print_message "${FORMAT_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${FORMAT_RESET}"
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
    read -r -e -p "$message$prompt_suffix" response < /dev/tty || true

    local lower_response
    lower_response="${response,,}"

    case "$lower_response" in
        "y" | "yes") return 0 ;;
        "n" | "no") return 1 ;;
        "") [[ "$default_resp_char" == "Y" ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# SECTION: Main Application Header
# ------------------------------------------------------------------------------

# Display the main application header
interfaces::print_application_header() {
    loggers::print_message ""
    loggers::print_message "${FORMAT_BOLD}🔄 $APP_NAME: $APP_DESCRIPTION${FORMAT_RESET}"
    interfaces::_print_separator
}

# ------------------------------------------------------------------------------
# SECTION: Execution Summary Display
# ------------------------------------------------------------------------------

# Display the update summary
interfaces::print_summary() {
    loggers::print_message ""
    interfaces::_print_separator
    loggers::print_message "${FORMAT_BOLD}Update Summary:${FORMAT_RESET}"
    loggers::print_message "  ${COLOR_GREEN}✓ Up to date:${FORMAT_RESET}    $(counters::get_up_to_date)"
    loggers::print_message "  ${COLOR_YELLOW}⬆ Updated:${FORMAT_RESET}       $(counters::get_updated)"
    loggers::print_message "  ${COLOR_RED}✗ Failed:${FORMAT_RESET}        $(counters::get_failed)"
    if [[ $(counters::get_skipped) -gt 0 ]]; then
        loggers::print_message "  ${COLOR_CYAN}🞨 Skipped/Disabled:${FORMAT_RESET} $(counters::get_skipped)"
    fi
    interfaces::_print_separator
}

# ------------------------------------------------------------------------------
# SECTION: Installation Help Display
# ------------------------------------------------------------------------------

# Display installation help information
interfaces::print_installation_help() {
    loggers::print_message ""
    loggers::print_message "${FORMAT_BOLD}To install core dependencies:${FORMAT_RESET}"
    loggers::print_message "  ${COLOR_CYAN}$INSTALL_CMD${FORMAT_RESET}"
    loggers::print_message ""
    loggers::print_message "Additional notes:"
    loggers::print_message "  • For 'notify-send': install 'libnotify-bin'"
    loggers::print_message "  • For 'flatpak': see https://flatpak.org/setup/"
}

# ------------------------------------------------------------------------------
# SECTION: Execution Mode Notification
# ------------------------------------------------------------------------------

# Notify the user if the script is running in dry-run mode.
# Usage: interfaces::notify_execution_mode
interfaces::notify_execution_mode() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then # Use default value for DRY_RUN for robustness
        loggers::print_message ""
        loggers::print_message "${COLOR_YELLOW}🚀 Running in DRY RUN mode - no installations or file modifications will be performed.${FORMAT_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# SECTION: User-Facing Error Messages
# ------------------------------------------------------------------------------

# Display home determination error to user
interfaces::print_home_determination_error() {
    local error_msg="$1"
    loggers::print_message "${COLOR_RED}⚠️  $error_msg${FORMAT_RESET}" >&2
}

# Display general error to user
interfaces::print_error_to_user() {
    local error_msg="$1"
    loggers::print_message "${COLOR_RED}❌ Error: $error_msg${FORMAT_RESET}" >&2
}

# ------------------------------------------------------------------------------
# SECTION: Debug Information Display
# ------------------------------------------------------------------------------

# Display debug state snapshot to user
interfaces::print_debug_state_snapshot() {
    loggers::print_message "${COLOR_CYAN}🔍 Debug Information:${FORMAT_RESET}" >&2
    loggers::print_message "   CORE_DIR: $CORE_DIR" >&2
    loggers::print_message "   CONFIG_ROOT: $CONFIG_ROOT" >&2
    loggers::print_message "   CONFIG_DIR: $CONFIG_DIR" >&2
    loggers::print_message "   CACHE_DIR: $CACHE_DIR" >&2
    loggers::print_message "   ORIGINAL_USER: $ORIGINAL_USER" >&2
    loggers::print_message "   ORIGINAL_HOME: $ORIGINAL_HOME" >&2
    loggers::print_message "   DRY_RUN: $DRY_RUN" >&2
    loggers::print_message "   VERBOSE: $VERBOSE" >&2
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
