#!/usr/bin/env bash
# ==============================================================================
# MODULE: errors.sh
# ==============================================================================
# Responsibilities:
#   - Centralized error handling and reporting
#   - Error code definitions
#
# Usage:
#   Source this file in your main script:
#     source "$SCRIPT_DIR/errors.sh"
#
#   Then use:
#     errors::handle_error "NETWORK_ERROR" "Failed to fetch data" "AppName"
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Error Code Definitions
# ------------------------------------------------------------------------------

declare -A ERROR_CODES=(
    ["NETWORK_ERROR"]=10
    ["CONFIG_ERROR"]=11
    ["PERMISSION_ERROR"]=12
    ["VALIDATION_ERROR"]=13
    ["DEPENDENCY_ERROR"]=14
    ["GPG_ERROR"]=15
    ["CUSTOM_CHECKER_ERROR"]=16
    ["INSTALLATION_ERROR"]=17
)

# ------------------------------------------------------------------------------
# SECTION: Error Handling Function
# ------------------------------------------------------------------------------

# Centralized error handler.
# Usage: errors::handle_error TYPE MESSAGE [APP_NAME]
#   TYPE      - One of the keys in ERROR_CODES
#   MESSAGE   - Error message to log
#   APP_NAME  - (Optional) Application name for context
errors::handle_error() {
    local error_type="$1"
    local error_message="$2"
    local app_name="${3:-unknown}"

    local exit_code="${ERROR_CODES[$error_type]:-1}"

    # Log the error (requires loggers.sh to be sourced)
    loggers::log_message "ERROR" "[$error_type] $error_message (app: $app_name)"

    # Optionally, send notifications for certain error types (requires notifiers.sh)
    case "$error_type" in
        "NETWORK_ERROR")
            notifiers::send_notification "Network Error" "$error_message" "critical"
            ;;
        "PERMISSION_ERROR")
            notifiers::send_notification "Permission Error" "$error_message" "critical"
            ;;
        "GPG_ERROR")
            notifiers::send_notification "GPG Error" "$error_message" "critical"
            ;;
        "INSTALLATION_ERROR")
            notifiers::send_notification "Installation Error" "$error_message" "critical"
            ;;
    esac

    return "$exit_code"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================