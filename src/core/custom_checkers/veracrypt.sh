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
#   - configs.sh
# ==============================================================================

_veracrypt::get_latest_version_from_page() {
    local page_content="$1"
    echo "$page_content" |
        grep -Po 'Latest Stable Release - \K[0-9]+\.[0-9]+\.[0-9]+' |
        head -n1
}

_veracrypt::get_download_url_from_page() {
    local page_content="$1"
    local latest_version="$2"
    local name="$3"

    local download_url_final=""
    local -a candidates
    mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")

    # Try to find Ubuntu-specific DEB (still keep this logic, just remove the `ubuntu_release` variable)
    for url_candidate in "${candidates[@]}"; do
        if [[ "$url_candidate" =~ https://[^\"]*veracrypt-${latest_version}-Ubuntu-[0-9.]+-amd64\.deb ]]; then
            download_url_final="$url_candidate"
            break
        fi
    done

    # If no Ubuntu-specific DEB, try a generic amd64 DEB
    if [[ -z "$download_url_final" ]]; then
        for url_candidate in "${candidates[@]}"; do
            if [[ "$url_candidate" =~ https://[^\"]*veracrypt-${latest_version}.*amd64\.deb ]]; then
                download_url_final="$url_candidate"
                break
            fi
        done
    fi

    # Adjust launchpadlibrarian.net URLs
    if [[ "$download_url_final" =~ launchpadlibrarian\.net ]]; then
        local base_name
        base_name=$(basename "$download_url_final")
        base_name="${base_name//%2B/+}"
        download_url_final="https://launchpad.net/veracrypt/trunk/${latest_version}/+download/${base_name}"
    fi

    printf %s "$download_url_final"
}

_veracrypt::get_signature_url_from_page() {
    local page_content="$1"
    local latest_version="$2"
    local name="$3"

    local sig_url_final=""
    local -a candidates
    mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")

    # Look for version-specific sig/asc
    for url_candidate in "${candidates[@]}"; do
        if [[ "$url_candidate" =~ veracrypt-${latest_version}.*\.sig ]] ||
            [[ "$url_candidate" =~ veracrypt-${latest_version}.*\.asc ]]; then
            sig_url_final="$url_candidate"
            break
        fi
    done

    # Fallback: look for any .sig/.asc with "PGP" in it
    if [[ -z "$sig_url_final" ]]; then
        for url_candidate in "${candidates[@]}"; do
            if [[ "$url_candidate" =~ PGP ]] && [[ "$url_candidate" =~ \.(sig|asc) ]]; then
                sig_url_final="$url_candidate"
                break
            fi
        done
    fi

    printf %s "$sig_url_final"
}

veracrypt::check() {
    local app_config_json="$1"

    # Cache config JSON
    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        responses::emit_error "CONFIG_ERROR" "Failed to cache app info." "VeraCrypt" >&2
        return 1
    fi

    local name="${app_info["name"]}"
    local app_key="${app_info["app_key"]}"
    local installed_version="${app_info["installed_version"]}"
    local cache_key="${app_info["cache_key"]}"

    local gpg_key_id gpg_fingerprint download_url_base
    gpg_key_id=$(systems::fetch_cached_json "$cache_key" "gpg_key_id")
    gpg_fingerprint=$(systems::fetch_cached_json "$cache_key" "gpg_fingerprint")
    download_url_base=$(systems::fetch_cached_json "$cache_key" "download_url_base")

    # Fetch download page
    local url="$download_url_base"
    local page_content
    if ! page_content=$(networks::fetch_and_load "$url" "html" "$name" \
        "Failed to fetch download page for $name."); then
        responses::emit_error "NETWORK_ERROR" "Failed to fetch download page for $name." "$name" >&2
        return 1
    fi

    # Extract latest version
    local latest_version
    latest_version=$(_veracrypt::get_latest_version_from_page "$page_content")
    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Failed to detect latest version for $name." "$name" >&2
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
        responses::emit_error "NETWORK_ERROR" "No compatible DEB package found for $name." "$name" >&2
        return 1
    fi

    local validated_download_url
    if ! validated_download_url=$(networks::validate_url "$download_url_final"); then
        responses::emit_error "NETWORK_ERROR" \
            "Invalid or unresolved download URL for $name (url=$download_url_final)." "$name" >&2
        return 1
    fi

    local sig_url
    sig_url=$(_veracrypt::get_signature_url_from_page "$page_content" "$latest_version" "$name")

    responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
        download_url "$validated_download_url" \
        gpg_key_id "$gpg_key_id" \
        gpg_fingerprint "$gpg_fingerprint" \
        sig_url "$sig_url" \
        install_type "deb"

    return 0
}
