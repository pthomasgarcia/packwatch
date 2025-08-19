#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/cursor.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Cursor.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
# ==============================================================================

# Custom checker for Cursor with direct curl calls
check_cursor() {
    local app_config_json="$1" # Now receives JSON string

    # Cache all fields at once to reduce jq process spawning
    local cache_key
    cache_key="cursor_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Get all values from cache instead of multiple jq calls
    local name
    name=$(systems::get_cached_json_value "$cache_key" "name")
    local install_path_config
    install_path_config=$(systems::get_cached_json_value "$cache_key" "install_path")
    local app_key
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")

    local appimage_filename_final="cursor.AppImage"
    local install_base_dir="${install_path_config//\$HOME/$ORIGINAL_HOME}"
    install_base_dir="${install_base_dir/#\~/$ORIGINAL_HOME}"
    local appimage_file_path="${install_base_dir}/${appimage_filename_final}"

    local installed_version
    installed_version=$(checker_utils::get_installed_version "$app_key")

    local api_endpoint="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
    local api_json_path
    if ! api_json_path=$(checker_utils::fetch_cached_or_error "$api_endpoint" "json" "$name" "Failed to fetch Cursor API JSON for $name."); then
        return 1
    fi

    # Extract downloadUrl and version from JSON, passing the file path
    local actual_download_url
    actual_download_url=$(systems::get_json_value "$api_json_path" '.downloadUrl // empty')
    local latest_version
    latest_version=$(systems::get_json_value "$api_json_path" '.version // empty')

    if [[ -z "$actual_download_url" ]] || [[ -z "$latest_version" ]]; then
        checker_utils::emit_error "PARSING_ERROR" "Failed to extract version or download URL for $name." "$name" >/dev/null
        return 1
    fi

    # Normalize versions (strip prefixes like v, version, release, etc.)
    installed_version=$(checker_utils::strip_version_prefix "$installed_version")
    latest_version=$(checker_utils::strip_version_prefix "$latest_version")

    # Resolve + validate the download URL
    local resolved_url
    if ! resolved_url=$(checker_utils::resolve_and_validate_url "$actual_download_url"); then
        checker_utils::emit_error "NETWORK_ERROR" "Invalid or unresolved download URL for $name." "$name" >/dev/null
        return 1
    fi

    checker_utils::debug "CURSOR: installed_version='$installed_version' latest_version='$latest_version' url='$resolved_url'"

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    checker_utils::emit_success "$output_status" "$latest_version" "appimage" "Official API (JSON)" \
        download_url "$resolved_url" \
        install_target_path "$appimage_file_path"

    return 0
}
