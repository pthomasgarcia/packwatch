#!/usr/bin/env bash
# shellcheck disable=SC2034
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

    local latest_version
    local temp_download_file

    if ! "$UPDATER_UTILS_CHECK_AND_GET_VERSION_FROM_DOWNLOAD_IMPL" \
        app_config_ref \
        "versions::extract_from_regex" \
        latest_version \
        temp_download_file; then
        return 1
    fi

    # Standardized summary output
    updates::print_version_info "$installed_version" "Direct Download" "$latest_version"

    local needs_update=0
    if updates::is_needed "$installed_version" "$latest_version"; then
        needs_update=1
    elif versions::compare_strings "$latest_version" "$installed_version" -eq 0; then
        # Versions are the same, and primary verification is done via verifiers::verify_artifact.
        # If we reach here, it means the artifact was downloaded and verified, but the version
        # is not newer. This implies a re-installation might be needed if the user wants to
        # ensure integrity or if the local file was corrupted/deleted.
        loggers::info "Downloaded version '$latest_version' is not newer than installed '$installed_version' for '$name'. Skipping re-installation."
        interfaces::print_ui_line "  " "✓ " "Already up-to-date." "${COLOR_GREEN}"
        updates::on_install_skipped "$name" # Treat as skipped if no update needed
        counters::inc_skipped
        return 0
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        # Determine artifact type using filename patterns to handle multi-part extensions
        local filename
        filename=$(basename "$temp_download_file")
        local artifact_type
        artifact_type=$(web_parsers::detect_artifact_type "$filename")

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
                    "packages::install_archive" \
                    "$temp_download_file" \
                    "$name" \
                    "$latest_version" \
                    "$app_key" \
                    "$binary_name"
                ;;
            appimage)
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
