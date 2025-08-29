#!/usr/bin/env bash
# ==============================================================================
# MODULE: systems.sh
# ==============================================================================
# Responsibilities:
#   - System-level helpers (temp files, cleanup, background processes, file sanitization, etc.)
#   - System dependency validation
#   - Command retry and CLI error handling
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/systems.sh"
#
#   Then use:
#     systems::create_temp_file "prefix"
#     systems::delete_temp_files
#     systems::sanitize_filename "filename"
#     systems::reattempt_command 3 2 some_command arg1 arg2
#     systems::cli_with_retry_or_error 3 2 "app" "error message" -- command args
#     systems::check_dependencies
#
# Dependencies:
#   - errors.sh
#   - globals.sh
#   - interfaces.sh
#   - loggers.sh
#   - responses.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Temp File and Background Process Tracking
# ------------------------------------------------------------------------------

declare -a TEMP_FILES=()
declare -a BACKGROUND_PIDS=()

# ------------------------------------------------------------------------------
# SECTION: JSON Parsing Cache
# ------------------------------------------------------------------------------

declare -gA _jq_cache=() # Global cache for parsed JSON

# Parse entire JSON once and cache results
systems::cache_json() {
    local json_data="$1"
    local cache_key="$2" # Unique identifier for this JSON

    # Clear previous cache entries for this key
    for key in "${!_jq_cache[@]}"; do
        if [[ "$key" == "$cache_key"* ]]; then
            unset "_jq_cache[$key]"
        fi
    done

    # Parse all fields at once and store in cache
    while IFS=$'\t' read -r key value; do
        _jq_cache["${cache_key}_${key}"]="$value"
    done < <(echo "$json_data" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2> /dev/null)

    # Store original JSON for fallback
    _jq_cache["$cache_key"]="$json_data"
}

# Get cached JSON value
systems::fetch_cached_json() {
    local cache_key="$1"
    local field="$2"
    echo "${_jq_cache["${cache_key}_${field}"]:-}"
}

# Clear JSON cache
systems::clear_json_cache() {
    unset _jq_cache
    declare -gA _jq_cache=()
}

# ------------------------------------------------------------------------------
# SECTION: Filename Sanitization
# ------------------------------------------------------------------------------

# Sanitize a filename for safe usage (removes unsafe characters).
# Usage: systems::sanitize_filename "filename"
systems::sanitize_filename() {
    local filename="$1"
    # Replace any path separators or backslashes with dashes first to prevent traversal
    filename=${filename//\//-}
    filename=${filename//\\/-}
    # Allow only [A-Za-z0-9._-]; replace others with '-'
    filename=$(echo -n "$filename" | sed -E 's/[^A-Za-z0-9._-]+/-/g')
    # Collapse multiple consecutive dots to a single dot to avoid spoofing like 'tar..gz'
    filename=$(echo -n "$filename" | sed -E 's/\.{2,}/./g')
    # Remove leading dots entirely (avoid hidden files or relative path implications)
    filename=$(echo -n "$filename" | sed -E 's/^\.+//')
    # Trim any leading dashes produced by stripping leading dots
    filename=$(echo -n "$filename" | sed -E 's/^-+//')
    # Fallback if empty after sanitization
    if [[ -z "$filename" ]]; then
        filename="unnamed"
    fi
    echo "$filename"
}

# ------------------------------------------------------------------------------
# SECTION: Temp File Management
# ------------------------------------------------------------------------------

# Create a securely named temporary file and track it for cleanup.
# Usage: systems::create_temp_file "prefix"
systems::create_temp_file() {
    local template="$1"
    template=$(systems::sanitize_filename "$template")

    # Use a user-specific cache directory to avoid sudo requirements for temp files.
    local temp_dir="${HOME}/.cache/packwatch/tmp"
    mkdir -p "$temp_dir" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create temporary directory: $temp_dir"
        return 1
    }

    local temp_file
    temp_file=$(mktemp "${temp_dir}/${template}.XXXXXX") || {
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: $template in $temp_dir"
        return 1
    }
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
# Usage: systems::unregister_temp_file "/path/to/somefile"
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
        if kill -0 "$pid" 2> /dev/null; then
            kill "$pid" 2> /dev/null || true
        fi
    done
}

# ------------------------------------------------------------------------------
# SECTION: Cache File Cleanup
# ------------------------------------------------------------------------------

# Clean up old cache files (older than 60 minutes).
# Usage: systems::_clean_cache_files
systems::_clean_cache_files() {
    [[ -d "$CACHE_DIR" ]] && find "$CACHE_DIR" -type f -mmin +60 -delete 2> /dev/null
}

# ------------------------------------------------------------------------------
# SECTION: Housekeeping (Cleanup on Exit/Error)
# ------------------------------------------------------------------------------

# Perform all cleanup actions (temp files, background pids, cache).
# Usage: systems::perform_housekeeping
systems::perform_housekeeping() {
    loggers::log_message "DEBUG" "Performing application housekeeping..."
    local lock_file="${LOCK_FILE:-}"

    # Clean up temporary files
    systems::delete_temp_files

    # Clean up background processes
    systems::_clean_background_processes

    # Clean up old cache files (if desired on exit, though often a scheduled task)
    # systems::_clean_cache_files # Decide if this should run on every exit

    # Remove legacy cache directory if it exists
    if [[ -d "/tmp/packwatch_cache" ]]; then
        loggers::log_message "DEBUG" "Removing legacy cache directory: /tmp/packwatch_cache"
        rm -rf "/tmp/packwatch_cache" || true
    fi

    # Clean up lock file
    if [[ -n "$lock_file" && -e "$lock_file" ]]; then
        loggers::log_message "DEBUG" "Removing lock file: $lock_file"
        rm -f -- "$lock_file" || true
    fi
    return 0
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

# Run a CLI with retry using systems::reattempt_command.
# Success: echoes command stdout to STDOUT (machine-readable path preserved).
# Failure: emits structured error JSON to STDERR (so STDOUT stays clean/empty) and returns non-zero.
# Usage: systems::cli_with_retry_or_error <RETRIES> <SLEEP> <APP_NAME> <FAIL_MSG> -- <cmd> [args...]
systems::cli_with_retry_or_error() {
    local retries="$1" sleep_secs="$2" app="$3" fail_msg="$4"
    shift 4
    # Optional "--" delimiter support
    [[ "$1" == "--" ]] && shift
    local output
    if [[ -n "${DEBUG:-}" && "${DEBUG}" != "0" ]]; then
        # Debug mode: preserve stderr from underlying command for diagnostics
        if ! output=$(systems::reattempt_command "$retries" "$sleep_secs" "$@"); then
            # Use responses::emit_error for consistency with custom checkers
            # This creates a dependency from systems.sh back to responses.sh, which is not ideal.
            # Ideally, emit_error would be in a more generic error handling module.
            # For now, we'll keep the dependency for functional correctness.
            responses::emit_error "COMMAND_ERROR" "$fail_msg" "$app" >&2
            return 1
        fi
    else
        # Normal mode: suppress underlying command stderr; still surface structured JSON on failure
        if ! output=$(systems::reattempt_command "$retries" "$sleep_secs" "$@" 2> /dev/null); then
            responses::emit_error "COMMAND_ERROR" "$fail_msg" "$app" >&2
            return 1
        fi
    fi
    printf '%s' "$output"
}

# ------------------------------------------------------------------------------
# SECTION: JSON Helpers
# ------------------------------------------------------------------------------

# Extract a value from a JSON string using jq.
# Usage: systems::fetch_json "$json" ".field" "app_name"
systems::fetch_json() {
    local json_source="$1"
    local jq_expression="$2"
    local app_name="${3:-unknown}"

    # Handle file paths as before
    if [[ -f "$json_source" ]]; then
        jq -r "$jq_expression // empty" "$json_source" 2> /dev/null
        return $?
    fi

    # For JSON strings, check if it's a simple field access
    if [[ "$jq_expression" =~ ^\.[a-zA-Z0-9_]+$ ]]; then
        local field_name="${jq_expression#.}"
        local cache_key
        cache_key="json_$(echo "$json_source" | md5sum | cut -d' ' -f1)"

        # Check cache first
        if [[ -n "${_jq_cache["${cache_key}_${field_name}"]+isset}" ]]; then
            echo "${_jq_cache["${cache_key}_${field_name}"]}"
            return 0
        fi

        # Cache all fields if not already done
        if [[ -z "${_jq_cache["$cache_key"]+isset}" ]]; then
            systems::cache_json "$json_source" "$cache_key"
        fi

        # Return cached value
        echo "${_jq_cache["${cache_key}_${field_name}"]:-}"
        return 0
    fi

    # Fallback to direct jq for complex expressions
    echo "$json_source" | jq -r "$jq_expression // empty" 2> /dev/null
    return $?
}

# Extract and validate a required value from a JSON string using jq.
# Usage: systems::require_json_value "$json" ".field" "field_name" "app_name"
systems::require_json_value() {
    local json_data="$1"
    local jq_expression="$2"
    local field_name="$3"
    local app_name="${4:-unknown}"
    local value=""

    value=$(systems::fetch_json "$json_data" "$jq_expression" "$app_name")
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

# ------------------------------------------------------------------------------
# SECTION: Sudo Session Check
# ------------------------------------------------------------------------------

# Checks if a sudo session is currently active without prompting for a password.
# Usage: if systems::is_sudo_session_active; then ...
systems::is_sudo_session_active() {
    # -n (non-interactive) prevents a password prompt.
    # The command returns 0 if sudo is active, 1 otherwise.
    sudo -n true 2> /dev/null
}

# ------------------------------------------------------------------------------
# SECTION: System Dependency Check
# ------------------------------------------------------------------------------

# Check that all required system dependencies are available.
# Calls errors::handle_error if dependencies are missing.
# Usage: systems::check_dependencies
systems::check_dependencies() {
    loggers::log_message "INFO" "Performing system dependency check..."
    local -a missing_cmds=()

    # REQUIRED_COMMANDS and INSTALL_CMD are constants from main.sh, assumed available
    # because main.sh sources globals.sh and then lib modules.

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        # Print installation help message BEFORE exiting
        interfaces::print_installation_help # Ensure this function is called
        errors::handle_error "DEPENDENCY_ERROR" \
            "Missing required core commands: ${missing_cmds[*]}. Please install them." "core"
        return 1
    fi

    loggers::log_message "INFO" "All core system dependencies found."
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
