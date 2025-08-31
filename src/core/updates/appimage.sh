#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/appimage.sh
# ==============================================================================
# Responsibilities:
#   - Encapsulates logic for AppImage updates and installations.
# ==============================================================================

updates::process_appimage_file() {
    local config_array_name="$1" # Name of the app config associative array
    local app_name="$2"
    local latest_version="$3"
    local download_url="$4"
    local install_target_full_path="$5"
    local app_key="$6"
    local expected_checksum="${7:-}"        # Direct checksum value (if any) derived from release metadata
    local checksum_algorithm="${8:-sha256}" # Hash algorithm (default sha256)
    local allow_http="${9:-0}"              # Allow insecure HTTP (0/1)

    # Bind nameref for verification / config-driven options
    local -n app_config_ref="$config_array_name"

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url" || [[ -z "$install_target_full_path" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for AppImage update flow (version, URL, install path, or app_key missing)" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"appimage_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Invalid parameters for AppImage update flow.\"}"
        return 1
    fi

    local temp_appimage_path
    local base_filename_for_tmp
    base_filename_for_tmp="$(basename "$install_target_full_path" | sed 's/\.AppImage$//')"
    base_filename_for_tmp=$(systems::sanitize_filename "$base_filename_for_tmp")
    if ! temp_appimage_path=$(systems::create_temp_file "${base_filename_for_tmp}"); then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: '${base_filename_for_tmp}'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"appimage_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Failed to create temporary file.\"}"
        return 1
    fi
    TEMP_FILES+=("$temp_appimage_path")
    # allow_http is provided as the 8th argument; do not override from config here.

    updates::on_download_start "$app_name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_appimage_path" "" "" "$allow_http"; then # DI applied, added allow_http
        errors::handle_error "NETWORK_ERROR" "Failed to download AppImage" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download AppImage.\"}"
        return 1
    fi
    updates::on_download_complete "$app_name" "$temp_appimage_path" # Hook

    # Perform verification after download
    if ! verifiers::verify_artifact "$config_array_name" "$temp_appimage_path" "$download_url" "$expected_checksum"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded AppImage: '$app_name'." "$app_name"
        return 1
    fi

    if ! chmod +x "$temp_appimage_path"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to make AppImage executable: '$temp_appimage_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to make AppImage executable.\"}"
        return 1
    fi

    # Use the generic process_installation function
    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "updates::_install_appimage_file_command" \
        "$temp_appimage_path" \
        "$install_target_full_path" \
        "$app_name"
}

# Helper function to encapsulate the AppImage installation command
updates::_install_appimage_file_command() {
    local temp_appimage_path="$1"
    local install_target_full_path="$2"
    local app_name="$3" # Passed from process_installation, but not used here directly

    local target_dir
    target_dir="$(dirname "$install_target_full_path")"
    if ! mkdir -p "$target_dir"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to create installation directory: '$target_dir'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to create installation directory.\"}"
        return 1
    fi

    # Remove existing file if present
    if [[ -f "$install_target_full_path" ]]; then
        if ! rm -f "$install_target_full_path"; then
            errors::handle_error "PERMISSION_ERROR" "Failed to remove existing AppImage: '$install_target_full_path'" "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to remove existing AppImage.\"}"
            return 1
        fi
    fi

    loggers::debug "Moving from '$temp_appimage_path' to '$install_target_full_path'"
    if mv "$temp_appimage_path" "$install_target_full_path"; then
        systems::unregister_temp_file "$temp_appimage_path"
        chmod +x "$install_target_full_path" || loggers::warn "Failed to make final AppImage executable: '$install_target_full_path'."
        if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &> /dev/null; then
            if [[ $(id -u) -eq 0 ]]; then
                chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$install_target_full_path" 2> /dev/null ||
                    loggers::warn "Failed to change ownership of '$install_target_full_path' to '$ORIGINAL_USER' (running as root)."
            else
                if ! systems::ensure_sudo_privileges "$app_name"; then
                    return 1
                fi
                if ! sudo -n chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$install_target_full_path" 2> /dev/null; then
                    loggers::warn "Skipping ownership change for '$install_target_full_path' (sudo failed or password required)."
                fi
            fi
        fi
        return 0
    else
        errors::handle_error "INSTALLATION_ERROR" "Failed to move new AppImage from '$temp_appimage_path' to '$install_target_full_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Failed to move new AppImage.\"}"
        return 1
    fi
}

# Updates module; checks for updates for an AppImage application.
updates::check_appimage() {
    local config_array_name="$1"
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local install_path="${app_config_ref[install_path]}"
    local github_repo_owner="${app_config_ref[repo_owner]:-}"
    local github_repo_name="${app_config_ref[repo_name]:-}"

    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid download URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid download URL configured." "${COLOR_RED}"
        return 1
    fi
    if ! validators::check_file_path "$install_path"; then
        errors::handle_error "CONFIG_ERROR" "Invalid install path in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid install path configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid install path configured." "${COLOR_RED}"
        return 1
    fi

    local resolved_install_base_dir="${install_path//\$HOME/$ORIGINAL_HOME}"
    resolved_install_base_dir="${resolved_install_base_dir/#\~/$ORIGINAL_HOME}"
    local appimage_file_path_current="${resolved_install_base_dir}/${name}.AppImage"

    local installed_version
    installed_version=$(versions::normalize "$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key")") # DI applied

    # Always show "Checking ..." at the start
    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    local latest_version=""
    local expected_checksum=""
    local checksum_algorithm="sha256"
    local source="Direct Download"

    # (Verbose logging of Source moved until after source detection logic.)

    if [[ -n "$github_repo_owner" ]] && [[ -n "$github_repo_name" ]]; then
        local api_response_file                                                                                        # This will now be a file path
        if api_response_file=$("$UPDATES_GET_LATEST_RELEASE_INFO_IMPL" "$github_repo_owner" "$github_repo_name"); then # DI applied
            local latest_release_json_path                                                                             # This will be the path to the JSON file
            if latest_release_json_path=$("$UPDATES_GET_JSON_VALUE_IMPL" "$api_response_file" '.[0]' "$name"); then    # DI applied
                if ! latest_version=$(repositories::parse_version_from_release "$latest_release_json_path" "$name"); then
                    loggers::warn "Failed to parse version from GitHub release for '$name'. Will try direct download URL."
                fi

                local filename_pattern_template
                filename_pattern_template="$(basename "$download_url" | cut -d'?' -f1)"
                expected_checksum=$(updates::_extract_release_checksum "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name" "app_config_ref")
                source="GitHub Releases"
            fi
        else
            loggers::warn "Failed to fetch GitHub latest release for '$name'. Will try direct download URL."
        fi
    fi

    # Verbose log lines: Installed & final Source after source resolution
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::info "Installed: $installed_version"
        loggers::info "Source:    $source"
    fi

    if [[ -z "$latest_version" ]]; then
        loggers::debug "Attempting to extract version from download URL filename: '$download_url'"
        local filename_from_url
        filename_from_url=$(basename "$download_url" | cut -d'?' -f1)
        if ! latest_version=$(versions::extract_from_regex "$filename_from_url" "FILENAME_REGEX" "$name"); then
            loggers::warn "Could not extract version from AppImage download URL filename for '$name'. Will default to 0.0.0 for comparison."
            latest_version="0.0.0"
        fi
    fi

    # Verbose log line: Latest after fetch
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::info "Latest:    $latest_version"
        loggers::output ""
    fi

    # Standardized summary output
    updates::print_version_info "$installed_version" "$source" "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_appimage_file \
            "$config_array_name" \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$app_key" \
            "${expected_checksum:-}" \
            "${app_config_ref[checksum_algorithm]:-sha256}" \
            "${app_config_ref[allow_insecure_http]:-0}"
    elif [[ "$installed_version" == "0.0.0" && "$latest_version" != "0.0.0" ]]; then
        interfaces::print_ui_line "  " "⬆ " "App not installed. Installing $latest_version." "${COLOR_YELLOW}"
        updates::process_appimage_file \
            "$config_array_name" \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$app_key" \
            "${expected_checksum:-}" \
            "${app_config_ref[checksum_algorithm]:-sha256}" \
            "${app_config_ref[allow_insecure_http]:-0}"
    else
        updates::handle_up_to_date
    fi

    return 0
}
