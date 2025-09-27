#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/zed.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Zed.
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

# Custom checker for Zed
zed::check() {
    local app_config_json="$1" # Now receives JSON string

    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        return 1
    fi

    local name="${app_info["name"]}"
    local app_key="${app_info["app_key"]}"
    local installed_version="${app_info["installed_version"]}"
    local cache_key="${app_info["cache_key"]}"

    local flatpak_app_id
    flatpak_app_id=$(systems::fetch_cached_json "$cache_key" "flatpak_app_id")
    # Early guard: flatpak_app_id must be present for Flatpak-based checks
    if validators::is_empty "$flatpak_app_id" || [[ "$flatpak_app_id" == "null" ]]; then
        responses::emit_error "CONFIG_ERROR" \
            "Missing required flatpak_app_id in config (cache_key=$cache_key) \
 for $name. Set 'flatpak_app_id' to the Flathub application ID." "$name"
        return 1
    fi

    local configured_download_url=""
    configured_download_url=$(systems::fetch_cached_json "$cache_key" "download_url")
    if ! validators::is_empty "$configured_download_url" && [[ "$configured_download_url" != "null" ]]; then
        local resolved_url
        if ! resolved_url=$(networks::validate_url \
            "$configured_download_url"); then
            responses::emit_error "NETWORK_ERROR" \
                "Invalid or unreachable download_url in config for $name." \
                "$name"
            return 1
        fi
        loggers::debug "ZED: resolved config download_url -> $resolved_url"
        configured_download_url="$resolved_url"
    else
        configured_download_url="" # Ensure it's empty if "null" or not set
    fi

    # Fetch flatpak info
    local flatpak_info
    flatpak_info=$(systems::cli_with_retry_or_error 3 5 "$name" \
        "Failed to retrieve flatpak info for $name." -- \
        flatpak remote-info flathub "$flatpak_app_id") || return 1

    # Extract latest version
    local latest_version
    latest_version=$(string_utils::extract_colon_value "$flatpak_info" "^Version$")

    if validators::is_empty "$latest_version"; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to parse latest version from flatpak info for $name." \
            "$name"
        return 1
    fi

    # Normalize versions
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    # Log debug info
    loggers::debug "ZED: installed_version='$installed_version' latest_version='$latest_version'"

    # Determine status
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    # Emit success response
    if ! validators::is_empty "$configured_download_url"; then
        responses::emit_success "$output_status" "$latest_version" \
            "flatpak" "Flathub" flatpak_app_id "$flatpak_app_id" \
            download_url "$configured_download_url"
    else
        responses::emit_success "$output_status" "$latest_version" \
            "flatpak" "Flathub" flatpak_app_id "$flatpak_app_id"
    fi

    return 0
}
