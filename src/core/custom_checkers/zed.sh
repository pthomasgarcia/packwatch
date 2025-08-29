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
# ==============================================================================

# Custom checker for Zed
check_zed() {
    local app_config_json="$1" # Now receives JSON string

    # Generate cache key and cache all fields at once
    local cache_key
    local _hash
    _hash="$(hashes::generate "$app_config_json")"
    cache_key="zed_${_hash}"
    systems::cache_json "$app_config_json" "$cache_key"

    # Retrieve all required fields from cache
    local name app_key flatpak_app_id
    name=$(systems::fetch_cached_json "$cache_key" "name")
    [[ "$name" == "null" ]] && name=""
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")
    [[ "$app_key" == "null" ]] && app_key=""
    flatpak_app_id=$(systems::fetch_cached_json "$cache_key" "flatpak_app_id")
    [[ "$flatpak_app_id" == "null" ]] && flatpak_app_id=""

    # Defaults and required-field guards
    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "CONFIG_ERROR" "Missing required fields: name/app_key." "${name:-zed}"
        return 1
    fi

    # Early guard: flatpak_app_id must be present for Flatpak-based checks
    if [[ -z "$flatpak_app_id" ]]; then
        responses::emit_error "CONFIG_ERROR" "Missing required flatpak_app_id in config (cache_key=$cache_key) for $name. Set 'flatpak_app_id' to the Flathub application ID." "$name"
        return 1
    fi

    # Optional: some configs may provide a direct URL; if present, resolve+validate it.
    local configured_download_url=""
    configured_download_url=$(systems::fetch_cached_json "$cache_key" "download_url")
    if [[ -n "$configured_download_url" ]]; then
        local resolved_url
        if ! resolved_url=$(networks::validate_url "$configured_download_url"); then
            responses::emit_error "NETWORK_ERROR" "Invalid or unreachable download_url in config for $name." "$name"
            return 1
        fi
        loggers::log_message "DEBUG" "ZED: resolved config download_url -> $resolved_url"
        # We don't use this for installation (Flatpak), but we can surface it as an extra field.
        configured_download_url="$resolved_url"
    fi

    # Get installed version (defensive: don't propagate errors)
    local installed_version=""
    local _iv_rc=0
    installed_version=$(packages::fetch_version "$app_key" 2> /dev/null) || _iv_rc=$?
    if ((_iv_rc != 0)); then
        # Leave installed_version empty; downstream logic will handle it
        loggers::log_message "DEBUG" "ZED: get_installed_version failed for app_key='$app_key' (rc=${_iv_rc}); proceeding with empty installed_version"
        installed_version=""
    fi

    # Fetch flatpak info
    local flatpak_info
    flatpak_info=$(systems::cli_with_retry_or_error 3 5 "$name" "Failed to retrieve flatpak info for $name." -- \
        flatpak remote-info flathub "$flatpak_app_id") || return 1

    # Extract latest version
    local latest_version
    latest_version=$(string_utils::extract_colon_value "$flatpak_info" "^Version$")

    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Failed to parse latest version from flatpak info for $name." "$name"
        return 1
    fi

    # Normalize versions
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    # Log debug info
    loggers::log_message "DEBUG" "ZED: installed_version='$installed_version' latest_version='$latest_version'"

    # Determine status
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    # Emit success response
    if [[ -n "$configured_download_url" ]]; then
        responses::emit_success "$output_status" "$latest_version" "flatpak" "Flathub" \
            flatpak_app_id "$flatpak_app_id" \
            download_url "$configured_download_url"
    else
        responses::emit_success "$output_status" "$latest_version" "flatpak" "Flathub" \
            flatpak_app_id "$flatpak_app_id"
    fi

    return 0
}
