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
    local cache_key
    cache_key="veracrypt_$(echo "$app_config_json" | md5sum | cut -d' ' -f1)"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Get all values from cache instead of multiple jq calls
    local name
    name=$(systems::get_cached_json_value "$cache_key" "name")
    local app_key
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")
    local gpg_key_id
    gpg_key_id=$(systems::get_cached_json_value "$cache_key" "gpg_key_id")
    local gpg_fingerprint
    gpg_fingerprint=$(systems::get_cached_json_value "$cache_key" "gpg_fingerprint")

    local installed_version
    installed_version=$(checker_utils::get_installed_version "$app_key")

    local url="https://veracrypt.io/en/Downloads.html"
    local page_content
    if ! page_content=$(checker_utils::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    local latest_version
    latest_version=$(echo "$page_content" | grep -oP 'VeraCrypt \K\d+\.\d+\.\d+' | head -n1)
    if [[ -z "$latest_version" ]]; then
        checker_utils::emit_error "PARSING_ERROR" "Failed to detect latest version for $name." "$name" >/dev/null
        return 1
    fi

    # Normalize versions
    installed_version=$(checker_utils::strip_version_prefix "$installed_version")
    latest_version=$(checker_utils::strip_version_prefix "$latest_version")

    checker_utils::debug "VERACRYPT: installed_version='$installed_version' latest_version='$latest_version'"

    local ubuntu_release
    ubuntu_release=$(lsb_release -rs 2> /dev/null || echo "")

    # Try page-derived URL for the exact Ubuntu release (if present)
    local download_url_direct=""
    if [[ -n "$ubuntu_release" ]]; then
        download_url_direct=$(echo "$page_content" | \
            grep -A 10 "Ubuntu ${ubuntu_release}:" | \
            grep -oP 'href="([^"]*veracrypt-'"${latest_version}"'-Ubuntu-'"${ubuntu_release}"'-amd64\.deb)"' | \
            head -n 1 | sed -E 's/href="([^"]+)"/\1/')
        download_url_direct=$(checker_utils::decode_url "$download_url_direct")
        if [[ -n "$download_url_direct" ]]; then
            # Resolve + validate quickly
            if ! download_url_direct=$(checker_utils::resolve_and_validate_url "$download_url_direct"); then
                download_url_direct=""
            fi
        fi
    fi

    # Build candidate fallback URLs for common Ubuntu releases
    local -a candidates=()
    [[ -n "$download_url_direct" ]] && candidates+=("$download_url_direct")

    local common_ubuntu_releases=("24.04" "22.04" "20.04" "18.04")
    local base_lp_url_template="https://launchpad.net/veracrypt/trunk/%s/+download/"
    local current_base_url
    printf -v current_base_url "$base_lp_url_template" "$latest_version"

    local ubuntu_ver_fallback
    for ubuntu_ver_fallback in "${common_ubuntu_releases[@]}"; do
        local deb_file="veracrypt-${latest_version}-Ubuntu-${ubuntu_ver_fallback}-amd64.deb"
        local candidate="${current_base_url}${deb_file}"
        candidate=$(checker_utils::decode_url "$candidate")
        candidates+=("$candidate")
    done

    # Choose the first alive candidate quickly
    local download_url_final
    if ! download_url_final=$(checker_utils::first_alive_url "${candidates[@]}"); then
        checker_utils::emit_error "NETWORK_ERROR" "No compatible DEB package found for $name." "$name" >/dev/null
        return 1
    fi

    local output_status
    output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

    # Extract PGP signature URL for the x86_64 AppImage from the downloads page
    local escaped_ver
    escaped_ver=$(printf '%s' "$latest_version" | sed 's/\./\\./g')
    local sig_url
    sig_url=$(echo "$page_content" | grep -oP 'href="([^"]*VeraCrypt-'"$escaped_ver"'-x86_64\.AppImage\.sig)"' | head -n1 | sed -E 's/href="([^"]+)"/\1/')
    sig_url=$(checker_utils::decode_url "$sig_url")

    checker_utils::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
        download_url "$download_url_final" \
        gpg_key_id "$gpg_key_id" \
        gpg_fingerprint "$gpg_fingerprint" \
        sig_url "$sig_url"

    return 0
}
