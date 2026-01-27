#!/usr/bin/env bash
# src/core/updates/github.sh
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

    # Extract the latest *stable* release object as a JSON STRING
    local latest_release_json
    if ! latest_release_json=$(jq -c '[.[] | select(.prerelease == false)][0]' "$api_response_file"); then
        errors::handle_error "PARSING_ERROR" "Failed to parse latest stable release information." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to parse latest stable release information.\"}"
        return 1
    fi

    # Write that JSON STRING to a temp file and return its PATH
    local latest_release_json_path
    if ! latest_release_json_path=$(systems::create_temp_file "latest_release"); then
        errors::handle_error "SYSTEM_ERROR" "Failed to create temp file for latest release JSON." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"SYSTEM_ERROR\", \"message\": \"Failed to create temp file.\"}"
        return 1
    fi
    printf '%s' "$latest_release_json" >"$latest_release_json_path"

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
    local name="${app_config_ref[name]:-$app_key}"
    local repo_owner="${app_config_ref[repo_owner]}"
    local repo_name="${app_config_ref[repo_name]}"
    local filename_pattern_template="${app_config_ref[filename_pattern_template]}"

    interfaces::print_ui_line "  " "→ " "Checking GitHub releases for ${FORMAT_BOLD}$name${FORMAT_RESET}..."

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key" 2>/dev/null || echo "0.0.0")
    installed_version=$(echo -n "$installed_version" | tr -d '\r' | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')

    local fetch_result
    fetch_result=$(updates::_fetch_github_version "$repo_owner" "$repo_name" "$name") || return 1
    local latest_version=$(echo "$fetch_result" | head -n1)
    local latest_release_json_path=$(echo "$fetch_result" | tail -n +2)

    updates::print_version_info "$installed_version" "GitHub Releases" "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        local download_url
        download_url=$(updates::_build_download_url "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name") || return 1

        # Correct Size Extraction
        local exact_size
        exact_size=$(jq -r --arg url "$download_url" '.assets[] | select(.browser_download_url == $url) | .size' "$latest_release_json_path")
        [[ -n "$exact_size" && "$exact_size" != "null" ]] && app_config_ref[content_length]="$exact_size"

        local expected_checksum=$(updates::_extract_release_checksum "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name" "$config_ref_name")
        local download_filename=$(printf "$filename_pattern_template" "$latest_version")

        # --- CORRECTED ROUTING ---
        if [[ "$download_filename" == *.deb ]]; then
            updates::process_installation "$name" "$app_key" "$latest_version" \
                "packages::process_deb_package" "$config_ref_name" "$filename_pattern_template" \
                "$latest_version" "$download_url" "$expected_checksum" "$name"

        elif [[ "$download_filename" == *.AppImage ]] && [[ "${app_config_ref[install_strategy]}" == "move_appimage" ]]; then
            local install_base="${app_config_ref[install_path]:-$HOME/Applications}"
            local resolved_base="${install_base//\$HOME/$ORIGINAL_HOME}"
            resolved_base="${resolved_base/#\~/$ORIGINAL_HOME}"
            local final_target="${resolved_base}/${name,,}/${name,,}.AppImage"

            updates::process_installation "$name" "$app_key" "$latest_version" \
                "updates::process_appimage_file" "$config_ref_name" "$name" "$latest_version" \
                "$download_url" "$final_target" "$app_key" "$expected_checksum" \
                "${app_config_ref[checksum_algorithm]:-sha256}" "${app_config_ref[allow_insecure_http]:-0}"

        else
            # FIX: Passed $config_ref_name FIRST so worker can find [content_length]
            local binary_name="${app_config_ref[binary_name]:-$(echo "$app_key" | tr '[:upper:]' '[:lower:]')}"
            updates::process_installation "$name" "$app_key" "$latest_version" \
                "packages::process_archive_package" \
                "$config_ref_name" \
                "$filename_pattern_template" \
                "$latest_version" \
                "$download_url" \
                "$expected_checksum" \
                "$name" \
                "$app_key" \
                "$binary_name"
        fi
    else
        updates::handle_up_to_date
    fi
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
