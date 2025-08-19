#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# Custom checker for Warp with direct curl calls
check_warp() {
    local app_config_json="$1" # Now receives JSON string

    # Cache all fields at once to reduce jq process spawning
    local cache_key
    cache_key="warp_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Get all values from cache instead of multiple jq calls
    local name
    name=$(systems::get_cached_json_value "$cache_key" "name")
    local app_key
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")

    local installed_version
    installed_version=$(checker_utils::get_installed_version "$app_key")

    local url="https://app.warp.dev/get_warp?package=deb"
    local html_content
    if ! html_content=$(checker_utils::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    local latest_version_raw
    latest_version_raw=$(echo "$html_content" | grep -oP '[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.stable_[0-9]+' | head -1)
    checker_utils::debug "Extracted latest_version_raw for Warp: '$latest_version_raw'"

    local latest_version
    latest_version=$(checker_utils::strip_version_prefix "$latest_version_raw")

    if [[ -z "$latest_version" ]]; then
        checker_utils::emit_error "PARSING_ERROR" "Failed to extract version for $name." "$name" >/dev/null
        return 1
    fi

    # Normalize installed version as well
    installed_version=$(checker_utils::strip_version_prefix "$installed_version")

    local actual_deb_url
    if ! actual_deb_url=$(checker_utils::resolve_and_validate_url "https://app.warp.dev/download?package=deb"); then
        checker_utils::emit_error "NETWORK_ERROR" "Failed to resolve download URL for $name." "$name" >/dev/null
        return 1
    fi

    checker_utils::debug "WARP: installed_version='$installed_version' latest_version='$latest_version' url='$actual_deb_url'"

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    checker_utils::emit_success "$output_status" "$latest_version" "deb" "Official API" \
        download_url "$actual_deb_url"

    return 0
}
