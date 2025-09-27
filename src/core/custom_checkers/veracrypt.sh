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

# Constants for version and URL pattern matching
readonly VERACRYPT_VERSION_PATTERN='Latest Stable Release - \K[0-9]+\.[0-9]+\.[0-9]+'
readonly VERACRYPT_UBUNTU_PATTERN='veracrypt-VERSION-Ubuntu-[0-9.]+-amd64\.deb([?#]|$)'
readonly VERACRYPT_GENERIC_PATTERN='veracrypt-VERSION.*amd64\.deb([?#]|$)'
readonly VERACRYPT_SIG_SPECIFIC_PATTERN='veracrypt-VERSION.*\.(sig|asc)'
readonly VERACRYPT_SIG_GENERIC_PATTERN='PGP.*\.(sig|asc)'
readonly LAUNCHPAD_DOMAIN='launchpadlibrarian\.net'

# Apply a placeholder replacement in a given pattern with a version string.
# $1: Pattern with "VERSION" placeholder
# $2: Version to substitute into pattern
# Returns: Resolved regex pattern
_veracrypt::apply_pattern() {
    local pattern="$1"
    local version="$2"
    echo "${pattern//VERSION/$version}"
	return 0
}

# Transforms Launchpad redirect-style URLs to direct download links.
# $1: Raw URL possibly from launchpadlibrarian.net
# $2: VeraCrypt version used in constructing destination URL
# Returns: Transformed URL if match, else original URL
_veracrypt::transform_launchpad_url() {
    local url="$1"
    local version="$2"

    if [[ "$url" =~ $LAUNCHPAD_DOMAIN ]]; then
        local base_name
        base_name=$(basename "$url")
        base_name="${base_name//%2B/+}"
        url="https://launchpad.net/veracrypt/trunk/${version}/+download/${base_name}"
        loggers::debug "VERACRYPT: Transformed launchpadlibrarian URL → $url"
    fi

    echo "$url"
	return 0
}

# Extracts the latest VeraCrypt version from a fetched HTML page.
# $1: Fetched page content as string (HTML)
# Returns: Version string (e.g. 1.25.9) or empty on failure
_veracrypt::get_latest_version_from_page() {
    local page_content="$1"
    local version
    version=$(echo "$page_content" | grep -Po "$VERACRYPT_VERSION_PATTERN" | head -n1)
    [[ -n "$version" ]] && echo "$version"
	return 0
}

# Searches for a suitable download URL from the provided HTML content.
# Prioritizes Ubuntu-specific DEB then generic amd64 DEB.
# $1: Fetched page content (HTML string)
# $2: Version to match against
# Returns: First matching download URL or exits with error
_veracrypt::find_download_url() {
    local page_content="$1"
    local version="$2"

    # Extract all URLs from page content
    local -a candidates
    mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")

    # Try Ubuntu-specific pattern first
    local pattern
    pattern=$(_veracrypt::apply_pattern "$VERACRYPT_UBUNTU_PATTERN" "$version")
    for url in "${candidates[@]}"; do
        if [[ "$url" =~ $pattern ]]; then
            echo "$url"
            return 0
        fi
    done

    # Fall back to generic amd64 file pattern
    pattern=$(_veracrypt::apply_pattern "$VERACRYPT_GENERIC_PATTERN" "$version")
    for url in "${candidates[@]}"; do
        if [[ "$url" =~ $pattern ]]; then
            echo "$url"
            return 0
        fi
    done

    # If we get here, no download found
    loggers::debug "VERACRYPT: No compatible DEB package found for version $version"
    return 1
}

# Finds a signature file URL associated with the latest version.
# Checks for version-specific signature first, then generic ones.
# $1: Page content (HTML string)
# $2: Version string
# Returns: Signature URL or empty string if not found (non-fatal)
_veracrypt::find_signature_url() {
    local page_content="$1"
    local version="$2"

    local -a candidates
    mapfile -t candidates < <(web_parsers::extract_urls_from_html <(echo "$page_content") "")

    # Prioritize version-specific signature (.sig/.asc)
    local pattern
    pattern=$(_veracrypt::apply_pattern "$VERACRYPT_SIG_SPECIFIC_PATTERN" "$version")
    for url in "${candidates[@]}"; do
        if [[ "$url" =~ $pattern ]]; then
            echo "$url"
            return 0
        fi
    done

    # Fall back to any PGP-related signature file
    for url in "${candidates[@]}"; do
        if [[ "$url" =~ $VERACRYPT_SIG_GENERIC_PATTERN ]]; then
            echo "$url"
            return 0
        fi
    done

    # Optional, so default behavior is success
    return 0
}

# Main updater check entrypoint for VeraCrypt.
# Parses configuration, detects latest release, determines update status,
# and outputs structured JSON response for downstream consumption.
# $1: Application-specific configuration JSON string
veracrypt::check() {
    local app_config_json="$1"

    # --------------------------------------------------------------------------
    # STEP 1: Load and validate configuration
    # --------------------------------------------------------------------------
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

    if validators::is_empty "$download_url_base"; then
        responses::emit_error "CONFIG_ERROR" "Missing download URL base in configuration." "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 2: Fetch the VeraCrypt download page HTML
    # --------------------------------------------------------------------------
    local page_content
    if ! page_content=$(networks::fetch_and_load "$download_url_base" "html" "$name" \
        "Failed to fetch download page for $name."); then
        responses::emit_error "NETWORK_ERROR" "Failed to fetch download page for $name." "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 3: Extract the latest version from the HTML
    # --------------------------------------------------------------------------
    local latest_version
    latest_version=$(_veracrypt::get_latest_version_from_page "$page_content")
    if validators::is_empty "$latest_version"; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to detect latest version for $name. Check if page format has changed." "$name" >&2
        return 1
    fi

    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version")

    loggers::debug "VERACRYPT: installed_version='$installed_version' latest_version='$latest_version'"

    # --------------------------------------------------------------------------
    # STEP 4: Determine update status
    # --------------------------------------------------------------------------
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    if [[ "$output_status" == "no_update" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" "Official Download Page" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # --------------------------------------------------------------------------
    # STEP 5: Locate and validate the download and signature URLs
    # --------------------------------------------------------------------------
    local download_url_final
    if ! download_url_final=$(_veracrypt::find_download_url "$page_content" "$latest_version"); then
        responses::emit_error "NETWORK_ERROR" \
            "No compatible DEB package found for $name version $latest_version." "$name" >&2
        return 1
    fi

    download_url_final=$(_veracrypt::transform_launchpad_url "$download_url_final" "$latest_version")

    local validated_download_url
    if ! validated_download_url=$(networks::validate_url "$download_url_final"); then
        responses::emit_error "NETWORK_ERROR" \
            "Invalid or unresolved download URL for $name (url=$download_url_final)." "$name" >&2
        return 1
    fi

    local sig_url
    sig_url=$(_veracrypt::find_signature_url "$page_content" "$latest_version")

    # --------------------------------------------------------------------------
    # STEP 6: Construct and emit the final structured response
    # --------------------------------------------------------------------------
    local -a response_args=(
        "$output_status" "$latest_version" "deb" "Official Download Page"
        download_url "$validated_download_url"
        gpg_key_id "$gpg_key_id"
        gpg_fingerprint "$gpg_fingerprint"
        install_type "deb"
    )

    [[ -n "$sig_url" ]] && response_args+=(sig_url "$sig_url")

    responses::emit_success "${response_args[@]}"
    return 0
}
