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
#   - loggers.sh (for internal logging)
#   - counters.sh (for summary statistics)
#   - globals.sh (for APP_NAME, APP_DESCRIPTION, DRY_RUN)
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

_color_cyan() { echo -e "\033[36m$1\033[0m"; }
_color_green() { echo -e "\033[32m$1\033[0m"; }
_color_yellow() { echo -e "\033[33m$1\033[0m"; }
_color_red() { echo -e "\033[31m$1\033[0m"; }
_bold() { echo -e "\033[1m$1\033[0m"; }

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
	read -rp "$(_bold "$message")$prompt_suffix" response </dev/tty || true

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
	loggers::print_message "$(_bold "🔄 $APP_NAME: $APP_DESCRIPTION")"
	loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ------------------------------------------------------------------------------
# SECTION: Execution Summary Display
# ------------------------------------------------------------------------------

# Display the update summary
interfaces::print_summary() {
	loggers::print_message ""
	loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
	loggers::print_message "$(_bold "Update Summary:")"
	loggers::print_message "  $(_color_green "✓ Up to date:")    $(counters::get_up_to_date)"
	loggers::print_message "  $(_color_yellow "⬆ Updated:")       $(counters::get_updated)"
	loggers::print_message "  $(_color_red "✗ Failed:")        $(counters::get_failed)"
	if [[ $(counters::get_skipped) -gt 0 ]]; then
		loggers::print_message "  $(_color_cyan "🞨 Skipped/Disabled:") $(counters::get_skipped)"
	fi
	loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
}

# ------------------------------------------------------------------------------
# SECTION: Installation Help Display
# ------------------------------------------------------------------------------

# Display installation help information
interfaces::print_installation_help() {
	loggers::print_message ""
	loggers::print_message "$(_bold "To install core dependencies:")"
	loggers::print_message "  $(_color_cyan "$INSTALL_CMD")"
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
		loggers::print_message "$(_color_yellow "🚀 Running in DRY RUN mode - no installations or file modifications will be performed.")"
	fi
}

# ------------------------------------------------------------------------------
# SECTION: User-Facing Error Messages
# ------------------------------------------------------------------------------

# Display home determination error to user
interfaces::print_home_determination_error() {
	local error_msg="$1"
	loggers::print_message "$(_color_red "⚠️  $error_msg")" >&2
}

# Display general error to user
interfaces::print_error_to_user() {
	local error_msg="$1"
	loggers::print_message "$(_color_red "❌ Error: $error_msg")" >&2
}

# ------------------------------------------------------------------------------
# SECTION: Debug Information Display
# ------------------------------------------------------------------------------

# Display debug state snapshot to user
interfaces::print_debug_state_snapshot() {
	loggers::print_message "$(_color_cyan "🔍 Debug Information:")" >&2
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