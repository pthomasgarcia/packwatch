#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/script.sh
# ==============================================================================
# Responsibilities:
#   - Manages updates for applications installed via executable scripts.
# ==============================================================================

# SECTION: Script-based Update Flow

updates::process_script_installation() {
    # Arity validation: expect exactly 3 parameters (config ref name, latest_version, download_url)
    if [[ $# -ne 3 ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid number of parameters for script update flow (expected 3, got $#)" "unknown"
        updates::trigger_hooks ERROR_HOOKS "unknown" '{"phase": "script_process", "error_type": "VALIDATION_ERROR", "message": "Invalid number of parameters for script update flow."}'
        return 1
    fi
    local -n app_config_ref=$1 # Now accepts app_config_ref directly
    local latest_version="$2"
    local download_url="$3"

    local app_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}" # Get from config

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url" || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for script update flow (version, URL, or app_key missing)" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"script_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Invalid parameters for script update flow.\"}"
        return 1
    fi

    local temp_script_path
    local base_filename_for_tmp
    base_filename_for_tmp="$(basename "$download_url" | cut -d'?' -f1 | sed 's/\.sh$//')"
    base_filename_for_tmp=$(systems::sanitize_filename "$base_filename_for_tmp")
    if ! temp_script_path=$(systems::create_temp_file "${base_filename_for_tmp}"); then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file for script: '${base_filename_for_tmp}'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"script_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Failed to create temporary file.\"}"
        return 1
    fi
    TEMP_FILES+=("$temp_script_path")

    # Attempt to obtain expected download size via HEAD request
    local download_size="unknown"
    if networks::require_https_or_fail "$download_url" "$allow_http"; then
        local head_output
        # Reuse network timeout config if available; fallback sensible defaults
        local timeout_val="${NETWORK_CONFIG[TIMEOUT]:-10}"
        if head_output=$(curl -s -I -L -A "$(networks::_user_agent)" \
            --connect-timeout "$timeout_val" \
            --max-time "$((timeout_val * 2))" \
            "$download_url" 2> /dev/null); then
            local cl
            cl=$(printf '%s\n' "$head_output" | awk -F': ' 'tolower($1)=="content-length"{val=$2} END {gsub(/\r/,"",val); if(val ~ /^[0-9]+$/) print val}')
            if [[ -n "$cl" ]]; then
                download_size="$cl"
            fi
        fi
    fi

    updates::on_download_start "$app_name" "$download_size"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_script_path" "$download_size" "" "$allow_http"; then # Pass size for implementations that support it
        errors::handle_error "NETWORK_ERROR" "Failed to download script" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download script.\"}"
        return 1
    fi
    updates::on_download_complete "$app_name" "$temp_script_path" # Hook

    # Perform verification after download
    if ! verifiers::verify_artifact app_config_ref "$temp_script_path" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded script: '$app_name'." "$app_name"
        return 1
    fi

    if ! chmod +x "$temp_script_path"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to make script executable: '$temp_script_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to make script executable.\"}"
        return 1
    fi

    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "sudo" \
        "bash" \
        "$temp_script_path"
}

# Fetch version from direct URL with regex
updates::_fetch_version_from_url() {
    local version_url="$1"
    local version_regex="$2"
    local app_name="$3"

    local latest_version="0.0.0"
    local api_response_file # This will now be a file path
    if api_response_file=$(networks::fetch_cached_data "$version_url" "json") && [[ -f "$api_response_file" ]]; then
        local parsed_version
        if parsed_version=$(versions::extract_from_json "$api_response_file" ".tag_name" "$app_name"); then
            latest_version="$parsed_version"
        else
            # If JSON extraction fails, try regex from the file content
            local file_content
            file_content=$(cat "$api_response_file")
            if parsed_version=$(versions::extract_from_regex "$file_content" "$version_regex" "$app_name"); then
                latest_version="$parsed_version"
            else
                loggers::log_message "WARN" "Could not extract version from '$version_url' for '$app_name' using JSON or regex. Defaulting to 0.0.0."
            fi
        fi
    fi

    echo "$latest_version"
    return 0
}

# Updates module; checks for updates for a script-based application.
updates::check_script() {
    # Arity validation: expect exactly 1 parameter (config ref name)
    if [[ $# -ne 1 ]]; then
        errors::handle_error "CONFIG_ERROR" "Invalid number of parameters for script check flow (expected 1, got $#)" "unknown"
        updates::trigger_hooks ERROR_HOOKS "unknown" '{"phase": "check", "error_type": "CONFIG_ERROR", "message": "Invalid number of parameters for script check flow."}'
        interfaces::print_ui_line "  " "✗ " "Invalid invocation for script check (expected 1 argument)." "${COLOR_RED}"
        return 1
    fi
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local version_url="${app_config_ref[version_url]}"
    local version_regex="${app_config_ref[version_regex]}"
    local source="Script Download"

    # Configuration validation (same as before)
    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid download URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid download URL configured." "${COLOR_RED}"
        return 1
    fi
    if ! validators::check_url_format "$version_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid version URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid version URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid version URL configured." "${COLOR_RED}"
        return 1
    fi
    if [[ -z "$version_regex" ]]; then
        errors::handle_error "CONFIG_ERROR" "Missing version regex in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Missing version regex configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Missing version regex configured." "${COLOR_RED}"
        return 1
    fi

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    # Use the new helper function
    local latest_version
    latest_version=$(updates::_fetch_version_from_url "$version_url" "$version_regex" "$name")

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_script_installation \
            app_config_ref \
            "${latest_version}" \
            "${download_url}"
    else
        updates::handle_up_to_date
    fi

    return 0
}
