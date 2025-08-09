#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/veracrypt.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for VeraCrypt.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - networks.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# Custom checker for VeraCrypt
check_veracrypt() {
    local app_config_json="$1" # Now receives JSON string
    
    # Cache all fields at once to reduce jq process spawning
    local cache_key="veracrypt_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"
    
    # Get all values from cache instead of multiple jq calls
    local name=$(systems::get_cached_json_value "$cache_key" "name")
    local app_key=$(systems::get_cached_json_value "$cache_key" "app_key")
    local gpg_key_id=$(systems::get_cached_json_value "$cache_key" "gpg_key_id")
    local gpg_fingerprint=$(systems::get_cached_json_value "$cache_key" "gpg_fingerprint")
    
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    local url="https://veracrypt.fr/en/Downloads.html"
    local page_content_path # This will now be a file path
    if ! page_content_path=$(networks::fetch_cached_data "$url" "html"); then
        errors::handle_error "CUSTOM_CHECKER_ERROR" "Failed to fetch download page for $name." "veracrypt"
        return 1
    fi

    local latest_version
    # Read content from the file for regex matching
    local page_content
    page_content=$(cat "$page_content_path")
    latest_version=$(echo "$page_content" | grep -oP 'VeraCrypt \K\d+\.\d+\.\d+' | head -n1)
    if [[ -z "$latest_version" ]]; then
        jq -n \
            --arg status "error" \
            --arg error_message "Failed to detect latest version for $name." \
            --arg error_type "PARSING_ERROR" \
            '{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
        return 1
    fi

    local ubuntu_release
    ubuntu_release=$(lsb_release -rs 2>/dev/null || echo "")
    local download_url_final=""

    if [[ -n "$ubuntu_release" ]]; then
        download_url_final=$(echo "$page_content" | grep -A 10 "Ubuntu ${ubuntu_release}:" | grep -oP 'href="([^"]*veracrypt-'"${latest_version}"'-Ubuntu-'"${ubuntu_release}"'-amd64\.deb)"' | head -n 1 | sed -E 's/href="([^"]+)"/\1/')
        download_url_final=$(networks::decode_url "$download_url_final")
    fi

    if [[ -z "$download_url_final" ]] || ! validators::check_url_format "$download_url_final"; then
        local common_ubuntu_releases=("24.04" "22.04" "20.04" "18.04")
        local base_lp_url_template="https://launchpad.net/veracrypt/trunk/%s/+download/"
        for ubuntu_ver_fallback in "${common_ubuntu_releases[@]}"; do
            local deb_file="veracrypt-${latest_version}-Ubuntu-${ubuntu_ver_fallback}-amd64.deb"
            local current_base_url
            printf -v current_base_url "$base_lp_url_template" "$latest_version"
            local test_url="${current_base_url}${deb_file}"
            test_url=$(networks::decode_url "$test_url")
            if validators::check_url_format "$test_url" &&
                networks::url_exists "$test_url"; then
                download_url_final="$test_url"
                break
            fi
        done
    fi

    if [[ -z "$download_url_final" ]] || ! validators::check_url_format "$download_url_final"; then
        jq -n \
            --arg status "error" \
            --arg error_message "No compatible DEB package found for $name." \
            --arg error_type "NETWORK_ERROR" \
            '{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
        return 1
    fi

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    jq -n \
        --arg status "$output_status" \
        --arg latest_version "$latest_version" \
        --arg download_url "$download_url_final" \
        --arg install_type "deb" \
        --arg gpg_key_id "$gpg_key_id" \
        --arg gpg_fingerprint "$gpg_fingerprint" \
        --arg source "Official Download Page" \
        --arg error_type "NONE" \
        '{
             "status": $status,
             "latest_version": $latest_version,
             "download_url": $download_url,
             "install_type": $install_type,
             "gpg_key_id": $gpg_key_id,
             "gpg_fingerprint": $gpg_fingerprint,
             "source": $source,
             "error_type": $error_type
           }'

    return 0
}
