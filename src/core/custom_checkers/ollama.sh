#!/usr/bin/env bash
# ==============================================================================
# CUSTOM CHECKER: Ollama
# ==============================================================================
#
# Responsibilities:
#   - Fetch the latest release object from the GitHub API.
#   - Extract version, tgz download URL, and checksum URL from the API response.
#   - Compare against the installed version.
#   - Return a JSON object with all necessary metadata for the installer.
#
# ==============================================================================

check_ollama() {
    local app_config_json="$1"
    local app_name
    app_name=$(echo "$app_config_json" | jq -r '.name')
    local app_key
    app_key=$(echo "$app_config_json" | jq -r '.app_key')

    # 1. Fetch Latest Release Info (with Caching)
    local repo_owner
    repo_owner=$(echo "$app_config_json" | jq -r '.repo_owner')
    local repo_name
    repo_name=$(echo "$app_config_json" | jq -r '.repo_name')
    local api_url="https://api.github.com/repos/${repo_owner}/${repo_name}/releases"
    
    local api_response_file
    if ! api_response_file=$(networks::fetch_cached_data "$api_url" "json"); then
        jq -n --arg status "error" --arg msg "Failed to fetch release info from GitHub." '{status: $status, error_message: $msg}'
        return 1
    fi

    local latest_release_object_file
    latest_release_object_file=$(systems::create_temp_file "ollama_latest_release")
    TEMP_FILES+=("$latest_release_object_file")

    if ! jq '.[0]' "$api_response_file" > "$latest_release_object_file"; then
        jq -n --arg status "error" --arg msg "Failed to extract latest release object from API response." '{status: $status, error_message: $msg}'
        return 1
    fi

    # 2. Extract All Required Data from the Release Object
    local latest_version
    if ! latest_version=$(repositories::parse_version_from_release "$latest_release_object_file" "$app_name"); then
        jq -n --arg status "error" --arg msg "Failed to parse version from GitHub release." '{status: $status, error_message: $msg}'
        return 1
    fi

    local filename_template
    filename_template=$(echo "$app_config_json" | jq -r '.filename_pattern_template')
    
    local tgz_url
    tgz_url=$(jq -r --arg name "$filename_template" '.assets[] | select(.name == $name).browser_download_url' "$latest_release_object_file")
    
    local checksum_url
    checksum_url=$(jq -r '.assets[] | select(.name | endswith("sha256sum.txt")).browser_download_url' "$latest_release_object_file")

    if [[ -z "$tgz_url" ]] || [[ -z "$checksum_url" ]]; then
        jq -n --arg status "error" --arg msg "Failed to find required assets in GitHub release." '{status: $status, error_message: $msg}'
        return 1
    fi

    # 3. Determine Status
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")
    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    # 4. Return JSON payload for the main script to handle
    jq -n \
        --arg status "$output_status" \
        --arg latest_version "$latest_version" \
        --arg download_url "$tgz_url" \
        --arg checksum_url "$checksum_url" \
        --arg install_type "tgz" \
        --arg source "GitHub Releases" \
        '{
             "status": $status,
             "latest_version": $latest_version,
             "download_url": $download_url,
             "checksum_url": $checksum_url,
             "install_type": $install_type,
             "source": $source
           }'
    return 0
}
