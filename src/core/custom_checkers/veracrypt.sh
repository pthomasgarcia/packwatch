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

readonly DOWNSTREAM_NAME="VeraCrypt"

readonly PLATFORM_NAME="Ubuntu"
readonly ARCHITECTURE="amd64"
readonly PACKAGE_TYPE="deb"

# File system constants
readonly SIGNATURE_TYPE="sig"

# Pattern matching constants
readonly VERACRYPT_VERSION_PATTERN='Latest Stable Release - \K[0-9]+\.[0-9]+\.[0-9]+'
readonly VERACRYPT_PLATFORM_VERSION_PATTERN='veracrypt-VERSION-Ubuntu-\K[0-9.]+(?=-amd64\.deb)'

# Network constants
readonly UPSTREAM_BACKEND_BASE_URL="https://launchpad.net/veracrypt/trunk"
readonly UPSTREAM_BACKEND_SUFFIX="+download"

# Response labels
readonly SOURCE_DESCRIPTION="Official Download Page"
readonly CONTENT_TYPE="html"

# Build package filename for a given version and platform
_veracrypt::build_package_filename() {
    local version_upstream="$1"
    local platform_version="$2"

    echo "${DOWNSTREAM_NAME,,}-${version_upstream}-${PLATFORM_NAME}-${platform_version}-${ARCHITECTURE}.${PACKAGE_TYPE}"
}

# Build full canonical package URL
_veracrypt::build_package_url() {
    local version_upstream="$1"
    local platform_version="$2"
    local package_filename

    package_filename=$(_veracrypt::build_package_filename "$version_upstream" "$platform_version")

    echo "${UPSTREAM_BACKEND_BASE_URL}/${version_upstream}/${UPSTREAM_BACKEND_SUFFIX}/${package_filename}"
}

# Build signature URL directly from package URL
_veracrypt::build_signature_url() {
    local package_url="$1"
    echo "${package_url}.${SIGNATURE_TYPE}"
}

# Apply version placeholders into a given regex template
# $1: Pattern containing VERSION placeholder(s)
# $2: Actual version string to insert
# Returns: Resolved regex-compatible pattern
_veracrypt::apply_pattern() {
    local pattern="${1:?Pattern required}"
    local version="${2:?Version required}"
    echo "${pattern//VERSION/$version}"
    return 0
}

# Downloads the latest Ubuntu amd64 signature file to dirname
# $1: VeraCrypt version_upstream
# $2: Platform version
# Returns: Local path to downloaded signature file
_veracrypt::download_signature() {
    local version_upstream="$1"
    local platform_version="$2"

    local dirname="${HOME}/.cache/packwatch/artifacts/VeraCrypt/v${version_upstream}"
    mkdir -p "$dirname"

    local package_url
    package_url=$(_veracrypt::build_package_url "$version_upstream" "$platform_version")

    local signature_url
    signature_url=$(_veracrypt::build_signature_url "$package_url")

    local package_filename
    package_filename=$(_veracrypt::build_package_filename "$version_upstream" "$platform_version")

    local pathname="${dirname}/${package_filename}.${SIGNATURE_TYPE}"

    if [[ -f "$pathname" ]]; then
        loggers::debug "VERACRYPT: Signature file already exists at $pathname"
        echo "$pathname"
        return 0
    fi

    loggers::debug "VERACRYPT: Downloading signature from $signature_url to $pathname"

    if ! curl -sSL -o "$pathname" "$signature_url"; then
        loggers::debug "VERACRYPT: Failed to download signature"
        return 1
    fi

    loggers::debug "VERACRYPT: Successfully downloaded signature to $pathname"
    echo "$pathname"
    return 0
}

# Extracts the latest VeraCrypt version from a fetched HTML page.
# $1: Fetched page content as string (HTML)
# Returns: Version string (e.g. 1.25.9) or empty on failure
_veracrypt::get_version_upstream_from_page() {
    local page_content="$1"
    local version
    version=$(echo "$page_content" | grep -Po "$VERACRYPT_VERSION_PATTERN" | head -n1)
    [[ -n "$version" ]] && echo "$version"
    return 0
}

# Extracts the platform version from the HTML page content
# $1: Page content as raw HTML string
# $2: Target detected version
# Returns: Platform version string (e.g. 20.04, 22.04) or empty on failure
_veracrypt::get_platform_version_from_page() {
    local page_content="$1"
    local version_upstream="$2"

    local pattern
	pattern=$(_veracrypt::apply_pattern "$VERACRYPT_PLATFORM_VERSION_PATTERN" "$version_upstream")
    local platform_version
    platform_version=$(echo "$page_content" | grep -Po "$pattern" | sort -V | tail -n1)
    [[ -n "$platform_version" ]] && echo "$platform_version"
    return 0
}

# Main update checker function implementing full VeraCrypt version detection workflow
# $1: JSON-formatted application configuration blob used by downstream dependencies
# Returns: Structured JSON output via `responses::emit_success` / `responses::emit_error`
veracrypt::check() {
    local app_config_json="${1:?App config JSON required}"

    # --------------------------------------------------------------------------
    # STEP 1: Parse and validate configuration data
    # --------------------------------------------------------------------------
    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        responses::emit_error "CONFIG_ERROR" "Failed to parse app info cache." "VeraCrypt" >&2
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
        responses::emit_error "CONFIG_ERROR" "Missing 'download_url_base' in config." "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 2: Fetch the official downloads HTML page
    # --------------------------------------------------------------------------
    local page_content
    if ! page_content=$(networks::fetch_and_load "$download_url_base" "$CONTENT_TYPE" "$name" \
        "Failed fetching download page for $name"); then
        responses::emit_error "NETWORK_ERROR" "Network issue fetching page for $name" "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 3: Detect upstream release version
    # --------------------------------------------------------------------------
    local version_upstream
    version_upstream=$(_veracrypt::get_version_upstream_from_page "$page_content")
    if validators::is_empty "$version_upstream"; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to locate latest version information for $name. May require format update." \
            "$name" >&2
        return 1
    fi

    installed_version=$(versions::strip_prefix "$installed_version")
    version_upstream=$(versions::strip_prefix "$version_upstream")
    loggers::debug "VERACRYPT: Installed v=$installed_version vs Latest v=$version_upstream"

    # --------------------------------------------------------------------------
    # STEP 4: Compare local version against upstream
    # --------------------------------------------------------------------------
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$version_upstream")

    if [[ "$output_status" == "no_update" ]]; then
        responses::emit_success "$output_status" "$version_upstream" "$PACKAGE_TYPE" "${SOURCE_DESCRIPTION}" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # --------------------------------------------------------------------------
    # STEP 5: Extract platform version
    # --------------------------------------------------------------------------
    local platform_version
    platform_version=$(_veracrypt::get_platform_version_from_page "$page_content" "$version_upstream")
    if validators::is_empty "$platform_version"; then
        responses::emit_error "PARSING_ERROR" \
            "No ${PLATFORM_NAME} build found matching version=$version_upstream" "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 6: Construct and validate binary download link
    # --------------------------------------------------------------------------
    local download_url_final
    download_url_final=$(_veracrypt::build_package_url "$version_upstream" "$platform_version")

    local validated_download_url
    if ! validated_download_url=$(networks::validate_url "$download_url_final"); then
        responses::emit_error "NETWORK_ERROR" \
            "Download link appears invalid or unreachable ($download_url_final)" "$name" >&2
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 7: Retrieve signed signature file associated with this release
    # --------------------------------------------------------------------------
    local sig_path
    sig_path=$(_veracrypt::download_signature "$version_upstream" "$platform_version")
    if [[ ! -f "$sig_path" ]]; then
        responses::emit_warning "VERACRYPT: Signature download failed; ignoring..."
    fi

    # --------------------------------------------------------------------------
    # STEP 8: Emit structured successful response JSON blob
    # --------------------------------------------------------------------------
    local -a response_args=(
        "$output_status" "$version_upstream" "$PACKAGE_TYPE" "${SOURCE_DESCRIPTION}"
        download_url "$validated_download_url"
        gpg_key_id "$gpg_key_id"
        gpg_fingerprint "$gpg_fingerprint"
        install_type "$PACKAGE_TYPE"
    )
    [[ -n "$sig_path" && -f "$sig_path" ]] && response_args+=(sig_path "$sig_path")

    responses::emit_success "${response_args[@]}"
    return 0
}
