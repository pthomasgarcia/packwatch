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
#     loggers::log "INFO" "This is an info message"
#     loggers::output "Simple message"
#
# Dependencies:
#   - None
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Logger Functions
# ------------------------------------------------------------------------------

# Internal log message (to STDERR), with timestamp, PID, and colorized level.
# Usage: loggers::log LEVEL MESSAGE...
loggers::log() {
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

# ------------------------------------------------------------------------------
# SECTION: Semantic Logger Functions
# ------------------------------------------------------------------------------

# Log a debug message.
# Usage: loggers::debug "This is a debug message"
loggers::debug() {
    loggers::log "DEBUG" "$@"
}

# Log an info message.
# Usage: loggers::info "This is an info message"
loggers::info() {
    loggers::log "INFO" "$@"
}

# Log a warning message.
# Usage: loggers::warn "This is a warning message"
loggers::warn() {
    loggers::log "WARN" "$@"
}

# Log an error message.
# Usage: loggers::error "This is an error message"
loggers::error() {
    loggers::log "ERROR" "$@"
}

# Simple message to STDOUT (legacy, unstructured).
# Usage: loggers::output "Hello, world!"
loggers::output() {
    printf "%b\n" "$*"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
