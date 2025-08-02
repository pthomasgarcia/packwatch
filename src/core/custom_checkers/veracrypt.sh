#!/usr/bin/env bash

# Custom checker for VeraCrypt
check_veracrypt() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    local url="https://veracrypt.fr/en/Downloads.html"
    local page_content
    if ! page_content=$(networks::fetch_cached_data "$url" "html"); then
        errors::handle_error "CUSTOM_CHECKER_ERROR" "Failed to fetch download page for $name." "veracrypt"
        return 1
    fi

    local latest_version
    latest_version=$(echo "$page_content" | grep -oP 'VeraCrypt \K\d+\.\d+\.\d+' | head -n1)
    if [[ -z "$latest_version" ]]; then
        errors::handle_error "CUSTOM_CHECKER_ERROR" "Failed to detect latest version for $name." "veracrypt"
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
            current_base_url=$(printf "$base_lp_url_template" "$latest_version")
            local test_url="${current_base_url}${deb_file}"
            test_url=$(networks::decode_url "$test_url")
            if validators::check_url_format "$test_url" && \
                systems::reattempt_command 3 5 curl --head -s --fail "$test_url" | head -n 1 | grep -q "200 OK"; then
                download_url_final="$test_url"
                break
            fi
        done
    fi

    if [[ -z "$download_url_final" ]] || ! validators::check_url_format "$download_url_final"; then
        errors::handle_error "CUSTOM_CHECKER_ERROR" "No compatible DEB package found for $name." "veracrypt"
        return 1
    fi

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")
    
    local gpg_key_id="${app_config_ref[gpg_key_id]:-}"
    local gpg_fingerprint="${app_config_ref[gpg_fingerprint]:-}"

    jq -n \
        --arg status "$output_status" \
        --arg latest_version "$latest_version" \
        --arg download_url "$download_url_final" \
        --arg install_type "deb" \
        --arg gpg_key_id "$gpg_key_id" \
        --arg gpg_fingerprint "$gpg_fingerprint" \
        --arg source "Official Download Page" \
        '{
          "status": $status,
          "latest_version": $latest_version,
          "download_url": $download_url,
          "install_type": $install_type,
          "gpg_key_id": $gpg_key_id,
          "gpg_fingerprint": $gpg_fingerprint,
          "source": $source
        }'
    
    return 0
}
