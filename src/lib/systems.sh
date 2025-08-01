#!/usr/bin/env bash
# ==============================================================================
# MODULE: systems.sh
# ==============================================================================
# Responsibilities:
#   - System-level helpers (temp files, cleanup, background processes, file sanitization, etc.)
#
# Usage:
#   Source this file in your main script:
#     source "$SCRIPT_DIR/systems.sh"
#
#   Then use:
#     systems::create_temp_file "prefix"
#     systems::delete_temp_files
#     systems::sanitize_filename "filename"
#     systems::reattempt_command 3 2 some_command arg1 arg2
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Temp File and Background Process Tracking
# ------------------------------------------------------------------------------

declare -a TEMP_FILES=()
declare -a BACKGROUND_PIDS=()

# ------------------------------------------------------------------------------
# SECTION: Filename Sanitization
# ------------------------------------------------------------------------------

# Sanitize a filename for safe usage (removes unsafe characters).
# Usage: systems::sanitize_filename "filename"
systems::sanitize_filename() {
    local filename="$1"
    echo "$filename" | sed 's/[^a-zA-Z0-9._-]/-/g'
}

# ------------------------------------------------------------------------------
# SECTION: Temp File Management
# ------------------------------------------------------------------------------

# Create a securely named temporary file and track it for cleanup.
# Usage: systems::create_temp_file "prefix"
systems::create_temp_file() {
    local template="$1"
    template=$(systems::sanitize_filename "$template")
    local temp_file
    temp_file=$(mktemp "/tmp/${template}.XXXXXX")
    if [[ -z "$temp_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: $template"
        return 1
    fi
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
    return 0
}

# Delete all tracked temporary files.
# Usage: systems::delete_temp_files
systems::delete_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            loggers::log_message "DEBUG" "Removing temporary file: $f"
            rm -f "$f"
        fi
    done
}

# Unregister a specific temporary file from cleanup tracking.
# Usage: systems::unregister_temp_file "/tmp/somefile"
systems::unregister_temp_file() {
    local file_to_remove="$1"
    local i
    for i in "${!TEMP_FILES[@]}"; do
        if [[ "${TEMP_FILES[$i]}" == "$file_to_remove" ]]; then
            unset "TEMP_FILES[$i]"
            break
        fi
    done
}

# ------------------------------------------------------------------------------
# SECTION: Background Process Management
# ------------------------------------------------------------------------------

# Kill all tracked background processes.
# Usage: systems::_clean_background_processes
systems::_clean_background_processes() {
    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

# ------------------------------------------------------------------------------
# SECTION: Cache File Cleanup
# ------------------------------------------------------------------------------

# Clean up old cache files (older than 60 minutes).
# Usage: systems::_clean_cache_files
systems::_clean_cache_files() {
    [[ -d "$CACHE_DIR" ]] && find "$CACHE_DIR" -type f -mmin +60 -delete 2>/dev/null
}

# ------------------------------------------------------------------------------
# SECTION: Housekeeping (Cleanup on Exit/Error)
# ------------------------------------------------------------------------------

# Perform all cleanup actions (temp files, background pids, cache).
# Usage: systems::perform_housekeeping
systems::perform_housekeeping() {
    local LAST_COMMAND_EXIT_CODE=$?
    [[ ${VERBOSE:-0} -eq 1 ]] && loggers::log_message "DEBUG" "Cleanup triggered. Last command's exit code: $LAST_COMMAND_EXIT_CODE"
    systems::_clean_background_processes
    systems::delete_temp_files
    systems::_clean_cache_files
}

# ------------------------------------------------------------------------------
# SECTION: Command Retry Helper
# ------------------------------------------------------------------------------

# Re-attempt a given command multiple times with exponential backoff.
# Usage: systems::reattempt_command 3 2 some_command arg1 arg2
systems::reattempt_command() {
    local max_attempts="${1:-3}"
    local delay_secs="${2:-2}"
    shift 2
    local cmd=("$@")

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        loggers::log_message "DEBUG" "Attempt $attempt/$max_attempts: ${cmd[*]}"
        if "${cmd[@]}"; then
            return 0
        fi
        loggers::log_message "WARN" "Command failed (attempt $attempt): ${cmd[*]}"
        if ((attempt < max_attempts)); then
            sleep "$delay_secs"
            delay_secs=$((delay_secs * 2)) # Exponential backoff
        fi
    done
    return 1 # Command failed after all attempts
}

# ------------------------------------------------------------------------------
# SECTION: JSON Helpers
# ------------------------------------------------------------------------------

# Extract a value from a JSON string using jq.
# Usage: systems::get_json_value "$json" ".field" "app_name"
systems::get_json_value() {
    local json_data="$1"
    local jq_expression="$2"
    local app_name="${3:-unknown}"
    local result=""

    result=$(echo "$json_data" | jq -r "$jq_expression // empty" 2>/dev/null)
    local jq_exit_code=$?

    if [[ "$jq_exit_code" -ne 0 ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to parse JSON for '$app_name' with expression: $jq_expression" "$app_name"
        return 1
    fi

    echo "$result"
    return 0
}

# Extract and validate a required value from a JSON string using jq.
# Usage: systems::require_json_value "$json" ".field" "field_name" "app_name"
systems::require_json_value() {
    local json_data="$1"
    local jq_expression="$2"
    local field_name="$3"
    local app_name="${4:-unknown}"
    local value=""

    value=$(systems::get_json_value "$json_data" "$jq_expression" "$app_name")
    local get_json_status=$?

    if [[ "$get_json_status" -ne 0 ]]; then
        return 1
    fi

    if [[ -z "$value" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Required field '$field_name' is missing or empty in JSON for '$app_name'. JQ expression: $jq_expression" "$app_name"
        return 1
    fi

    echo "$value"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================