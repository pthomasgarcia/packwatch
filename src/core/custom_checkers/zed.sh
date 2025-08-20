#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/zed.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Zed.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
# ==============================================================================

# Custom checker for Zed
check_zed() {
    local app_config_json="$1" # Now receives JSON string

    # Cache all fields at once to reduce jq process spawning
    local cache_key
    cache_key="zed_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Get all values from cache instead of multiple jq calls
    local name
    name=$(systems::get_cached_json_value "$cache_key" "name")
    local app_key
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")
    local flatpak_app_id
    flatpak_app_id=$(systems::get_cached_json_value "$cache_key" "flatpak_app_id")

    # Early guard: flatpak_app_id must be present for Flatpak-based checks
    if [[ -z "$flatpak_app_id" ]]; then
        checker_utils::emit_error "CONFIG_ERROR" "Missing required flatpak_app_id in config (cache_key=$cache_key) for $name. Set 'flatpak_app_id' to the Flathub application ID." "$name" > /dev/null
        return 1
    fi

    # Optional: some configs may provide a direct URL; if present, resolve+validate it.
    local configured_download_url=""
    configured_download_url=$(systems::get_cached_json_value "$cache_key" "download_url")
    if [[ -n "$configured_download_url" ]]; then
        local resolved_url
        if ! resolved_url=$(checker_utils::resolve_and_validate_url "$configured_download_url"); then
            checker_utils::emit_error "NETWORK_ERROR" "Invalid or unreachable download_url in config for $name." "$name"
            return 1
        fi
        checker_utils::debug "ZED: resolved config download_url -> $resolved_url"
        # We don't use this for installation (Flatpak), but we can surface it as an extra field.
        configured_download_url="$resolved_url"
    fi

    local installed_version
    installed_version=$(checker_utils::get_installed_version "$app_key")

    # (9) Use scaffolded CLI fetch + parse
    local flatpak_info
    flatpak_info=$(checker_utils::cli_with_retry_or_error 3 5 "$name" "Failed to retrieve flatpak info for $name." -- \
        flatpak remote-info flathub "$flatpak_app_id") || return 1

    local latest_version
    latest_version=$(checker_utils::extract_colon_value "$flatpak_info" "^Version$")

    if [[ -z "$latest_version" ]]; then
        checker_utils::emit_error "PARSING_ERROR" "Failed to parse latest version from flatpak info for $name." "$name"
        return 1
    fi

    # Normalize versions (strip prefixes like v, version, release, etc.)
    installed_version=$(checker_utils::strip_version_prefix "$installed_version")
    latest_version=$(checker_utils::strip_version_prefix "$latest_version")

    checker_utils::debug "ZED: installed_version='$installed_version' latest_version='$latest_version'"

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    if [[ -n "$configured_download_url" ]]; then
        checker_utils::emit_success "$output_status" "$latest_version" "flatpak" "Flathub" \
            flatpak_app_id "$flatpak_app_id" \
            download_url "$configured_download_url"
    else
        checker_utils::emit_success "$output_status" "$latest_version" "flatpak" "Flathub" \
            flatpak_app_id "$flatpak_app_id"
    fi

    return 0
}
