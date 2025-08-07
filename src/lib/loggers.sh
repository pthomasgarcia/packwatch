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
#
# Dependencies:
#   - None
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Color and Formatting Helpers
# ------------------------------------------------------------------------------

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
        printf '[%s] [PID:%s] [%b%s%b] %s\n' "$timestamp" "$pid" "$COLOR_RED" "$level" "$FORMAT_RESET" "$message" >&2
        ;;
    WARN)
        printf '[%s] [PID:%s] [%b%s%b] %s\n' "$timestamp" "$pid" "$COLOR_YELLOW" "$level" "$FORMAT_RESET" "$message" >&2
        ;;
    INFO)
        printf '[%s] [PID:%s] [INFO] %s\n' "$timestamp" "$pid" "$message" >&2
        ;;
    DEBUG)
        [[ ${VERBOSE:-0} -eq 1 ]] && printf '[%s] [PID:%s] [DEBUG] %s\n' "$timestamp" "$pid" "$message" >&2
        ;;
    *)
        printf '[%s] [PID:%s] [INFO] %s\n' "$timestamp" "$pid" "$message" >&2
        ;;
    esac
}

# User-facing progress/status message (to STDOUT), with optional color constant.
# Usage: loggers::print_ui_line "  " "✓ " "Success!" "${COLOR_GREEN}"
loggers::print_ui_line() {
    local indent="$1" # e.g., "  "
    local prefix="$2" # e.g., "✓ "
    local message="$3"
    local color_constant="${4:-}" # Directly accepts the ANSI color constant (e.g., ${COLOR_GREEN})

    if [[ -n "$color_constant" ]]; then
        printf "%s%s%b%b%b\n" "$indent" "$prefix" "$color_constant" "$message" "$FORMAT_RESET"
    else
        printf "%s%s%b\n" "$indent" "$prefix" "$message"
    fi
}

# Simple message to STDOUT (legacy, unstructured).
# Usage: loggers::print_message "Hello, world!"
loggers::print_message() {
    printf "%b\n" "$*"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
