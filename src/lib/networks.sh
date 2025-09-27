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
#     networks::download_file "url" "/tmp/file"
#     networks::fetch_cached_data "url" "json"
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - systems.sh
#   - validators.sh
#   - interfaces.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Networking
# ------------------------------------------------------------------------------
# Ensure LAST_API_CALL is initialized to avoid arithmetic errors

# These variables are now loaded from configs.sh
# CACHE_DIR
# CACHE_DURATION
# NETWORK_CONFIG (associative array)

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
    local rate_limit_val="${NETWORK_CONFIG[RATE_LIMIT]:-1}"
    # Default to 1 if not set

    if ((time_diff < rate_limit_val)); then
        local sleep_duration=$((rate_limit_val - time_diff))
        loggers::debug "Rate limiting: sleeping for ${sleep_duration}s"
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
    local cache_file="${HOME}/.cache/packwatch/cache/$cache_key"
    local temp_download_file

    mkdir -p "${HOME}/.cache/packwatch/cache" || {
        errors::handle_error "PERMISSION_ERROR" \
            "Failed to create cache directory: '${HOME}/.cache/packwatch/cache'"
        return 1
    }

    # Check cache first
    local cache_duration_val="${CACHE_DURATION:-300}"
    # Use global CACHE_DURATION
    if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt "$cache_duration_val" ]]; then
        if [[ ${VERBOSE:-0} -eq 1 ]]; then
            loggers::debug "Using cached response for: '$url' (file: '$cache_file')"
        fi
        echo "$cache_file" # Return the path to the cached file
        return 0
    else
        networks::apply_rate_limit

        if ! temp_download_file=$(systems::create_temp_file "fetch_response"); then return 1; fi

        local -a curl_args
        mapfile -t curl_args < <(networks::build_curl_args \
            "$temp_download_file" "${NETWORK_CONFIG[TIMEOUT_MULTIPLIER]:-4}")
        # Use configurable timeout multiplier

        local max_retries_val="${NETWORK_CONFIG[MAX_RETRIES]:-3}"
        local retry_delay_val="${NETWORK_CONFIG[RETRY_DELAY]:-5}"
        if ! systems::reattempt_command "$max_retries_val" "$retry_delay_val" curl "${curl_args[@]}" "$url"; then
            errors::handle_error "NETWORK_ERROR" \
                "Failed to download '$url' after multiple attempts."
            systems::unregister_temp_file "$temp_download_file" # Clean up failed download
            return 1
        fi

        case "$expected_type" in
            "json")
                if ! jq . "$temp_download_file" > /dev/null 2>&1; then
                    errors::handle_error "VALIDATION_ERROR" \
                        "Fetched content for '$url' is not valid JSON."
                    systems::unregister_temp_file "$temp_download_file" # Clean up invalid content
                    return 1
                fi
                ;;
            "html")
                if ! grep -q '<html' "$temp_download_file" > /dev/null 2>&1 &&
                    ! grep -q '<!DOCTYPE html>' "$temp_download_file" > \
                        /dev/null 2>&1; then
                    loggers::warn "Fetched content for '$url' might not be \
valid HTML, but continuing."
                fi
                ;;
        esac

        mv -f "$temp_download_file" "$cache_file" || {
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to move temporary file '$temp_download_file' to cache \
'$cache_file' for '$url'"
            systems::unregister_temp_file "$temp_download_file" # Clean up if move fails
            return 1
        }
        systems::unregister_temp_file "$temp_download_file" # Unregister after successful move

        echo "$cache_file" # Return the path to the cached file
        return 0
    fi
}

# Enforce HTTPS unless explicitly allowed.
networks::require_https_or_fail() {
    local url="$1" allow_http="${2:-false}"
    if [[ "$allow_http" != "true" ]] && ! validators::check_https_url "$url"; then
        errors::handle_error "NETWORK_ERROR" "Refusing insecure URL: '$url'"
        return 1
    fi
}

# Download text content to a temporary file and return its path.
networks::download_text_to_cache() {
    local url="$1"
    networks::require_https_or_fail "$url" "${ALLOW_INSECURE_HTTP:-false}" || return 1

    local tmp
    tmp=$(systems::create_temp_file "sidecar") || return 1

    # Reuse download_file logic but suppress its UI output for silent operation
    if ! networks::download_file "$url" "$tmp" "" "" "${ALLOW_INSECURE_HTTP:-false}" > /dev/null 2>&1; then
        # Error is already handled by download_file, just need to clean up and fail
        systems::unregister_temp_file "$tmp"
        return 1
    fi
    echo "$tmp"
}

# Get the effective URL after redirects.
# Usage: networks::get_effective_url "url"
networks::get_effective_url() {
    local url="$1"
    local curl_output

    networks::apply_rate_limit

    # Use curl to get the effective URL after redirects, discarding content
    if ! curl_output=$(systems::reattempt_command \
        "${NETWORK_CONFIG[MAX_RETRIES]:-3}" \
        "${NETWORK_CONFIG[RETRY_DELAY]:-5}" curl -s -L \
        -H "User-Agent: $(networks::_user_agent)" \
        -o /dev/null \
        -w "%{url_effective}\n" \
        "$url"); then
        errors::handle_error "NETWORK_ERROR" \
            "Failed to get effective URL for '$url'."
        return 1
    fi

    local effective_url
    effective_url=$(echo "$curl_output" | tr -d '\r')
    if [[ -z "$effective_url" ]]; then
        errors::handle_error "NETWORK_ERROR" \
            "Failed to get effective URL for '$url'."
        return 1
    fi

    echo "$effective_url"
    return 0
}

# Return HTTP status from a quick HEAD probe (no redirects). Empty on failure.
# Uses PW_CONNECT_TIMEOUT and PW_MAX_TIME from globals.sh
networks::fast_head_status() {
    local url="$1"
    local ct="${PW_CONNECT_TIMEOUT}" # Now a global
    local mt="${PW_MAX_TIME}"        # Now a global
    curl -sS -o /dev/null -I \
        --connect-timeout "$ct" --max-time "$mt" \
        -w '%{http_code}' "$url" 2> /dev/null || true
}

# Boolean: quick existence check (2xx/3xx considered alive)
# Uses networks::fast_head_status
networks::fast_url_exists() {
    local url="$1"
    local code
    code=$(networks::fast_head_status "$url")
    [[ -n "$code" && "$code" -ge 200 && "$code" -lt 400 ]]
}

# Follow redirects quickly and return the effective URL (limited time/redirs)
# Uses PW_CONNECT_TIMEOUT and PW_RESOLVE_MAX_TIME from globals.sh
networks::fast_resolve_url() {
    local url="$1"
    local ct="${PW_CONNECT_TIMEOUT}"  # Now a global
    local rt="${PW_RESOLVE_MAX_TIME}" # Now a global
    # Use HEAD with -L and capture final effective URL
    curl -sS -I -L --max-redirs 5 \
        --connect-timeout "$ct" --max-time "$rt" \
        -o /dev/null -w '%{url_effective}' "$url" 2> /dev/null || true
}

# ------------------------------------------------------------------------------
# SECTION: File Downloading
# ------------------------------------------------------------------------------

# Download a file from a given URL.
# Usage: networks::download_file "url" "/tmp/file"
networks::download_file() {
    local url="$1"
    local dest_path="$2"
    # Checksum parameters are handled by the calling function (e.g., updates module)
    local allow_http="${5:-false}" # New parameter for allowing HTTP

    networks::require_https_or_fail "$url" "$allow_http" || return 1

    interfaces::print_ui_line "  " "→ " \
        "Downloading $(basename "$dest_path")..." >&2 # Redirect to stderr

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        interfaces::print_ui_line "    " "[DRY RUN] " \
            "Would download: '$url'" "${COLOR_YELLOW}" >&2 # Redirect to stderr
        return 0
    fi

    if [[ -z "$url" ]]; then
        errors::handle_error "NETWORK_ERROR" \
            "Download URL is empty for destination: '$dest_path'."
        return 1
    fi

    local -a curl_args
    mapfile -t curl_args < <(networks::build_curl_args "$dest_path" \
        "${NETWORK_CONFIG[TIMEOUT_MULTIPLIER]:-10}")
    # Use configurable timeout multiplier

    if ! systems::reattempt_command "${NETWORK_CONFIG[MAX_RETRIES]:-3}" "${NETWORK_CONFIG[RETRY_DELAY]:-5}" curl "${curl_args[@]}" "$url"; then
        errors::handle_error "NETWORK_ERROR" \
            "Failed to download '$url' after multiple attempts."
        return 1
    fi

    return 0
}

# Resolve + validate with fast paths; fall back to networks::get_effective_url if needed.
networks::validate_url() {
    local raw="$1"

    # Preliminary validation on raw and decoded
    local decoded
    decoded=$(networks::decode_url "$raw")

    if ! validators::check_url_format "$decoded"; then
        return 1
    fi

    # Quick probe
    local code
    code=$(networks::fast_head_status "$decoded")

    # 2xx: good as-is
    if [[ -n "$code" && "$code" -ge 200 && "$code" -lt 300 ]]; then
        printf '%s' "$decoded"
        return 0
    fi

    # 3xx or unknown: try fast resolve
    local fast_resolved
    fast_resolved=$(networks::fast_resolve_url "$decoded")
    if [[ -n "$fast_resolved" ]] && validators::check_url_format "$fast_resolved"; then
        # Confirm it exists quickly; if not, still return the resolved (some servers block HEAD)
        if networks::fast_url_exists "$fast_resolved"; then
            printf '%s' "$fast_resolved"
            return 0
        fi
        printf '%s' "$fast_resolved"
        return 0
    fi

    # Fallback to networks::get_effective_url (may be slower)
    local resolved
    resolved=$(networks::get_effective_url "$decoded" 2> /dev/null || true)
    if [[ -n "$resolved" ]] && validators::check_url_format "$resolved"; then
        printf '%s' "$resolved"
        return 0
    fi

    return 1
}

# Fetch a URL with caching; on failure emits uniform error JSON and returns non-zero.
# Usage: networks::fetch_cached_or_error <URL> <TYPE> <APP_NAME> [FAIL_MSG]
networks::fetch_cached_or_error() {
    local url="$1"
    local type="$2"
    local app="$3"
    local fail_msg="${4:-Failed to fetch $type from $url}"
    local path
    if ! path=$(networks::fetch_cached_data "$url" "$type"); then
        # Use responses::emit_error for consistency with custom checkers
        # This creates a dependency from networks.sh back to checker_utils.sh,
        # which is not ideal.
        # Ideally, emit_error would be in a more generic error handling
        # module.
        # For now, we'll keep the dependency for functional correctness.
        responses::emit_error "NETWORK_ERROR" "$fail_msg" "$app" > /dev/null
        return 1
    fi
    printf '%s' "$path"
}

# Load cached file content; on failure emits uniform error JSON and returns non-zero.
# Usage: networks::load_cached_content_or_error <PATH> <APP_NAME> [FAIL_MSG]
networks::load_cached_content_or_error() {
    local path="$1"
    local app="$2"
    local fail_msg="${3:-Cached file missing or unreadable: $path}"
    if [[ ! -f "$path" ]]; then
        # Use responses::emit_error for consistency with custom checkers
        responses::emit_error "CACHE_ERROR" "$fail_msg" "$app" > /dev/null
        return 1
    fi
    cat "$path"
}

# Convenience: fetch -> load content; echoes content on success.
# Usage: networks::fetch_and_load <URL> <TYPE> <APP_NAME> [FAIL_MSG]
networks::fetch_and_load() {
    local url="$1" type="$2" app="$3" msg="${4:-}"
    local path
    if ! path=$(networks::fetch_cached_or_error "$url" "$type" "$app" "$msg"); then
        return 1
    fi
    networks::load_cached_content_or_error "$path" "$app" "$msg"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
