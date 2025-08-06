#!/usr/bin/env bash
# ==============================================================================
# MODULE: systems.sh
# ==============================================================================
# Responsibilities:
#   - System-level helpers (temp files, cleanup, background processes, file sanitization, etc.)
#   - System dependency validation
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
#     systems::check_dependencies
#
# Dependencies:
#   - errors.sh
#   - globals.sh
#   - interfaces.sh
#   - loggers.sh
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
	echo "${filename//[^a-zA-Z0-9._-]/-}"
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
# In systems.sh
systems::perform_housekeeping() {
	loggers::log_message "DEBUG" "Performing application housekeeping..."
	local cache_dir="${CACHE_DIR:-}" # Ensure CACHE_DIR is set or default safely
	local lock_file="${LOCK_FILE:-}"

	# Clean up temporary files
	systems::delete_temp_files

	# Clean up background processes
	systems::_clean_background_processes

	# Clean up old cache files (if desired on exit, though often a scheduled task)
	# systems::_clean_cache_files # Decide if this should run on every exit

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

# ------------------------------------------------------------------------------
# SECTION: JSON Helpers
# ------------------------------------------------------------------------------

# Extract a value from a JSON string using jq.
# Usage: systems::get_json_value "$json" ".field" "app_name"
systems::get_json_value() {
	local json_source="$1" # Can be a JSON string or a file path
	local jq_expression="$2"
	local app_name="${3:-unknown}"
	local result=""

	# Check if json_source is a file path (starts with /tmp/ or similar)
	if [[ -f "$json_source" ]]; then
		result=$(jq -r "$jq_expression // empty" "$json_source" 2>/dev/null)
	else
		# Assume it's a JSON string
		result=$(echo "$json_source" | jq -r "$jq_expression // empty" 2>/dev/null)
	fi
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

# ------------------------------------------------------------------------------
# SECTION: System Dependency Check
# ------------------------------------------------------------------------------

# Check that all required system dependencies are available.
# Calls errors::handle_error_and_exit if dependencies are missing.
# Usage: systems::check_dependencies
systems::check_dependencies() {
	loggers::log_message "INFO" "Performing system dependency check..."
	local -a missing_cmds=()

	# REQUIRED_COMMANDS and INSTALL_CMD are constants from main.sh, assumed available
	# because main.sh sources globals.sh and then lib modules.

	for cmd in "${REQUIRED_COMMANDS[@]}"; do
		if ! command -v "$cmd" &>/dev/null; then
			missing_cmds+=("$cmd")
		fi
	done

	if [[ ${#missing_cmds[@]} -gt 0 ]]; then
		# Print installation help message BEFORE exiting
		interfaces::print_installation_help # Ensure this function is called
		errors::handle_error_and_exit "DEPENDENCY_ERROR" \
			"Missing required core commands: ${missing_cmds[*]}. Please install them." "core"
	fi

	loggers::log_message "INFO" "All core system dependencies found."
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
