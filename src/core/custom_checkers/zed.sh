#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/zed.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Zed editor (via Flatpak).
#
# Dependencies:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - string_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
#   - configs.sh
# ==============================================================================

# Constants for internal use
readonly ZED_FLATPAK_REMOTE='flathub'             # Target repo name for flatpak remote-info queries
readonly ZED_VERSION_FIELD='^Version$'            # Field used to identify version in flatpak output
readonly ZED_FLATPAK_RETRY_COUNT=3                # Number of retry attempts on flatpak query failure
readonly ZED_FLATPAK_RETRY_DELAY=5                # Seconds between retry attempts

# Validate required input string is non-empty
# $1: String to validate
# $2: Descriptive name for logging
# Returns: Success if non-empty, else logs and returns 1
_zed::validate_input() {
    local input="$1"
    local input_name="$2"

    if [[ -z "$input" ]]; then
        loggers::debug "ZED: Required field \"$input_name\" is empty."
        return 1
    fi
    return 0
}

# Ensures that flatpak_app_id exists in config
# $1: App ID provided in config
# $2: Cached key for debugging
# $3: Display name
# Logs error and returns 1 if empty or invalid
_zed::validate_flatpak_app_id() {
    local flatpak_app_id="$1"
    local cache_key="$2"
    local name="$3"

    if validators::is_empty "$flatpak_app_id"; then
        responses::emit_error "CONFIG_ERROR" \
            "Missing flatpak_app_id. Expected Flathub identifier for $name (cache_key=$cache_key)." "$name" >&2
        return 1
    fi

    loggers::debug "ZED: Valid flatpak_app_id provided: $flatpak_app_id"
    return 0
}

# Resolves custom-configured download URL (if present)
# Treats missing download URL as non-fatal (returns "")
# $1: Download URL from config
# $2: Display name
# Returns: Resolved URL (non-empty) or empty if not defined
_zed::resolve_download_url() {
    local configured_url="$1"
    local name="$2"

    if validators::is_empty "$configured_url"; then
        printf ""
        return 0
    fi

    local resolved_url
    if ! resolved_url=$(networks::validate_url "$configured_url"); then
        responses::emit_error "NETWORK_ERROR" \
            "Invalid or unreachable download_url provided for $name." "$name" >&2
        return 1
    fi

    loggers::debug "ZED: Resolved download URL: $resolved_url"
    printf %s "$resolved_url"
}

# Query Flatpak remote info for the latest version info
# Uses retry on failure and logs preview if parse fails
# $1: Flatpak app ID (e.g. dev.zed.Zed)
# $2: Human-readable program name
# Returns: Parsed version string on success
_zed::get_latest_version_from_flatpak() {
    local flatpak_app_id="$1"
    local name="$2"

    # Execute CLI with retry wrapper
    local flatpak_info
    if ! flatpak_info=$(systems::cli_with_retry_or_error "$ZED_FLATPAK_RETRY_COUNT" "$ZED_FLATPAK_RETRY_DELAY" "$name" \
        "Failed to retrieve flatpak metadata." -- \
        flatpak remote-info "$ZED_FLATPAK_REMOTE" "$flatpak_app_id"); then
        return 1
    fi

    if ! _zed::validate_input "$flatpak_info" "flatpak_info"; then
        responses::emit_error "PARSING_ERROR" "Flatpak response body was unexpectedly empty." "$name" >&2
        return 1
    fi

    # Extract desired version line
    local latest_version
    latest_version=$(string_utils::extract_colon_value "$flatpak_info" "$ZED_VERSION_FIELD")

    if validators::is_empty "$latest_version"; then
        loggers::debug "ZED: Could not extract version from response. Preview: '$(echo "$flatpak_info" | head -c 200)'"
        responses::emit_error "PARSING_ERROR" "Failed locating 'Version:' field in flatpak manifest." "$name" >&2
        return 1
    fi

    # Success path
    loggers::debug "ZED: Detected latest version: $latest_version"
    printf %s "$latest_version"
}

# Emit final response in standard form based on outcome
# $1: Status code ("outdated", "no_update", etc.)
# $2: Detected latest version
# $3: Flathub app ID
# $4: Optional custom download URL
_zed::emit_response() {
    local output_status="$1"
    local latest_version="$2"
    local flatpak_app_id="$3"
    local download_url="$4"

    local -a args=(
        "$output_status" "$latest_version" "flatpak" "Flathub"
        flatpak_app_id "$flatpak_app_id"
    )

    if [[ -n "$download_url" ]]; then
        args+=(download_url "$download_url")
    fi

    responses::emit_success "${args[@]}"
}

# Main update checker for Zed editor
# Queries latest version via flatpak, compares with installed one, and emits JSON response
# $1: JSON-encoded app config including flatpak_app_id
zed::check() {
    local app_config_json="$1"

    # --------------------------------------------------------------------------
    # STEP 1: Load and validate base configuration
    # --------------------------------------------------------------------------
    if ! _zed::validate_input "$app_config_json" "app_config_json"; then
        responses::emit_error "CONFIG_ERROR" "Required configuration JSON not provided." "Zed"
        return 1
    fi

    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        responses::emit_error "CONFIG_ERROR" "Failed loading configuration for Zed." "Zed"
        return 1
    fi

    local name="${app_info['name']}"
    local app_key="${app_info['app_key']}"
    local installed_version="${app_info['installed_version']}"
    local cache_key="${app_info['cache_key']}"

    # --------------------------------------------------------------------------
    # STEP 2: Load and validate required fields (flatpak ID + optional custom DL)
    # --------------------------------------------------------------------------
    local flatpak_app_id
    flatpak_app_id=$(systems::fetch_cached_json "$cache_key" "flatpak_app_id")

    if ! _zed::validate_flatpak_app_id "$flatpak_app_id" "$cache_key" "$name"; then
        return 1
    fi

    local configured_download_url
    configured_download_url=$(systems::fetch_cached_json "$cache_key" "download_url")

    local resolved_download_url
    if ! resolved_download_url=$(_zed::resolve_download_url "$configured_download_url" "$name"); then
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 3: Fetch latest version from upstream (via flatpak remote-info)
    # --------------------------------------------------------------------------
    local latest_version
    if ! latest_version=$(_zed::get_latest_version_from_flatpak "$flatpak_app_id" "$name"); then
        return 1
    fi

    # Normalize version strings before comparison
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    loggers::debug "ZED: installed=$installed_version latest=$latest_version"

    # --------------------------------------------------------------------------
    # STEP 4: Compare versions and determine update status
    # --------------------------------------------------------------------------
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    if [[ "$output_status" == "no_update" ]]; then
        _zed::emit_response "$output_status" "$latest_version" "$flatpak_app_id" ""
        return 0
    fi

    # --------------------------------------------------------------------------
    # STEP 5: Emit full update info if newer version detected
    # --------------------------------------------------------------------------
    _zed::emit_response "$output_status" "$latest_version" "$flatpak_app_id" "$resolved_download_url"
    return 0
}
