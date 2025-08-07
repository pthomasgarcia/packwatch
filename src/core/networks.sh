#!/usr/bin/env bash
# ==============================================================================
# MODULE: networks.sh
# ==============================================================================
# Responsibilities:
#   - Networking, downloads, caching, and rate limiting
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/networks.sh"
#
#   Then use:
#     networks::download_file "url" "/tmp/file" "checksum" "sha256"
#     networks::fetch_cached_data "url" "json"
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Networking
# Ensure LAST_API_CALL is initialized to avoid arithmetic errors
LAST_API_CALL=0
# ------------------------------------------------------------------------------

# These variables are now loaded from configs.sh
# CACHE_DIR
# CACHE_DURATION
# NETWORK_CONFIG (associative array)
# LAST_API_CALL (managed internally by networks.sh)
# API_RATE_LIMIT (managed internally by networks.sh)

# ------------------------------------------------------------------------------
# SECTION: URL Decoding
# ------------------------------------------------------------------------------

# Decode HTML-encoded characters in a URL.
# Usage: networks::decode_url "https%3A%2F%2Fexample.com"
networks::decode_url() {
	local encoded_url="$1"
	echo "$encoded_url" | sed -e 's/&#43;/+/g' -e 's/%2B/+/g'
}

# ------------------------------------------------------------------------------
# SECTION: Rate Limiting
# ------------------------------------------------------------------------------

# Apply a rate limit to API calls.
# Usage: networks::apply_rate_limit
networks::apply_rate_limit() {
	local current_time
	current_time=$(date +%s)
	local time_diff=$((current_time - LAST_API_CALL))
	local rate_limit_val="${NETWORK_CONFIG[RATE_LIMIT]:-1}" # Default to 1 if not set

	if ((time_diff < rate_limit_val)); then
		local sleep_duration=$((rate_limit_val - time_diff))
		loggers::log_message "DEBUG" "Rate limiting: sleeping for ${sleep_duration}s"
		sleep "$sleep_duration"
	fi

	LAST_API_CALL=$(date +%s)
}

# ------------------------------------------------------------------------------
# SECTION: Curl Argument Builder
# ------------------------------------------------------------------------------

# Helper to get the User-Agent string from NETWORK_CONFIG or fallback
networks::_user_agent() {
	printf '%s' "${NETWORK_CONFIG[USER_AGENT]:-Packwatch/1.0}"
}

# Build standard curl arguments.
# Usage: networks::build_curl_args "/tmp/file" 4
networks::build_curl_args() {
	local output_file="$1"
	local timeout_multiplier="${2:-4}"
	local timeout_val="${NETWORK_CONFIG[TIMEOUT]:-10}"

	local args=(
		"-L" "--fail" "--output" "$output_file"
		"--connect-timeout" "$timeout_val"
		"--max-time" "$((timeout_val * timeout_multiplier))"
		"-A" "$(networks::_user_agent)"
		"-s"
	)

	printf '%s\n' "${args[@]}"
}

# ------------------------------------------------------------------------------
# SECTION: Cached Data Fetching
# ------------------------------------------------------------------------------

# Fetch data from a URL, using cache if available.
# Usage: networks::fetch_cached_data "url" "json"
networks::fetch_cached_data() {
	local url="$1"
	local expected_type="$2" # "json", "html", "raw"
	local cache_key
	cache_key=$(echo -n "$url" | sha256sum | cut -d' ' -f1)
	local cache_file="${CACHE_DIR:-/tmp/packwatch_cache}/$cache_key" # Use global CACHE_DIR
	local temp_download_file

	mkdir -p "${CACHE_DIR:-/tmp/packwatch_cache}" || { # Use global CACHE_DIR
		errors::handle_error "PERMISSION_ERROR" "Failed to create cache directory: '${CACHE_DIR:-/tmp/packwatch_cache}'"
		return 1
	}

	# Check cache first
	local cache_duration_val="${CACHE_DURATION:-300}" # Use global CACHE_DURATION
	if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt "$cache_duration_val" ]]; then
		loggers::log_message "DEBUG" "Using cached response for: '$url' (file: '$cache_file')"
		echo "$cache_file" # Return the path to the cached file
		return 0
	else
		networks::apply_rate_limit

		temp_download_file=$(systems::create_temp_file "fetch_response")
		if [[ $? -ne 0 ]]; then return 1; fi

		local -a curl_args; mapfile -t curl_args < <(networks::build_curl_args "$temp_download_file" "${NETWORK_CONFIG[TIMEOUT_MULTIPLIER]:-4}") # Use configurable timeout multiplier

		local max_retries_val="${NETWORK_CONFIG[MAX_RETRIES]:-3}"
		local retry_delay_val="${NETWORK_CONFIG[RETRY_DELAY]:-5}"
		if ! systems::reattempt_command "$max_retries_val" "$retry_delay_val" curl "${curl_args[@]}" "$url"; then
			errors::handle_error "NETWORK_ERROR" "Failed to download '$url' after multiple attempts."
			systems::unregister_temp_file "$temp_download_file" # Clean up failed download
			return 1
		fi

		case "$expected_type" in
		"json")
			if ! jq . "$temp_download_file" >/dev/null 2>&1; then
				errors::handle_error "VALIDATION_ERROR" "Fetched content for '$url' is not valid JSON."
				systems::unregister_temp_file "$temp_download_file" # Clean up invalid content
				return 1
			fi
			;;
		"html")
			if ! grep -q '<html' "$temp_download_file" >/dev/null 2>&1 && ! grep -q '<!DOCTYPE html>' "$temp_download_file" >/dev/null 2>&1; then
				loggers::log_message "WARN" "Fetched content for '$url' might not be valid HTML, but continuing."
			fi
			;;
		esac

		mv "$temp_download_file" "$cache_file" || {
			errors::handle_error "PERMISSION_ERROR" "Failed to move temporary file '$temp_download_file' to cache '$cache_file' for '$url'"
			systems::unregister_temp_file "$temp_download_file" # Clean up if move fails
			return 1
		}
		systems::unregister_temp_file "$temp_download_file" # Unregister after successful move

		echo "$cache_file" # Return the path to the cached file
		return 0
	fi
}
# Get the effective URL after redirects.
# Usage: networks::get_effective_url "url"
networks::get_effective_url() {
	local url="$1"
	local curl_output

	networks::apply_rate_limit

	# Use curl to get the effective URL after redirects, discarding content
	if ! curl_output=$(systems::reattempt_command "${NETWORK_CONFIG[MAX_RETRIES]:-3}" "${NETWORK_CONFIG[RETRY_DELAY]:-5}" curl -s -L \
		-H "User-Agent: $(networks::_user_agent)" \
		-o /dev/null \
		-w "%{url_effective}\n" \
		"$url"); then
		errors::handle_error "NETWORK_ERROR" "Failed to get effective URL for '$url'."
		return 1
	fi

	local effective_url
	effective_url=$(echo "$curl_output" | tr -d '\r')
	if [[ -z "$effective_url" ]]; then
		errors::handle_error "NETWORK_ERROR" "Failed to get effective URL for '$url'."
		return 1
	fi

	echo "$effective_url"
	return 0
}

# ------------------------------------------------------------------------------
# SECTION: File Downloading
# Efficiently check if a URL exists using a HEAD request.
# Usage: networks::url_exists "url"
networks::url_exists() {
	local url="$1"
	networks::apply_rate_limit
	if curl -s --head --fail -A "$(networks::_user_agent)" "$url" >/dev/null; then
		return 0
	else
		return 1
	fi
}
# ------------------------------------------------------------------------------

# Download a file from a given URL.
# Usage: networks::download_file "url" "/tmp/file" "checksum" "sha256"
networks::download_file() {
	local url="$1"
	local dest_path="$2"
	local expected_checksum="$3"
	local checksum_algorithm="${4:-sha256}"

	loggers::print_ui_line "  " "→ " "Downloading $(basename "$dest_path")..." >&2 # Redirect to stderr

	if [[ ${DRY_RUN:-0} -eq 1 ]]; then
		loggers::print_ui_line "    " "[DRY RUN] " "Would download: '$url'" "${COLOR_YELLOW}" >&2 # Redirect to stderr
		return 0
	fi

	if [[ -z "$url" ]]; then
		errors::handle_error "NETWORK_ERROR" "Download URL is empty for destination: '$dest_path'."
		return 1
	fi

	local -a curl_args; mapfile -t curl_args < <(networks::build_curl_args "$dest_path" "${NETWORK_CONFIG[TIMEOUT_MULTIPLIER]:-10}") # Use configurable timeout multiplier

	if ! systems::reattempt_command "${NETWORK_CONFIG[MAX_RETRIES]:-3}" "${NETWORK_CONFIG[RETRY_DELAY]:-5}" curl "${curl_args[@]}" "$url"; then
		errors::handle_error "NETWORK_ERROR" "Failed to download '$url' after multiple attempts."
		return 1
	fi

	if [[ -n "$expected_checksum" ]]; then
		loggers::log_message "DEBUG" "Attempting checksum verification for '$dest_path' with expected: '$expected_checksum', algorithm: '$checksum_algorithm'"
		if ! validators::verify_checksum "$dest_path" "$expected_checksum" "$checksum_algorithm"; then
			errors::handle_error "VALIDATION_ERROR" "Checksum verification failed for downloaded file: '$dest_path'"
			return 1
		fi
	else
		loggers::log_message "DEBUG" "No expected checksum provided for '$dest_path'. Skipping verification."
	fi

	return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
