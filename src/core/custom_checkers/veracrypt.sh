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
#   - web_parsers.sh
# ==============================================================================

_veracrypt::get_latest_version_from_page() {
    local page_content="$1"
    web_parsers::extract_version "$page_content" 'VeraCrypt [0-9]+\.[0-9]+\.[0-9]+' | cut -d' ' -f2
}

_veracrypt::get_download_url_from_page() {
    local page_content="$1"
    local latest_version="$2"
    local name="$3"

    local ubuntu_release
    ubuntu_release=$(lsb_release -rs 2> /dev/null || echo "")

    local download_url_final=""
    if [[ -n "$ubuntu_release" ]]; then
        local candidates
        mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")
        download_url_final=$(echo "${candidates[@]}" | grep -oE "https://[^\"]*veracrypt-${latest_version}-Ubuntu-${ubuntu_release}-amd64\\.deb" | head -n1)
        if ! download_url_final=$(networks::validate_url "$download_url_final"); then
            download_url_final=""
        fi
    fi

    if [[ -z "$download_url_final" ]]; then
        local candidates
        mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")
        download_url_final=$(echo "${candidates[@]}" | grep -oE "https://[^\"]*veracrypt-${latest_version}.*amd64\\.deb" | head -n1)
        if ! download_url_final=$(networks::validate_url "$download_url_final"); then
            download_url_final=""
        fi
    fi

    if [[ -z "$download_url_final" ]]; then
        responses::emit_error "NETWORK_ERROR" "No compatible DEB package found for Ubuntu $ubuntu_release for $name." "$name"
        return 1
    fi

    if [[ "$download_url_final" =~ launchpadlibrarian.net ]]; then
        local base_name
        base_name=$(basename "$download_url_final")
        download_url_final="https://launchpad.net/veracrypt/trunk/${latest_version}/+download/${base_name}"
    fi

    echo "$download_url_final"
}

check_veracrypt() {
    local app_config_json="$1"

    # Cache config JSON
    local cache_key
    cache_key="veracrypt_$(hashes::generate "$app_config_json")"
    systems::cache_json "$app_config_json" "$cache_key"

    # Retrieve required fields
    local name app_key gpg_key_id gpg_fingerprint download_url_base
    name=$(systems::fetch_cached_json "$cache_key" "name")
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")
    gpg_key_id=$(systems::fetch_cached_json "$cache_key" "gpg_key_id")
    gpg_fingerprint=$(systems::fetch_cached_json "$cache_key" "gpg_fingerprint")
    download_url_base=$(systems::fetch_cached_json "$cache_key" "download_url_base")

    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "CONFIG_ERROR" "Missing required fields: name/app_key." "${name:-veracrypt}"
        return 1
    fi

    # Installed version
    local installed_version
    installed_version=$(packages::fetch_version "$app_key")

    # Fetch download page
    local url="$download_url_base"
    local page_content
    if ! page_content=$(networks::fetch_and_load "$url" "html" "$name" "Failed to fetch download page for $name."); then
        return 1
    fi

    # Extract latest version
    local latest_version
    latest_version=$(_veracrypt::get_latest_version_from_page "$page_content")
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

    if [[ "$output_status" == "no_update" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # Search for download URL
    local download_url_final
    download_url_final=$(_veracrypt::get_download_url_from_page "$page_content" "$latest_version" "$name")
    if [[ -z "$download_url_final" ]]; then
        # Error message already emitted by _veracrypt::get_download_url_from_page
        return 1
    fi

    local sig_url="${download_url_final}.sig"

    responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
        download_url "$download_url_final" \
        gpg_key_id "$gpg_key_id" \
        gpg_fingerprint "$gpg_fingerprint" \
        sig_url "$sig_url" \
        install_type "deb"

    return 0
}
