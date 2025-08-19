#!/usr/bin/env bash
# ==============================================================================
# MODULE: util/checker_utils.sh
# ==============================================================================
# Responsibilities:
#   - Minimal utilities for custom checkers.
#
# Dependencies:
#   - updates.sh
#   - loggers.sh
#   - packages.sh
#   - errors.sh
#   - networks.sh
#   - validators.sh
#   - systems.sh
#   - jq (at runtime for emit_* helpers)
# ==============================================================================

# ------------------------------------------------------------------------------
# Status computation
# ------------------------------------------------------------------------------

checker_utils::determine_status() {
    local installed_version="$1"
    local latest_version="$2"

    if ! updates::is_needed "$installed_version" "$latest_version"; then
        echo "no_update"
    else
        echo "success"
    fi
}

# ------------------------------------------------------------------------------
# Version normalization
# ------------------------------------------------------------------------------

# Normalize common version prefixes to compare versions reliably.
# Handles leading whitespace, path-like prefixes (e.g., refs/tags/),
# and textual prefixes like v, version, ver, release, stable.
checker_utils::strip_version_prefix() {
    local version="$1"

    # Trim leading/trailing whitespace
    version="${version#"${version%%[![:space:]]*}"}"
    version="${version%"${version##*[![:space:]]}"}"

    # Drop common path-like refs (e.g., refs/tags/, releases/)
    version=$(printf '%s' "$version" | sed -E 's#^(refs/tags/|tags/|releases?/)+##I')

    # Drop common textual prefixes followed by separators
    version=$(printf '%s' "$version" | sed -E 's#^(v|version|ver|release|stable)[[:space:]_/:.-]*##I')

    echo "$version"
}

# ------------------------------------------------------------------------------
# Abstractions (1) logging, (2) installed version, (5) error JSON, (6) success JSON
# ------------------------------------------------------------------------------

# (1) Logging snippet (DEBUG)
checker_utils::debug() {
    local msg="$1"
    loggers::log_message "DEBUG" "$msg"
}

# (2) Installed version lookup by app_key
checker_utils::get_installed_version() {
    local app_key="$1"
    packages::get_installed_version "$app_key"
}

# (5) Uniform error JSON emission with centralized logging/notification.
# Usage: checker_utils::emit_error <ERROR_TYPE> <MESSAGE> [APP_NAME] [CUSTOM_ERROR_TYPE]
checker_utils::emit_error() {
    local error_type="$1"
    local error_message="$2"
    local app_name="${3:-unknown}"
    local custom_error_type="${4:-}"

    # Prefer centralized handler if available; otherwise log locally.
    if declare -F errors::handle_error >/dev/null 2>&1; then
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

# (6) Uniform success JSON emission.
# Usage: checker_utils::emit_success <STATUS> <LATEST_VERSION> <INSTALL_TYPE> <SOURCE> [key value]...
# Always includes: status, latest_version, install_type, source, error_type:"NONE"
checker_utils::emit_success() {
    local status="$1"
    local latest="$2"
    local install_type="$3"
    local source="$4"
    shift 4

    local jq_prog='{ "status": $status, "latest_version": $latest, "install_type": $install_type, "source": $source, "error_type": "NONE" }'
    local args=(--arg status "$status" --arg latest "$latest" --arg install_type "$install_type" --arg source "$source")

    # Append extra k/v pairs
    while (( "$#" >= 2 )); do
        local k="$1"; local v="$2"
        shift 2
        args+=(--arg "$k" "$v")
        jq_prog="$jq_prog + {\"$k\": (\$$k)}"
    done

    jq -n "${args[@]}" "$jq_prog"
}

# ------------------------------------------------------------------------------
# Fast network helpers (8) URL resolution/validation with small timeouts
# ------------------------------------------------------------------------------

# Internal: get timeout values (with env overrides)
checker_utils::__timeout_connect() { : "${PW_CONNECT_TIMEOUT:=1}"; echo "${PW_CONNECT_TIMEOUT}"; }
checker_utils::__timeout_max()     { : "${PW_MAX_TIME:=3}";        echo "${PW_MAX_TIME}"; }
checker_utils::__timeout_resolve() { : "${PW_RESOLVE_MAX_TIME:=4}"; echo "${PW_RESOLVE_MAX_TIME}"; }
checker_utils::__first_alive_wait(){ : "${PW_FIRST_ALIVE_WAIT:=3}"; echo "${PW_FIRST_ALIVE_WAIT}"; }

# Decode URL percent-encoding (noop if already decoded)
checker_utils::decode_url() {
    local url="$1"
    networks::decode_url "$url"
}

# Validate URL format using validators.sh
checker_utils::validate_url() {
    local url="$1"
    validators::check_url_format "$url"
}

# Return HTTP status from a quick HEAD probe (no redirects). Empty on failure.
checker_utils::fast_head_status() {
    local url="$1"
    local ct mt
    ct=$(checker_utils::__timeout_connect)
    mt=$(checker_utils::__timeout_max)
    curl -sS -o /dev/null -I \
         --connect-timeout "$ct" --max-time "$mt" \
         -w '%{http_code}' "$url" 2>/dev/null || true
}

# Boolean: quick existence check (2xx/3xx considered alive)
checker_utils::fast_url_exists() {
    local url="$1"
    local code
    code=$(checker_utils::fast_head_status "$url")
    [[ -n "$code" && "$code" -ge 200 && "$code" -lt 400 ]]
}

# Follow redirects quickly and return the effective URL (limited time/redirs)
checker_utils::fast_resolve_url() {
    local url="$1"
    local ct rt
    ct=$(checker_utils::__timeout_connect)
    rt=$(checker_utils::__timeout_resolve)
    # Use HEAD with -L and capture final effective URL
    curl -sS -I -L --max-redirs 5 \
         --connect-timeout "$ct" --max-time "$rt" \
         -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null || true
}

# Resolve + validate with fast paths; fall back to networks::get_effective_url if needed.
checker_utils::resolve_and_validate_url() {
    local raw="$1"

    # Preliminary validation on raw and decoded
    local decoded
    decoded=$(checker_utils::decode_url "$raw")

    if ! checker_utils::validate_url "$decoded"; then
        return 1
    fi

    # Quick probe
    local code
    code=$(checker_utils::fast_head_status "$decoded")

    # 2xx: good as-is
    if [[ -n "$code" && "$code" -ge 200 && "$code" -lt 300 ]]; then
        printf '%s' "$decoded"
        return 0
    fi

    # 3xx or unknown: try fast resolve
    local fast_resolved
    fast_resolved=$(checker_utils::fast_resolve_url "$decoded")
    if [[ -n "$fast_resolved" ]] && checker_utils::validate_url "$fast_resolved"; then
        # Confirm it exists quickly; if not, still return the resolved (some servers block HEAD)
        if checker_utils::fast_url_exists "$fast_resolved"; then
            printf '%s' "$fast_resolved"
            return 0
        fi
        printf '%s' "$fast_resolved"
        return 0
    fi

    # Fallback to networks::get_effective_url (may be slower)
    local resolved
    resolved=$(networks::get_effective_url "$decoded" 2>/dev/null || true)
    if [[ -n "$resolved" ]] && checker_utils::validate_url "$resolved"; then
        printf '%s' "$resolved"
        return 0
    fi

    return 1
}

# Try multiple URLs and return the first that responds (2xx/3xx) within a short window.
# Usage: checker_utils::first_alive_url <url1> <url2> ...
checker_utils::first_alive_url() {
    local urls=("$@")
    (( ${#urls[@]} )) || return 1

    # Run quick sequential probes with tiny timeouts to avoid job-control complexity.
    local u
    for u in "${urls[@]}"; do
        if checker_utils::validate_url "$u" && checker_utils::fast_url_exists "$u"; then
            printf '%s' "$u"
            return 0
        fi
    done

    # As a last attempt, try fast resolve on each
    for u in "${urls[@]}"; do
        local r
        r=$(checker_utils::fast_resolve_url "$u")
        if [[ -n "$r" ]] && checker_utils::validate_url "$r"; then
            printf '%s' "$r"
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------------------------
# Network fetch + parse scaffold (9)
# ------------------------------------------------------------------------------

# Fetch a URL with caching; on failure emits uniform error JSON and returns non-zero.
# Usage: checker_utils::fetch_cached_or_error <URL> <TYPE> <APP_NAME> [FAIL_MSG]
checker_utils::fetch_cached_or_error() {
    local url="$1" type="$2" app="$3" fail_msg="${4:-Failed to fetch $type from $url}"
    local path
    if ! path=$(networks::fetch_cached_data "$url" "$type"); then
        checker_utils::emit_error "NETWORK_ERROR" "$fail_msg" "$app" >/dev/null
        return 1
    fi
    printf '%s' "$path"
}

# Load cached file content; on failure emits uniform error JSON and returns non-zero.
# Usage: checker_utils::load_cached_content_or_error <PATH> <APP_NAME> [FAIL_MSG]
checker_utils::load_cached_content_or_error() {
    local path="$1" app="$2" fail_msg="${3:-Cached file missing or unreadable: $path}"
    if [[ ! -f "$path" ]]; then
        checker_utils::emit_error "NETWORK_ERROR" "$fail_msg" "$app" >/dev/null
        return 1
    fi
    cat "$path"
}

# Convenience: fetch -> load content; echoes content on success.
# Usage: checker_utils::fetch_and_load <URL> <TYPE> <APP_NAME> [FAIL_MSG]
checker_utils::fetch_and_load() {
    local url="$1" type="$2" app="$3" msg="${4:-}"
    local path
    if ! path=$(checker_utils::fetch_cached_or_error "$url" "$type" "$app" "$msg"); then
        return 1
    fi
    checker_utils::load_cached_content_or_error "$path" "$app" "$msg"
}

# Run a CLI with retry using systems::reattempt_command; echo stdout or emit error JSON.
# Usage: checker_utils::cli_with_retry_or_error <RETRIES> <SLEEP> <APP_NAME> <FAIL_MSG> -- <cmd> [args...]
checker_utils::cli_with_retry_or_error() {
    local retries="$1" sleep_secs="$2" app="$3" fail_msg="$4"
    shift 4
    # Optional "--" delimiter support
    [[ "$1" == "--" ]] && shift
    local output
    if ! output=$(systems::reattempt_command "$retries" "$sleep_secs" "$@" 2>/dev/null); then
        checker_utils::emit_error "NETWORK_ERROR" "$fail_msg" "$app" >/dev/null
        return 1
    fi
    printf '%s' "$output"
}

# Extract the value of a "Key: Value" line from given text; echoes the trimmed value.
# Usage: checker_utils::extract_colon_value "<TEXT>" "<KEY_REGEX>"
checker_utils::extract_colon_value() {
    local text="$1" key_re="$2"
    awk -F: -v key_re="$key_re" '
        {
          k=$1
          gsub(/^[ \t]+|[ \t]+$/, "", k)
          if (k ~ key_re) {
             v=$2
             sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
             print v
             exit
          }
        }' <<<"$text" | xargs
}
