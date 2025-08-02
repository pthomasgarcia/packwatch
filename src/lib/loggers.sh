#!/usr/bin/env bash
# ==============================================================================
# MODULE: loggers.sh
# ==============================================================================
# Responsibilities:
#   - All logging and user-facing output
#   - Color and formatting helpers
#   - Standardized log message formatting for both UI and internal logs
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/loggers.sh"
#
#   Then use:
#     loggers::log_message "INFO" "This is an info message"
#     loggers::print_ui_line "  " "✓ " "Success!" _color_green
#     loggers::print_message "Simple message"
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Color and Formatting Helpers
# ------------------------------------------------------------------------------

_color_red()    { printf '\033[31m%b\033[0m' "$1"; }
_color_green()  { printf '\033[32m%b\033[0m' "$1"; }
_color_yellow() { printf '\033[33m%b\033[0m' "$1"; }
_color_blue()   { printf '\033[34m%b\033[0m' "$1"; }
_color_cyan()   { printf '\033[36m%b\033[0m' "$1"; }
_bold()         { printf '\033[1m%b\033[0m' "$1"; }

# ------------------------------------------------------------------------------
# SECTION: Logger Functions
# ------------------------------------------------------------------------------

# Internal log message (to STDERR), with timestamp, PID, and colorized level.
# Usage: loggers::log_message LEVEL MESSAGE...
loggers::log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$

    case "$level" in
        ERROR | CRITICAL)
            echo "[$timestamp] [PID:$pid] [$(_color_red "$level")] $message" >&2
            ;;
        WARN)
            echo "[$timestamp] [PID:$pid] [$(_color_yellow "$level")] $message" >&2
            ;;
        INFO)
            echo "[$timestamp] [PID:$pid] [INFO] $message" >&2
            ;;
        DEBUG)
            [[ ${VERBOSE:-0} -eq 1 ]] && echo "[$timestamp] [PID:$pid] [DEBUG] $message" >&2
            ;;
        *)
            echo "[$timestamp] [PID:$pid] [INFO] $message" >&2
            ;;
    esac
}

# User-facing progress/status message (to STDOUT), with optional color.
# Usage: loggers::print_ui_line "  " "✓ " "Success!" _color_green
loggers::print_ui_line() {
    local indent="$1"   # e.g., "  "
    local prefix="$2"   # e.g., "✓ "
    local message="$3"
    local color_func="${4:-printf}" # e.g., _color_green, _color_red

    printf "%s%s%b\n" "$indent" "$prefix" "$(${color_func} "$message")"
}

# Simple message to STDOUT (legacy, unstructured).
# Usage: loggers::print_message "Hello, world!"
loggers::print_message() {
    printf "%b\n" "$*"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
