#!/usr/bin/env bash
# ==============================================================================
# MODULE: networks.sh
# ==============================================================================
# Responsibilities:
#   - Networking, downloads, caching, and rate limiting
#
# Usage:
#   Source this file in your main script:
#     source "$SCRIPT_DIR/networks.sh"
#
#   Then use:
#     networks::download_file "url" "/tmp/file" "checksum" "sha256"
#     networks::fetch_cached_data "url" "json"
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Networking
# ------------------------------------------------------------------------------

# These should be set in your main script or config:
#   CACHE_DIR="/tmp/app-updater-cache"
#   CACHE_DURATION=300
#   declare -A NETWORK_CONFIG=([MAX_RETRIES]=3 [TIMEOUT]=30 [USER_AGENT]="AppUpdater/1.0" [RATE_LIMIT]=1 [RETRY_DELAY]=2)
#   LAST_API_CALL=0
#   API_RATE_LIMIT=1

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

    if ((time_diff < API_RATE_LIMIT)); then
        local sleep_duration=$((API_RATE_LIMIT - time_diff))
        loggers::log_message "DEBUG" "Rate limiting: sleeping for ${sleep_duration}s"
        sleep "$sleep_duration"
    fi

    LAST_API_CALL=$(date +%s)
}

# ------------------------------------------------------------------------------
# SECTION: Curl Argument Builder
# ------------------------------------------------------------------------------

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
        "-A" "${NETWORK_CONFIG[USER_AGENT]:-AppUpdater/1.0}"
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
    local cache_file="$CACHE_DIR/$cache_key"
    local temp_download_file

    mkdir -p "$CACHE_DIR" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create cache directory: '$CACHE_DIR'"
        return 1
    }

    # Check cache first
    if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt $CACHE_DURATION ]]; then
        loggers::log_message "DEBUG" "Using cached response for: '$url' (file: '$cache_file')"
        cat "$cache_file"
        return 0
    else
        networks::apply_rate_limit

        temp_download_file=$(systems::create_temp_file "fetch_response")
        if [[ $? -ne 0 ]]; then return 1; fi

        local -a curl_args=($(networks::build_curl_args "$temp_download_file" 4))

        if ! systems::reattempt_command 3 5 curl "${curl_args[@]}" "$url"; then
            errors::handle_error "NETWORK_ERROR" "Failed to download '$url' after multiple attempts."
            return 1
        fi

        case "$expected_type" in
            "json")
                if ! jq . "$temp_download_file" >/dev/null 2>&1; then
                    errors::handle_error "VALIDATION_ERROR" "Fetched content for '$url' is not valid JSON."
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
            return 1
        }

        cat "$cache_file"
        return 0
    fi
}

# ------------------------------------------------------------------------------
# SECTION: File Downloading
# ------------------------------------------------------------------------------

# Download a file from a given URL.
# Usage: networks::download_file "url" "/tmp/file" "checksum" "sha256"
networks::download_file() {
    local url="$1"
    local dest_path="$2"
    local expected_checksum="$3"
    local checksum_algorithm="${4:-sha256}"

    loggers::print_ui_line "  " "→ " "Downloading $(basename "$dest_path")..." >&2  # Redirect to stderr

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        loggers::print_ui_line "    " "[DRY RUN] " "Would download: '$url'" _color_yellow >&2  # Redirect to stderr
        return 0
    fi

    if [[ -z "$url" ]]; then
        errors::handle_error "NETWORK_ERROR" "Download URL is empty for destination: '$dest_path'."
        return 1
    fi

    local -a curl_args=($(networks::build_curl_args "$dest_path" 10))

    if ! systems::reattempt_command 3 5 curl "${curl_args[@]}" "$url"; then
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