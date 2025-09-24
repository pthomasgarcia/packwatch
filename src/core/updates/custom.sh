#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/custom.sh
# ==============================================================================
# Responsibilities:
#   - Handles the dispatch and processing for custom update checkers.
# ==============================================================================

# Updates helper; handles the logic for a 'custom' application type.
# This function now passes a JSON string of the app configuration to the custom checker.
updates::handle_custom_check() {
    local config_array_name="$1"
    local -n app_config_ref=$config_array_name
    local app_display_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local installed_version
    if [[ -z "${UPDATES_GET_INSTALLED_VERSION_IMPL:-}" ]] || ! type -t "$UPDATES_GET_INSTALLED_VERSION_IMPL" &> /dev/null; then
        errors::handle_error "CONFIG_ERROR" "UPDATES_GET_INSTALLED_VERSION_IMPL is not set or not callable" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"check","error_type":"CONFIG_ERROR","message":"Missing or invalid UPDATES_GET_INSTALLED_VERSION_IMPL."}'
        return 1
    fi
    if ! installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key"); then # DI applied
        errors::handle_error "RUNTIME_ERROR" "Failed to obtain installed version" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"check","error_type":"RUNTIME_ERROR","message":"Failed to obtain installed version."}'
        return 1
    fi
    local custom_checker_script="${app_config_ref[custom_checker_script]}"
    if [[ -z "$custom_checker_script" ]]; then
        errors::handle_error "CONFIG_ERROR" "Missing 'custom_checker_script' for custom app type" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Missing custom_checker_script.\"}"
        interfaces::print_ui_line "  " "✗ " "Configuration error: Missing custom checker script." "${COLOR_RED}"
        return 1
    fi

    # Resolve custom checker script path:
    # - Absolute (/...), or relative (./, ../) paths are used as-is.
    # - Bare filenames are resolved inside CORE_DIR/custom_checkers.
    local script_path
    if [[ "$custom_checker_script" == /* || "$custom_checker_script" == ./* || "$custom_checker_script" == ../* ]]; then
        script_path="$custom_checker_script"
    else
        script_path="${CORE_DIR}/custom_checkers/${custom_checker_script}"
    fi

    # Optional normalization for cleaner error messages (best effort)
    if command -v realpath > /dev/null 2>&1; then
        script_path=$(realpath -m -- "$script_path" 2> /dev/null || echo "$script_path")
    elif command -v readlink > /dev/null 2>&1; then
        script_path=$(readlink -f -- "$script_path" 2> /dev/null || echo "$script_path")
    fi

    if [[ ! -r "$script_path" ]]; then
        errors::handle_error "CONFIG_ERROR" "Custom checker script not readable: '$script_path'" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\":\"check\",\"error_type\":\"CONFIG_ERROR\",\"message\":\"Custom checker script not readable: $script_path\"}"
        interfaces::print_ui_line "  " "✗ " "Custom checker script not found or unreadable: $script_path" "${COLOR_RED}"
        return 1
    fi

    # Export functions/vars used by custom checkers
    export -f loggers::debug loggers::info loggers::warn loggers::error interfaces::print_ui_line systems::fetch_json systems::require_json_value \
        systems::create_temp_file systems::unregister_temp_file systems::sanitize_filename systems::reattempt_command \
        errors::handle_error validators::check_url_format packages::fetch_version versions::is_newer
    export UPDATES_DOWNLOAD_FILE_IMPL UPDATES_GET_JSON_VALUE_IMPL UPDATES_PROMPT_CONFIRM_IMPL \
        UPDATES_GET_INSTALLED_VERSION_IMPL UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL \
        UPDATES_GET_LATEST_RELEASE_INFO_IMPL UPDATES_EXTRACT_DEB_VERSION_IMPL UPDATES_FLATPAK_SEARCH_IMPL
    export ORIGINAL_HOME ORIGINAL_USER VERBOSE DRY_RUN
    declare -p NETWORK_CONFIG > /dev/null 2>&1 && export NETWORK_CONFIG
    # shellcheck disable=SC2034 # `func` is used by `export -f`.
    while IFS= read -r func; do export -f func 2> /dev/null || true; done \
        < <(declare -F | awk '{print $3}' | grep -E '^(networks|packages|versions|validators|systems|updates)::')
    export -f verifiers::verify_artifact

    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$app_display_name${FORMAT_RESET} for latest version..."

    local custom_checker_output=""
    local custom_checker_func="${app_config_ref[custom_checker_func]}"

    # shellcheck disable=SC1090 # The script path is dynamic by design.
    source "$script_path" || {
        errors::handle_error "CONFIG_ERROR" "Failed to source custom checker script: '$script_path'" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Failed to source custom checker script.\"}"
        return 1
    }

    if [[ -z "$custom_checker_func" ]] || ! declare -F "$custom_checker_func" > /dev/null; then
        errors::handle_error "CONFIG_ERROR" "Custom checker function '$custom_checker_func' not found in script '$custom_checker_script'" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Custom checker function not found.\"}"
        return 1
    fi

    # Build JSON config for checker
    local app_config_json="{}"
    local key
    for key in "${!app_config_ref[@]}"; do
        if ! app_config_json=$(echo "$app_config_json" | jq --arg k "$key" --arg v "${app_config_ref[$key]}" '.[$k] = $v'); then
            errors::handle_error "RUNTIME_ERROR" "Failed to build app config JSON (jq error)" "$app_display_name"
            updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"check","error_type":"RUNTIME_ERROR","message":"Failed to build app config JSON."}'
            return 1
        fi
    done

    custom_checker_output=$("$custom_checker_func" "$app_config_json")
    if ! jq -e . > /dev/null 2>&1 <<< "$custom_checker_output"; then
        errors::handle_error "CUSTOM_CHECKER_ERROR" "Custom checker did not return valid JSON" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"check","error_type":"CUSTOM_CHECKER_ERROR","message":"Checker returned invalid JSON."}'
        interfaces::print_ui_line "  " "✗ " "Custom checker returned invalid JSON." "${COLOR_RED}"
        return 1
    fi

    local status latest_version source error_message error_type_from_checker content_length_from_output
    status=$(echo "$custom_checker_output" | jq -r '.status // "error"')
    latest_version=$(versions::normalize "$(echo "$custom_checker_output" | jq -r '.latest_version // "0.0.0"')")
    source=$(echo "$custom_checker_output" | jq -r '.source // "Unknown"')
    error_message=$(echo "$custom_checker_output" | jq -r '.error_message // empty')
    error_type_from_checker=$(echo "$custom_checker_output" | jq -r '.error_type // "CUSTOM_CHECKER_ERROR"')
    content_length_from_output=$(echo "$custom_checker_output" | jq -r '.content_length // empty') # New: Content-Length
    app_config_ref[content_length]="$content_length_from_output" # Store content_length in config map

    updates::print_version_info "$installed_version" "$source" "$latest_version"

    if [[ "$status" == "success" ]] && updates::is_needed "$installed_version" "$latest_version"; then
        local install_type
        install_type=$(echo "$custom_checker_output" | jq -r '.install_type // "unknown"')
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        case "$install_type" in
            "deb")
                local download_url_from_output expected_checksum_from_output
                download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
                expected_checksum_from_output=$(echo "$custom_checker_output" | jq -r '.expected_checksum // empty')

                if [[ -z "$download_url_from_output" || "$download_url_from_output" == "null" ]]; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Missing download_url for deb install type" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Missing download_url for deb."}'
                    interfaces::print_ui_line "  " "✗ " "Custom checker did not provide a deb download_url." "${COLOR_RED}"
                    return 1
                fi

                # Process DEB via packages module
                updates::process_installation \
                    "$app_display_name" \
                    "$app_key" \
                    "$latest_version" \
                    "packages::process_deb_package" \
                    "$config_array_name" \
                    "${app_config_ref[deb_filename_template]:-}" \
                    "$latest_version" \
                    "$download_url_from_output" \
                    "$expected_checksum_from_output" \
                    "$app_display_name"
                ;;
            "appimage")
                local download_url_from_output install_target_path_from_output
                download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
                install_target_path_from_output=$(echo "$custom_checker_output" | jq -r '.install_target_path')

                if [[ -z "$download_url_from_output" || "$download_url_from_output" == "null" ]]; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Missing download_url for appimage install type" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Missing download_url for appimage."}'
                    return 1
                fi
                if [[ -z "$install_target_path_from_output" || "$install_target_path_from_output" == "null" ]]; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Missing install_target_path for appimage install type" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Missing install_target_path for appimage."}'
                    return 1
                fi

                updates::process_appimage_file \
                    "$config_array_name" \
                    "${app_config_ref[name]}" \
                    "${latest_version}" \
                    "${download_url_from_output}" \
                    "${install_target_path_from_output}" \
                    "${app_config_ref[app_key]}" \
                    "${app_config_ref[checksum_url]:-}" \
                    "${app_config_ref[checksum_algorithm]:-sha256}" \
                    "${app_config_ref[allow_insecure_http]:-0}"
                ;;
            "flatpak")
                local flatpak_app_id_from_output
                flatpak_app_id_from_output=$(echo "$custom_checker_output" | jq -r '.flatpak_app_id')
                if [[ -z "$flatpak_app_id_from_output" || "$flatpak_app_id_from_output" == "null" ]]; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Missing or invalid flatpak_app_id from custom checker output" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Missing flatpak_app_id for flatpak install."}'
                    interfaces::print_ui_line "  " "✗ " "Custom checker did not provide a valid flatpak_app_id." "${COLOR_RED}"
                    return 1
                fi

                updates::process_flatpak_app \
                    "${app_config_ref[name]}" \
                    "${app_config_ref[app_key]}" \
                    "$latest_version" \
                    "$flatpak_app_id_from_output"
                ;;
            "tgz")
                local download_url_from_output checksum_url_from_output
                download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
                checksum_url_from_output=$(echo "$custom_checker_output" | jq -r '.checksum_url // empty')

                if [[ -z "$download_url_from_output" || "$download_url_from_output" == "null" ]]; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Missing download_url for tgz install type" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Missing download_url for tgz."}'
                    interfaces::print_ui_line "  " "✗ " "Custom checker did not provide a tgz download_url." "${COLOR_RED}"
                    return 1
                fi
                if ! validators::check_url_format "$download_url_from_output"; then
                    errors::handle_error "CUSTOM_CHECKER_ERROR" "Invalid download_url format for tgz install type" "$app_display_name"
                    updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Invalid download_url format for tgz."}'
                    interfaces::print_ui_line "  " "✗ " "Custom checker provided invalid tgz download_url format." "${COLOR_RED}"
                    return 1
                fi
                if [[ -n "$checksum_url_from_output" && "$checksum_url_from_output" != "null" ]]; then
                    if ! validators::check_url_format "$checksum_url_from_output"; then
                        errors::handle_error "CUSTOM_CHECKER_ERROR" "Invalid checksum_url format for tgz install type" "$app_display_name"
                        updates::trigger_hooks ERROR_HOOKS "$app_display_name" '{"phase":"install","error_type":"CUSTOM_CHECKER_ERROR","message":"Invalid checksum_url format for tgz."}'
                        interfaces::print_ui_line "  " "✗ " "Custom checker provided invalid tgz checksum_url format." "${COLOR_RED}"
                        return 1
                    fi
                else
                    checksum_url_from_output="" # normalize null -> empty
                fi

                updates::process_installation \
                    "$app_display_name" \
                    "$app_key" \
                    "$latest_version" \
                    "packages::install_tgz_package" \
                    "$download_url_from_output" \
                    "$config_array_name" \
                    "$app_key" \
                    "$latest_version" \
                    "$checksum_url_from_output"
                ;;
            *)
                errors::handle_error "CUSTOM_CHECKER_ERROR" "Unknown install type '$install_type' from custom checker" "$app_display_name"
                updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\":\"install\",\"error_type\":\"CUSTOM_CHECKER_ERROR\",\"message\":\"Unknown install type: $install_type\"}"
                interfaces::print_ui_line "  " "✗ " "Unknown install type from custom checker: $install_type" "${COLOR_RED}"
                return 1
                ;;
        esac

    elif [[ "$status" == "no_update" || "$status" == "success" ]]; then
        updates::handle_up_to_date

    elif [[ "$status" == "error" ]]; then
        errors::handle_error "$error_type_from_checker" "$error_message" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\":\"check\",\"error_type\":\"$error_type_from_checker\",\"message\":\"$error_message\"}"
        interfaces::print_ui_line "  " "✗ " "Error: $error_message" "${COLOR_RED}"
        return 1

    else
        interfaces::print_ui_line "  " "✗ " "Unknown status from checker." "${COLOR_RED}"
        return 1
    fi

    return 0
}
