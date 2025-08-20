#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/github.sh
# ==============================================================================
# Responsibilities:
#   - Handles all logic specific to updating applications via GitHub releases.
# ==============================================================================

# Fetch the latest release JSON from GitHub and return:
#   1) the parsed latest version (line 1)
#   2) a PATH to a temp file containing the latest release JSON object (line 2)
updates::_fetch_github_version() {
    local repo_owner="$1"
    local repo_name="$2"
    local app_name="$3"

    # Fetch the releases list to a cached file (path)
    local api_response_file
    if ! api_response_file=$("$UPDATES_GET_LATEST_RELEASE_INFO_IMPL" "$repo_owner" "$repo_name"); then
        errors::handle_error "NETWORK_ERROR" "Failed to fetch GitHub releases for '$app_name'." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to fetch GitHub releases.\"}"
        return 1
    fi

    # Extract the latest release object as a JSON STRING
    local latest_release_json
    if ! latest_release_json=$("$UPDATES_GET_JSON_VALUE_IMPL" "$api_response_file" '.[0]' "$app_name"); then
        errors::handle_error "PARSING_ERROR" "Failed to parse latest release information." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to parse latest release information.\"}"
        return 1
    fi

    # Write that JSON STRING to a temp file and return its PATH
    local latest_release_json_path
    if ! latest_release_json_path=$(systems::create_temp_file "latest_release"); then
        errors::handle_error "SYSTEM_ERROR" "Failed to create temp file for latest release JSON." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"SYSTEM_ERROR\", \"message\": \"Failed to create temp file.\"}"
        return 1
    fi
    printf '%s' "$latest_release_json" > "$latest_release_json_path"

    # Parse version from the temp file (function expects a file path)
    local latest_version
    if ! latest_version=$(repositories::parse_version_from_release "$latest_release_json_path" "$app_name"); then
        errors::handle_error "PARSING_ERROR" "Failed to get version from latest release." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to get version from latest release.\"}"
        return 1
    fi

    # Maintain the two-line echo contract used by callers
    echo "$latest_version"
    echo "$latest_release_json_path"
    return 0
}

# Build download URL from a release JSON file path
updates::_build_download_url() {
    local release_path="$1"      # Path to temp file containing the release JSON
    local filename_template="$2" # Template (may contain %s)
    local version="$3"
    local app_name="$4"

    local download_filename
    # shellcheck disable=SC2059 # The template is a trusted config value.
    download_filename=$(printf "$filename_template" "$version")

    local download_url status=0
    # First attempt: pattern (template). Capture status immediately.
    download_url=$(repositories::find_asset_url "$release_path" "$filename_template" "$app_name") || status=$?

    # Fallback if first attempt failed or empty: try concrete resolved filename.
    if [[ $status -ne 0 || -z "$download_url" ]]; then
        download_url=$(repositories::find_asset_url "$release_path" "$download_filename" "$app_name") || status=$?
    fi

    # Unified validation & error handling.
    if [[ $status -ne 0 || -z "$download_url" || ! $(validators::check_url_format "$download_url" && echo ok) ]]; then
        errors::handle_error "NETWORK_ERROR" "Download URL not found or invalid for '$download_filename'." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Download URL not found or invalid.\"}"
        return 1
    fi

    echo "$download_url"
    return 0
}

# Extract checksum from release JSON
updates::_extract_release_checksum() {
    local release_json_path="$1"
    local filename_template="$2"
    local version="$3"
    local app_name="$4"
    local config_ref_name="$5"
    local -n app_config_ref=$config_ref_name

    local use_digest="${app_config_ref[checksum_from_github_release_digest]:-false}"
    local expected_checksum=""
    local download_filename
    # shellcheck disable=SC2059 # The template is a trusted config value.
    download_filename=$(printf "$filename_template" "$version")

    if [[ "$use_digest" == "true" ]]; then
        # First try using the template (with %s placeholder) so the digest lookup can
        # match any version pattern (new style).
        expected_checksum=$(repositories::find_asset_digest \
            "$release_json_path" \
            "$filename_template" \
            "$app_name") || expected_checksum=""

        # Older releases / legacy implementations may store the digest under the
        # fully resolved filename instead of a pattern; if the first attempt
        # yielded nothing, retry using the concrete resolved filename.
        if [[ -z "$expected_checksum" ]]; then
            local alt_checksum
            alt_checksum=$(repositories::find_asset_digest \
                "$release_json_path" \
                "$download_filename" \
                "$app_name") || alt_checksum=""
            [[ -n "$alt_checksum" ]] && expected_checksum="$alt_checksum"
        fi
    fi

    echo "$expected_checksum"
    return 0
}

updates::check_github_release() {
    local config_ref_name="$1"
    local -n app_config_ref=$config_ref_name
    local app_key="${app_config_ref[app_key]}"
    local name="${app_config_ref[name]:-$app_key}" # Fallback to app_key
    local repo_owner="${app_config_ref[repo_owner]}"
    local repo_name="${app_config_ref[repo_name]}"
    local filename_pattern_template="${app_config_ref[filename_pattern_template]}"
    local source="GitHub Releases"

    interfaces::print_ui_line "  " "→ " "Checking GitHub releases for ${FORMAT_BOLD}$name${FORMAT_RESET}..."

    local installed_version installed_version_raw
    if ! installed_version_raw=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key" 2> /dev/null); then
        loggers::log_message "WARN" "Failed to obtain installed version for '$name'; treating as not installed (0.0.0)."
        installed_version="0.0.0"
    else
        # Trim whitespace/newlines
        installed_version_raw=$(echo -n "$installed_version_raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$installed_version_raw" ]]; then
            loggers::log_message "WARN" "Installed version empty for '$name'; treating as not installed (0.0.0)."
            installed_version="0.0.0"
        else
            installed_version="$installed_version_raw"
        fi
    fi

    local fetch_result
    fetch_result=$(updates::_fetch_github_version "$repo_owner" "$repo_name" "$name") || return 1
    local latest_version
    latest_version=$(echo "$fetch_result" | head -n1)
    local latest_release_json_path
    latest_release_json_path=$(echo "$fetch_result" | tail -n +2)

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        local download_url
        if ! download_url=$(updates::_build_download_url "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name"); then
            # First attempt (template) failed; retry explicitly with concrete filename.
            local concrete_filename
            # shellcheck disable=SC2059
            concrete_filename=$(printf "$filename_pattern_template" "$latest_version")
            if ! download_url=$(updates::_build_download_url "$latest_release_json_path" "$concrete_filename" "$latest_version" "$name"); then
                errors::handle_error "NETWORK_ERROR" "Failed to resolve download URL (template '$filename_pattern_template', concrete '$concrete_filename', version '$latest_version')." "$name"
                updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\":\"download\",\"error_type\":\"NETWORK_ERROR\",\"message\":\"Failed to resolve download URL after template+concrete attempts.\"}"
                return 1
            fi
        fi

        local expected_checksum
        expected_checksum=$(updates::_extract_release_checksum "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name" "$config_ref_name")

        local download_filename
        # shellcheck disable=SC2059 # The template is a trusted config value.
        download_filename=$(printf "$filename_pattern_template" "$latest_version")

        if [[ "$download_filename" == *.deb ]]; then
            updates::process_installation \
                "$name" \
                "$app_key" \
                "$latest_version" \
                "packages::process_deb_package" \
                "$config_ref_name" \
                "$filename_pattern_template" \
                "$latest_version" \
                "$download_url" \
                "$expected_checksum" \
                "$name"
        elif [[ "$download_filename" == *.tgz ]]; then
            local binary_name="${app_config_ref[binary_name]:-$(echo "$app_key" | tr '[:upper:]' '[:lower:]')}"
            updates::process_installation \
                "$name" \
                "$app_key" \
                "$latest_version" \
                "packages::process_tgz_package" \
                "$config_ref_name" \
                "$filename_pattern_template" \
                "$latest_version" \
                "$download_url" \
                "$expected_checksum" \
                "$name" \
                "$app_key" \
                "$binary_name"
        else
            errors::handle_error "UNSUPPORTED_ERROR" "Unsupported file type for github_release: '$download_filename'" "$name"
            return 1
        fi
    else
        updates::handle_up_to_date
    fi

    return 0
}
