#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/cursor.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Cursor.
#
# Dependencies:
#   - json_response.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
# ==============================================================================
# Custom checker for Cursor with direct curl calls
check_cursor() {
    local app_config_json="$1" # Now receives JSON string

    # Generate cache key and cache all fields at once
    local cache_key
    local _hash
    _hash="$(hash_utils::generate_hash "$app_config_json")"
    cache_key="cursor_${_hash}"
    systems::cache_json_fields "$app_config_json" "$cache_key"
    # Retrieve all required fields from cache
    local name install_path_config app_key
    name=$(systems::get_cached_json_value "$cache_key" "name")
    install_path_config=$(systems::get_cached_json_value "$cache_key" "install_path")
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")
    if [[ -z "$name" || -z "$app_key" ]]; then
        json_response::emit_error "PARSING_ERROR" "Missing 'name' or 'app_key' in config JSON." "${name:-cursor}"
        return 1
    fi
    # Resolve install path
    local appimage_filename_final="cursor.AppImage"
    local original_home="${ORIGINAL_HOME:-$HOME}"
    local install_base_dir="${install_path_config}"
    # Expand $HOME, ${HOME}, and leading ~
    install_base_dir="${install_base_dir//\$HOME/$original_home}"
    install_base_dir="${install_base_dir//\$\{HOME\}/$original_home}"
    [[ "$install_base_dir" == "~"* ]] && install_base_dir="${install_base_dir/#\~/$original_home}"
    # Default to home if empty and ensure directory exists
    [[ -z "$install_base_dir" ]] && install_base_dir="$original_home"
    mkdir -p -- "$install_base_dir" || {
        json_response::emit_error "FILESYSTEM_ERROR" "Unable to create install directory '$install_base_dir'." "$name"
        return 1
    }
    local appimage_file_path="${install_base_dir%/}/${appimage_filename_final}"
    # Get installed version
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    # Fetch API JSON
    local api_endpoint="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
    local api_json_path
    if ! api_json_path=$(networks::fetch_cached_or_error "$api_endpoint" "json" "$name" "Failed to fetch Cursor API JSON for $name."); then
        return 1
    fi

    # Extract required fields
    local actual_download_url latest_version
    actual_download_url=$(systems::get_json_value "$api_json_path" '.downloadUrl // empty')
    latest_version=$(systems::get_json_value "$api_json_path" '.version // empty')

    # Validate required fields
    if [[ -z "$actual_download_url" ]] || [[ -z "$latest_version" ]]; then
        local -a missing_keys=()
        [[ -z "$actual_download_url" ]] && missing_keys+=("downloadUrl")
        [[ -z "$latest_version" ]] && missing_keys+=("version")

        local missing_joined
        if ((${#missing_keys[@]})); then
            IFS=',' read -r -a _tmp <<< "${missing_keys[*]}"
            missing_joined=$(
                IFS=','
                echo "${missing_keys[*]}"
            )
        else
            missing_joined="unknown"
        fi

        json_response::emit_error "PARSING_ERROR" "Missing required field(s) [${missing_joined}] for $name (empty or absent in API JSON)." "$name"
        return 1
    fi
    # Log debug info
    latest_version=$(versions::strip_version_prefix "$latest_version")

    # Validate download URL
    local resolved_url=""
    if ! resolved_url=$(networks::resolve_and_validate_url "$actual_download_url"); then
        json_response::emit_error "NETWORK_ERROR" "Invalid or unresolved download URL for $name (url=$actual_download_url)." "$name"
        return 1
    fi

    # Log debug info
    loggers::log_message "DEBUG" "CURSOR: installed_version='$installed_version' latest_version='$latest_version' url='$resolved_url'"

    # Determine status and emit response
    local output_status
    output_status=$(json_response::determine_status "$installed_version" "$latest_version")

    json_response::emit_success "$output_status" "$latest_version" "appimage" "Official API (JSON)" \
        download_url "$resolved_url" \
        install_target_path "$appimage_file_path" \
        app_key "$app_key"

    return 0
}
