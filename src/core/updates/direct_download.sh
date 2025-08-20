#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/direct_download.sh
# ==============================================================================
# Responsibilities:
#   - Manages the update process for applications installed via direct file downloads.
# ==============================================================================

# Updates module; checks for updates for a direct download application.
updates::check_direct_download() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}"
    local package_name="${app_config_ref[package_name]:-}" # Optional, for display or specific installers

    # Fast-fail validation of required fields
    local missing_keys=()
    [[ -z "$name" ]] && missing_keys+=(name)
    [[ -z "$app_key" ]] && missing_keys+=(app_key)
    [[ -z "$download_url" ]] && missing_keys+=(download_url)
    if ((${#missing_keys[@]} > 0)); then
        local joined_missing
        joined_missing=$(
            IFS=,
            echo "${missing_keys[*]}"
        )
        errors::handle_error "CONFIG_ERROR" "Missing required direct_download config field(s): $joined_missing" "${app_key:-unknown}"
        updates::trigger_hooks "ERROR_HOOKS" "${name:-unknown}" "{\"phase\":\"config_validation\",\"error_type\":\"CONFIG_ERROR\",\"message\":\"Missing required field(s): $joined_missing\"}"
        interfaces::print_ui_line "  " "✗ " "Configuration error: missing field(s): $joined_missing" "${COLOR_RED}"
        return 1
    fi

    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    local temp_download_dir
    temp_download_dir=$(systems::create_temp_dir) || return 1
    systems::register_temp_file "$temp_download_dir"

    local filename
    # Derive a safe filename from the download URL:
    #  1. Strip any query string or fragment (everything after first ? or #)
    #  2. Take the basename of the cleaned URL
    #  3. Sanitize to remove shell-unsafe characters (keep . _ - alnum)
    #  4. Provide a fallback if the result is empty
    local cleaned_url
    cleaned_url="${download_url%%[?#]*}" # Remove query/fragment
    local raw_filename
    raw_filename="$(basename "$cleaned_url")"
    filename="$(systems::sanitize_filename "$raw_filename")"
    if [[ -z "$filename" ]]; then
        # Fallback: use app_key or generic name
        filename="$(systems::sanitize_filename "${app_key:-download}")"
    fi
    local temp_download_file="${temp_download_dir}/${filename}"

    # Early version extraction from filename to potentially skip unnecessary download
    local latest_version="0.0.0" early_latest_extracted=0
    if early_latest=$(versions::extract_from_regex "$filename" "FILENAME_REGEX" "$name" 2> /dev/null); then
        latest_version=$(versions::normalize "$early_latest")
        early_latest_extracted=1
        # Decide if update needed before downloading
        if ! updates::is_needed "$installed_version" "$latest_version"; then
            loggers::log_message "INFO" "Skipping download for '$name'; installed version '$installed_version' is up-to-date against '$latest_version'."
            interfaces::print_ui_line "  " "✓ " "Already up-to-date." "${COLOR_GREEN}"
            updates::on_install_skipped "$name"
            counters::inc_skipped
            return 0
        fi
    fi

    updates::on_download_start "$name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_download_file" "" "" "$allow_http"; then # DI applied, added allow_http
        errors::handle_error "NETWORK_ERROR" "Failed to download file from '$download_url'" "$name"
        updates::trigger_hooks "ERROR_HOOKS" "$name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download file.\"}"
        return 1
    fi

    if ! verifiers::verify_artifact app_config_ref "$temp_download_file" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded artifact: '$name'." "$name"
        updates::trigger_hooks "ERROR_HOOKS" "$name" "{\"phase\": \"download\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Verification failed for downloaded artifact.\"}"
        return 1
    fi

    # Fallback extraction only if not already done early
    if [[ $early_latest_extracted -eq 0 ]]; then
        if ! latest_version=$(versions::extract_from_regex "$filename" "FILENAME_REGEX" "$name"); then
            loggers::log_message "WARN" "Could not extract version from download URL filename for '$name'. Will default to 0.0.0 for comparison."
            latest_version="0.0.0"
        fi
    fi

    # Standardized summary output
    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "Direct Download"

    local needs_update=0
    if updates::is_needed "$installed_version" "$latest_version"; then
        needs_update=1
    elif versions::compare_strings "$latest_version" "$installed_version" -eq 0; then
        # Versions are the same, and primary verification is done via verifiers::verify_artifact.
        # If we reach here, it means the artifact was downloaded and verified, but the version
        # is not newer. This implies a re-installation might be needed if the user wants to
        # ensure integrity or if the local file was corrupted/deleted.
        loggers::log_message "INFO" "Downloaded version '$latest_version' is not newer than installed '$installed_version' for '$name'. Skipping re-installation."
        interfaces::print_ui_line "  " "✓ " "Already up-to-date." "${COLOR_GREEN}"
        updates::on_install_skipped "$name" # Treat as skipped if no update needed
        counters::inc_skipped
        return 0
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        # Determine artifact type using filename patterns to handle multi-part extensions
        local artifact_type=""
        if [[ "$filename" == *.tar.gz ]]; then
            artifact_type="tar.gz"
        elif [[ "$filename" == *.tgz ]]; then
            artifact_type="tgz"
        elif [[ "$filename" == *.deb ]]; then
            artifact_type="deb"
        elif [[ "$filename" == *.AppImage || "$filename" == *.appimage ]]; then
            artifact_type="AppImage"
        else
            artifact_type="${filename##*.}"
        fi

        case "$artifact_type" in
            deb)
                updates::process_installation \
                    "$name" \
                    "$app_key" \
                    "$latest_version" \
                    "packages::install_deb_package" \
                    "$temp_download_file" \
                    "${package_name:-$name}" \
                    "$latest_version" \
                    "$app_key"
                ;;
            tgz | tar.gz)
                local binary_name="${package_name:-$(echo "$app_key" | tr '[:upper:]' '[:lower:]')}"
                updates::process_installation \
                    "$name" \
                    "$app_key" \
                    "$latest_version" \
                    "packages::install_tgz_package" \
                    "$temp_download_file" \
                    "$name" \
                    "$latest_version" \
                    "$app_key" \
                    "$binary_name"
                ;;
            AppImage)
                local install_target_full_path="${app_config_ref[install_path]:-$HOME/Applications/${name}.AppImage}"
                updates::process_installation \
                    "$name" \
                    "$app_key" \
                    "$latest_version" \
                    "updates::_install_appimage_file_command" \
                    "$temp_download_file" \
                    "$install_target_full_path" \
                    "$name"
                ;;
            *)
                errors::handle_error "INSTALLATION_ERROR" "Unsupported file type for direct download: .$artifact_type" "$name"
                updates::trigger_hooks "ERROR_HOOKS" "$name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Unsupported file type for direct download.\"}"
                return 1
                ;;
        esac
    else
        updates::handle_up_to_date
    fi
}
