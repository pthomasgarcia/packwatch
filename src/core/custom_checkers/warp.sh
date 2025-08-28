#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp.
#
# Dependencies:
#   - json_response.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# Custom checker for Warp with direct curl calls
check_warp() {
    local app_config_json="$1" # Now receives JSON string

    # Generate cache key and cache all fields at once
    local cache_key
    local _hash
    _hash="$(hash_utils::generate_hash "$app_config_json")"
    cache_key="warp_${_hash}"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Retrieve all required fields from cache
    local name app_key
    name=$(systems::get_cached_json_value "$cache_key" "name")
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")

    if [[ -z "$name" || -z "$app_key" ]]; then
        json_response::emit_error "CONFIG_ERROR" "Missing required fields: name/app_key." "${name:-warp}"
        return 1
    fi
    # Get installed version
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    # Fetch download page
    local url="https://app.warp.dev/get_warp?package=deb"
    local html_content
    if ! html_content=$(networks::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    # Extract latest version
    local latest_version_raw
    latest_version_raw=$(echo "$html_content" | grep -oP '[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.stable_[0-9]+' | head -1)
    loggers::log_message "DEBUG" "Extracted latest_version_raw for Warp: '$latest_version_raw'"

    local latest_version
    latest_version=$(versions::strip_version_prefix "$latest_version_raw")

    if [[ -z "$latest_version" ]]; then
        json_response::emit_error "PARSING_ERROR" "Failed to extract version for $name." "$name"
        return 1
    fi

    # Normalize installed version
    installed_version=$(versions::strip_version_prefix "$installed_version")

    # Resolve and validate download URL
    local actual_deb_url
    if ! actual_deb_url=$(networks::resolve_and_validate_url "https://app.warp.dev/download?package=deb"); then
        json_response::emit_error "NETWORK_ERROR" "Failed to resolve download URL for $name." "$name"
        return 1
    fi

    # Log debug info
    loggers::log_message "DEBUG" "WARP: installed_version='$installed_version' latest_version='$latest_version' url='$actual_deb_url'"

    # Determine status
    local output_status
    output_status=$(json_response::determine_status "$installed_version" "$latest_version")

    # Emit success response
    json_response::emit_success "$output_status" "$latest_version" "deb" "Official API" \
        download_url "$actual_deb_url"

    return 0
}
