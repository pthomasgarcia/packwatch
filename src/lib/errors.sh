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
#     source "$CORE_DIR/errors.sh"
#
#   Then use:
#     errors::handle_error "NETWORK_ERROR" "Failed to fetch data" "AppName"
# ==============================================================================
# Dependencies:
#   - globals.sh
#   - interfaces.sh
#   - loggers.sh
#   - notifiers.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Error Handling Functions
# ------------------------------------------------------------------------------

# Centralized error handler.
# Usage: errors::handle_error TYPE MESSAGE [APP_NAME] [CUSTOM_ERROR_TYPE]
#   TYPE               - One of the keys in ERROR_CODES (default error type)
#   MESSAGE            - Error message to log
#   APP_NAME           - (Optional) Application name for context
#   CUSTOM_ERROR_TYPE  - (Optional) Override error type (must be key in ERROR_CODES)
errors::handle_error() {
    local error_type_code="$1"
    # Renamed to avoid conflict with new optional param
    local error_message="$2"
    local app_name="${3:-unknown}"
    local custom_error_type="${4:-}"
    # New optional parameter for custom error type

    local final_error_type="${custom_error_type:-$error_type_code}"
    # Use custom if provided, else default
    local exit_code="${ERROR_CODES[$final_error_type]:-1}"

    # Log the error (requires loggers.sh to be sourced)
    loggers::error "[$final_error_type] $error_message (app: $app_name)"

    # Optionally, send notifications for certain error types (requires
    # notifiers.sh)
    case "$final_error_type" in
        "NETWORK_ERROR")
            notifiers::send_notification "Network Error" "$error_message" \
                "critical"
            ;;
        "CONFIG_ERROR")
            notifiers::send_notification "Configuration Error" "$error_message" \
                "warning"
            ;;
        "PERMISSION_ERROR")
            notifiers::send_notification "Permission Error" \
                "$error_message" "critical"
            ;;
        "VALIDATION_ERROR")
            notifiers::send_notification "Validation Error" "$error_message" \
                "warning"
            ;;
        "DEPENDENCY_ERROR")
            notifiers::send_notification "Dependency Error" "$error_message" \
                "warning"
            ;;
        "GPG_ERROR")
            notifiers::send_notification "GPG Error" "$error_message" \
                "critical"
            ;;
        "CUSTOM_CHECKER_ERROR")
            notifiers::send_notification "Custom Checker Error" "$error_message" \
                "warning"
            ;;
        "INSTALLATION_ERROR")
            notifiers::send_notification "Installation Error" \
                "$error_message" "critical"
            ;;
        "INITIALIZATION_ERROR")
            notifiers::send_notification "Initialization Error" "$error_message" \
                "warning"
            ;;
        "CLI_ERROR")
            notifiers::send_notification "CLI Error" "$error_message" \
                "warning"
            ;;
        "CACHE_ERROR")
            notifiers::send_notification "Cache Error" "$error_message" \
                "warning"
            ;;
    esac

    return "$exit_code"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
