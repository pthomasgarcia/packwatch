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

# Custom checker for VeraCrypt
check_veracrypt() {
    local app_config_json="$1" # Now receives JSON string

    # Generate cache key and cache all fields at once
    local cache_key
    local _hash
    _hash="$(hashes::generate "$app_config_json")"
    cache_key="veracrypt_${_hash}"
    systems::cache_json "$app_config_json" "$cache_key"

    # Retrieve all required fields from cache efficiently
    local name app_key gpg_key_id gpg_fingerprint
    name=$(systems::fetch_cached_json "$cache_key" "name")
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")
    gpg_key_id=$(systems::fetch_cached_json "$cache_key" "gpg_key_id")
    gpg_fingerprint=$(systems::fetch_cached_json "$cache_key" "gpg_fingerprint")

    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "CONFIG_ERROR" "Missing required fields: name/app_key." "${name:-veracrypt}"
        return 1
    fi

    # Get installed version
    local installed_version
    installed_version=$(packages::fetch_version "$app_key")

    # Fetch download page (with caching)
    local url="https://veracrypt.io/en/Downloads.html"
    local page_content
    if ! page_content=$(networks::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    # Extract latest version (simplified)
    local latest_version
    latest_version=$(echo "$page_content" | grep -oE 'VeraCrypt [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2)
    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Failed to detect latest version for $name." "$name"
        return 1
    fi

    # Normalize versions
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    # Log debug info
    loggers::log_message "DEBUG" "VERACRYPT: installed_version='$installed_version' latest_version='$latest_version'"

    # Determine status early
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    # Early exit if up-to-date (no need to search for URLs)
    if [[ "$output_status" == "UP_TO_DATE" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # Only search for download URL if update is needed
    local ubuntu_release
    ubuntu_release=$(lsb_release -rs 2> /dev/null || echo "")

    local download_url_final=""

    if [[ -n "$ubuntu_release" ]]; then
        download_url_final=$(echo "$page_content" |
            grep -E "href=\"[^\"]*veracrypt-${latest_version}-Ubuntu-${ubuntu_release}-amd64\\.deb\"" |
            head -n 1 |
            sed -nE "s/.*href=\"([^\"]*veracrypt-${latest_version}-Ubuntu-${ubuntu_release}-amd64\\.deb)\".*/\1/p")
        download_url_final=$(networks::decode_url "$download_url_final")
        if [[ -n "$download_url_final" ]]; then
            if ! download_url_final=$(networks::validate_url "$download_url_final"); then
                download_url_final=""
            fi
        fi
    fi

    # If no specific DEB found for current Ubuntu release, fail immediately
    if [[ -z "$download_url_final" ]]; then
        responses::emit_error "NETWORK_ERROR" "No compatible DEB package found for Ubuntu $ubuntu_release for $name." "$name"
        return 1
    fi

    # Extract PGP signature URL
    local escaped_ver
    escaped_ver=$(printf '%s' "$latest_version" | sed 's/\./\\./g')
    local sig_url
    sig_url=$(echo "$page_content" | grep -oP 'href="([^"]*VeraCrypt-'"$escaped_ver"'-x86_64\.AppImage\.sig)"' | head -n1 | sed -E 's/href="([^"]+)"/\1/')
    sig_url=$(networks::decode_url "$sig_url")

    # Emit success response
    responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
        download_url "$download_url_final" \
        gpg_key_id "$gpg_key_id" \
        gpg_fingerprint "$gpg_fingerprint" \
        sig_url "$sig_url"

    return 0
}
