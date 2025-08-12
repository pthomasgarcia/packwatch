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
    local cache_key="cursor_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Get all values from cache instead of multiple jq calls
    local name=$(systems::get_cached_json_value "$cache_key" "name")
    local install_path_config=$(systems::get_cached_json_value "$cache_key" "install_path")
    local app_key=$(systems::get_cached_json_value "$cache_key" "app_key")

    local appimage_filename_final="cursor.AppImage"
    local install_base_dir="${install_path_config//\$HOME/$ORIGINAL_HOME}"
    install_base_dir="${install_base_dir/#\~/$ORIGINAL_HOME}"
    local appimage_file_path="${install_base_dir}/${appimage_filename_final}"

    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    local api_endpoint="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
    local api_json_path # This will now be a file path
    if ! api_json_path=$(networks::fetch_cached_data "$api_endpoint" "json"); then
        jq -n \
            --arg status "error" \
            --arg error_message "Failed to fetch Cursor API JSON for $name." \
            --arg error_type "NETWORK_ERROR" \
            '{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
        return 1
    fi

    # Extract downloadUrl and version from JSON, passing the file path
    local actual_download_url
    actual_download_url=$(systems::get_json_value "$api_json_path" '.downloadUrl // empty')
    local latest_version
    latest_version=$(systems::get_json_value "$api_json_path" '.version // empty')

    if [[ -z "$actual_download_url" ]] || [[ -z "$latest_version" ]]; then
        jq -n \
            --arg status "error" \
            --arg error_message "Failed to extract version or download URL for $name." \
            --arg error_type "PARSING_ERROR" \
            '{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
        return 1
    fi

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    jq -n \
        --arg status "$output_status" \
        --arg latest_version "$latest_version" \
        --arg download_url "$actual_download_url" \
        --arg install_type "appimage" \
        --arg install_target_path "$appimage_file_path" \
        --arg source "Official API (JSON)" \
        --arg error_type "NONE" \
        '{
             "status": $status,
             "latest_version": $latest_version,
             "download_url": $download_url,
             "install_type": $install_type,
             "install_target_path": $install_target_path,
             "source": $source,
             "error_type": $error_type
           }'

    return 0
}
