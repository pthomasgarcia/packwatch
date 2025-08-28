#!/usr/bin/env bash
# ==============================================================================
# MODULE: json_response.sh
# ==============================================================================
# Responsibilities:
#   - Uniform JSON emission for errors and successes.
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - versions.sh
#   - updates.sh
#   - jq (at runtime)
# ==============================================================================

# Uniform error JSON emission with centralized logging/notification.
# Usage: json_response::emit_error <ERROR_TYPE> <MESSAGE> [APP_NAME] [CUSTOM_ERROR_TYPE]
json_response::emit_error() {
    local error_type="$1"
    local error_message="$2"
    local app_name="${3:-unknown}"
    local custom_error_type="${4:-}"

    # Prefer centralized handler if available; otherwise log locally.
    if declare -F errors::handle_error > /dev/null 2>&1; then
        errors::handle_error "$error_type" "$error_message" "$app_name" "$custom_error_type"
    else
        loggers::log_message "ERROR" "[$error_type] $error_message (app: $app_name)"
    fi

    jq -n \
        --arg status "error" \
        --arg error_message "$error_message" \
        --arg error_type "$error_type" \
        '{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
}
# Determine the status of an application update.
# Usage: json_response::determine_status "1.0.0" "1.0.1"
json_response::determine_status() {
    local installed_version="$1"
    local latest_version="$2"

    local normalized_installed_version
    normalized_installed_version=$(versions::strip_version_prefix "$installed_version")
    local normalized_latest_version
    normalized_latest_version=$(versions::strip_version_prefix "$latest_version")

    if ! updates::is_needed "$normalized_installed_version" "$normalized_latest_version"; then
        echo "no_update"
    else
        echo "success"
    fi
}

# Uniform success JSON emission.
# Usage: json_response::emit_success <STATUS> <LATEST_VERSION> <INSTALL_TYPE> <SOURCE> [key value]...
# Always includes: status, latest_version, install_type, source, error_type:"NONE"
json_response::emit_success() {
    local status="$1"
    local latest="$2"
    local install_type="$3"
    local source="$4"
    shift 4

    local jq_prog="{ \"status\": \$status, \"latest_version\": \$latest, \"install_type\": \$install_type, \"source\": \$source, \"error_type\": \"NONE\" }"
    local args=(--arg status "$status" --arg latest "$latest" --arg install_type "$install_type" --arg source "$source")

    # Append extra k/v pairs
    while (("$#" >= 2)); do
        local k="$1"
        local v="$2"
        shift 2
        args+=(--arg "$k" "$v")
        jq_prog="${jq_prog} + {\"$k\": \$$k}"
    done

    jq -n "${args[@]}" "$jq_prog"
}
