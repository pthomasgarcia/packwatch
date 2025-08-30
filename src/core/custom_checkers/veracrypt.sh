#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/veracrypt.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for VeraCrypt.
#
# Dependencies:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

check_veracrypt() {
    local app_config_json="$1"

    # Cache config JSON
    local cache_key
    cache_key="veracrypt_$(hashes::generate "$app_config_json")"
    systems::cache_json "$app_config_json" "$cache_key"

    # Retrieve required fields
    local name app_key gpg_key_id gpg_fingerprint
    name=$(systems::fetch_cached_json "$cache_key" "name")
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")
    gpg_key_id=$(systems::fetch_cached_json "$cache_key" "gpg_key_id")
    gpg_fingerprint=$(systems::fetch_cached_json "$cache_key" "gpg_fingerprint")

    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "CONFIG_ERROR" "Missing required fields: name/app_key." "${name:-veracrypt}"
        return 1
    fi

    # Installed version
    local installed_version
    installed_version=$(packages::fetch_version "$app_key")

    # Fetch download page
    local url="https://veracrypt.io/en/Downloads.html"
    local page_content
    if ! page_content=$(networks::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    # Extract latest version
    local latest_version
    latest_version=$(echo "$page_content" | grep -oE 'VeraCrypt [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2)
    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Failed to detect latest version for $name." "$name"
        return 1
    fi

    # Normalize versions
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    loggers::debug "VERACRYPT: installed_version='$installed_version' latest_version='$latest_version'"

    # Determine status
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    if [[ "$output_status" == "UP_TO_DATE" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # Search for download URL
    local ubuntu_release
    ubuntu_release=$(lsb_release -rs 2> /dev/null || echo "")

    local download_url_final=""
    if [[ -n "$ubuntu_release" ]]; then
        download_url_final=$(echo "$page_content" |
            grep -E "href=\"[^\"]*veracrypt-${latest_version}-Ubuntu-${ubuntu_release}-amd64\\.deb\"" |
            head -n 1 |
            sed -nE "s/.*href=\"([^\"]*veracrypt-${latest_version}-Ubuntu-${ubuntu_release}-amd64\\.deb)\".*/\1/p")
        download_url_final=$(networks::decode_url "$download_url_final")
        if ! download_url_final=$(networks::validate_url "$download_url_final"); then
            download_url_final=""
        fi
    fi

    # Fallback: try generic .deb if Ubuntu-specific not found
    if [[ -z "$download_url_final" ]]; then
        download_url_final=$(echo "$page_content" |
            grep -Eo "https://[^\"]*veracrypt-${latest_version}.*amd64\\.deb" | head -n1)
        if ! download_url_final=$(networks::validate_url "$download_url_final"); then
            download_url_final=""
        fi
    fi

    if [[ -z "$download_url_final" ]]; then
        responses::emit_error "NETWORK_ERROR" "No compatible DEB package found for Ubuntu $ubuntu_release for $name." "$name"
        return 1
    fi

    # Normalize Launchpad URLs
    if [[ "$download_url_final" =~ launchpadlibrarian.net ]]; then
        local base_name
        base_name=$(basename "$download_url_final")
        download_url_final="https://launchpad.net/veracrypt/trunk/${latest_version}/+download/${base_name}"
    fi

    local sig_url="${download_url_final}.sig"

    responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
        download_url "$download_url_final" \
        gpg_key_id "$gpg_key_id" \
        gpg_fingerprint "$gpg_fingerprint" \
        sig_url "$sig_url"

    return 0
}
