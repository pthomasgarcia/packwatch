#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/veracrypt.sh
# ==============================================================================
# DESCRIPTION:
#   This script provides functionality to check for the latest version of
#   VeraCrypt available for Ubuntu (amd64), fetch its metadata (URLs, GPG info),
#   and determine whether an update is required.
#
# AUTHOR:
#   PackWatch Framework Team
#
# DEPENDENCIES:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
#   - web_parsers.sh
#   - configs.sh
#
# INPUTS:
#   - An application configuration JSON string passed to `veracrypt::check`
#
# OUTPUTS:
#   - Structured JSON response on stdout for further processing
#   - Debug logs and error messages to stderr
#
# NOTES:
#   - Designed for Ubuntu x86_64 systems
#   - GPG signature verification support included
# ==============================================================================

# ==============================================================================
# SECTION: Global Constants
# ==============================================================================

readonly DOWNSTREAM="VeraCrypt"
readonly PLATFORM="Ubuntu"
readonly ARCHITECTURE="amd64"
readonly PACKAGE_TYPE="deb"

# File system constants
readonly CACHE_BASE_DIR="${HOME:-/tmp}/.cache/packwatch/artifacts"
readonly DOWNSTREAM_CACHE_DIR="${CACHE_BASE_DIR}/VeraCrypt"
readonly SIGNATURE_TYPE="sig"

# Pattern matching constants using sed -E compatible ERE
readonly DOWNSTREAM_VERSION_REGEX='([0-9]+\.[0-9]+\.[0-9]+)'
read -r -d '' DOWNSTREAM_VERSION_PATTERN << EOF
Latest Stable Release - ${DOWNSTREAM_VERSION_REGEX}
EOF

readonly PLATFORM_VERSION_REGEX='([0-9.]+)-amd64\.deb'
read -r -d '' PLATFORM_VERSION_PATTERN << EOF
veracrypt-VERSION-Ubuntu-${PLATFORM_VERSION_REGEX}
EOF

# Network constants
readonly UPSTREAM_BASE_URL="https://launchpad.net/veracrypt/trunk"
readonly UPSTREAM_SUFFIX="+download"

# Response labels
readonly SOURCE_DESCRIPTION="Official Download Page"
readonly CONTENT_TYPE="html"

# ==============================================================================
# SECTION: Helper Functions - Filename & URL Construction
# ==============================================================================

_veracrypt::build_package_filename() {
    : <<- 'DOC'
    Builds the expected package filename from upstream details.

    Arguments:
        $1 - upstream version (e.g. '1.25')
        $2 - platform version (e.g. '20.04')

    Returns:
        Standard output: full package name string like 
        'veracrypt-1.25-Ubuntu-20.04-amd64.deb'
DOC

    local upstream_version="$1"
    local platform_version="$2"

    local package_filename
    package_filename="${DOWNSTREAM,,}-${upstream_version}-"
    package_filename+="${PLATFORM}-${platform_version}-${ARCHITECTURE}."
    package_filename+="${PACKAGE_TYPE}"

    echo "$package_filename"
    return 0
}

_veracrypt::build_package_url() {
    : <<- 'DOC'
    Constructs the download URL for a specific package.

    Arguments:
        $1 - upstream version (e.g. '1.25')
        $2 - platform version (e.g. '20.04')

    Returns:
        Standard output: full URL to package
DOC

    local upstream_version="$1"
    local platform_version="$2"

    local package_filename
    package_filename=$(_veracrypt::build_package_filename "$upstream_version" \
        "$platform_version")
    local package_url
    package_url="${UPSTREAM_BASE_URL}/${upstream_version}/"
    package_url+="${UPSTREAM_SUFFIX}/${package_filename}"

    echo "$package_url"
    return 0
}

_veracrypt::build_signature_url() {
    : <<- 'DOC'
    Appends .sig suffix to generate the corresponding signature URL.

    Arguments:
        $1 - base package URL

    Returns:
        Standard output: signature URL (package_url.sig)
DOC

    local package_url="$1"

    echo "${package_url}.${SIGNATURE_TYPE}"
    return 0
}

# ==============================================================================
# SECTION: Helper Functions - Pattern Application & Cache Management
# ==============================================================================

_veracrypt::apply_pattern() {
    : <<- 'DOC'
    Replaces "VERSION" token in a regex pattern with an actual version string.

    Arguments:
        $1 - input regex pattern containing "VERSION"
        $2 - version string to replace

    Returns:
        Standard output: modified regex with VERSION replaced
DOC

    local pattern="$1"
    local version="$2"

    echo "${pattern//VERSION/$version}"
    return 0
}

_veracrypt::build_cache_dirname() {
    : <<- 'DOC'
    Generates the local directory path where artifacts for a given version 
    should be cached.

    Arguments:
        $1 - upstream version

    Returns:
        Standard output: absolute path to versioned directory
DOC

    local upstream_version="$1"

    echo "${DOWNSTREAM_CACHE_DIR}/v${upstream_version}"
    return 0
}

_veracrypt::build_signature_pathname() {
    : <<- 'DOC'
    Constructs the local path to a cached .sig file based on package details.

    Arguments:
        $1 - upstream version (e.g. '1.25')
        $2 - platform version (e.g. '20.04')

    Returns:
        Standard output: absolute path to signature file
DOC

    local upstream_version="$1"
    local platform_version="$2"

    local dirname
    dirname=$(_veracrypt::build_cache_dirname "$upstream_version")
    local package_filename
    package_filename=$(_veracrypt::build_package_filename "$upstream_version" \
        "$platform_version")

    echo "${dirname}/${package_filename}.${SIGNATURE_TYPE}"
    return 0
}

# ==============================================================================
# SECTION: Helper Functions - Signature Download
# ==============================================================================

_veracrypt::download_signature() {
    : <<- 'DOC'
    Downloads the signature file for a given version if not already cached 
    locally.

    Arguments:
        $1 - upstream version
        $2 - platform version

    Returns:
        Standard output: path to signature file (even if not downloaded)
DOC

    local upstream_version="$1"
    local platform_version="$2"

    local pathname
    pathname=$(_veracrypt::build_signature_pathname "$upstream_version" \
        "$platform_version")
    local dirname
    dirname=$(_veracrypt::build_cache_dirname "$upstream_version")
    mkdir -p "$dirname"

    if [[ -f "$pathname" ]]; then
        loggers::debug "VERACRYPT: Signature file already exists at $pathname"
        echo "$pathname"
        return 0
    fi

    local package_url
    package_url=$(_veracrypt::build_package_url "$upstream_version" \
        "$platform_version")
    local signature_url
    signature_url=$(_veracrypt::build_signature_url "$package_url")

    loggers::debug "VERACRYPT: Downloading signature from $signature_url to " \
        "$pathname"

    curl -sSL --fail -o "$pathname" "$signature_url" || {
        loggers::error "VERACRYPT: Failed to download signature from " \
            "$signature_url"
        return 1
    }

    loggers::debug "VERACRYPT: Successfully downloaded signature to $pathname"
    echo "$pathname"
    return 0
}

# ==============================================================================
# SECTION: Parsing Functions - Web Content
# ==============================================================================

_veracrypt::extract_upstream_version() {
    : <<- 'DOC'
    Parses and returns the latest upstream VeraCrypt version found in the HTML 
    page.

    Arguments:
        $1 - HTML content string

    Returns:
        Standard output: upstream version number
DOC

    local page_content="$1"

    local upstream_version
    upstream_version=$(
        sed -E -n "s/.*${DOWNSTREAM_VERSION_PATTERN}.*/\1/p" \
            <<< "$page_content" | head -n1
    )

    if [[ -n "$upstream_version" ]]; then
        echo "$upstream_version"
    fi

    return 0
}

_veracrypt::extract_platform_version() {
    : <<- 'DOC'
    Finds the latest compatible Ubuntu platform version embedded in the release 
    page HTML.

    Arguments:
        $1 - HTML content
        $2 - upstream version

    Returns:
        Standard output: platform version (e.g. '20.04')
DOC

    local page_content="$1"
    local upstream_version="$2"

    local pattern
    pattern=$(_veracrypt::apply_pattern "$PLATFORM_VERSION_PATTERN" \
        "$upstream_version")

    local platform_version
    platform_version=$(
        sed -E -n "s/.*${pattern}.*/\1/p" <<< "$page_content" |
            sort -V | tail -n1
    )

    if [[ -n "$platform_version" ]]; then
        echo "$platform_version"
    fi

    return 0
}

# ==============================================================================
# SECTION: Parsing Functions - Configuration
# ==============================================================================

_veracrypt::parse_config() {
    : <<- 'DOC'
    Parses the application config JSON and extracts all needed fields.

    Arguments:
        $1 - raw JSON string of app config
    Outputs:
        name, installed_version, cache_key, gpg_key_id, gpg_fingerprint, 
        download_base_url
DOC

    local app_config="$1"

    local -A app_info

    if ! configs::get_cached_app_info "$app_config" app_info; then
        responses::emit_error "CONFIG_ERROR" "Failed to parse app info cache." \
            "VeraCrypt" >&2
        return 1
    fi

    local key
    for key in name installed_version cache_key; do
        echo "${app_info[$key]}"
    done

    local cache_key="${app_info["cache_key"]}"
    for key in gpg_key_id gpg_fingerprint download_base_url; do
        systems::fetch_cached_json "$cache_key" "$key"
    done

    return 0
}

# ==============================================================================
# SECTION: Parsing Functions - Upstream Details
# ==============================================================================

_veracrypt::parse_upstream_details() {
    : <<- 'DOC'
    Fetches webpage, parses primary metadata like version and platform, and
    retrieves the package download size.

    Arguments:
        $1 - base download URL
    Outputs:
        upstream_version, platform_version, download_size
DOC

    local download_base_url="$1"
    local page_content

    if ! page_content=$(networks::fetch_and_load "$download_base_url" \
        "$CONTENT_TYPE" "$DOWNSTREAM" "Failed fetching download page for" \
        "$DOWNSTREAM"); then
        responses::emit_error "NETWORK_ERROR" \
            "Network issue fetching page for $DOWNSTREAM" \
            "$DOWNSTREAM" >&2
        return 1
    fi

    local upstream_version
    upstream_version=$(_veracrypt::extract_upstream_version \
        "$page_content")

    if validators::is_empty "$upstream_version"; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to locate latest version information. " \
            "May require format update." "$DOWNSTREAM" >&2
        return 1
    fi

    local platform_version
    platform_version=$(_veracrypt::extract_platform_version \
        "$page_content" "$upstream_version")

    if validators::is_empty "$platform_version"; then
        responses::emit_error "PLATFORM_MISSING" \
            "No matching ${PLATFORM} binaries found for " \
            "version=${upstream_version}" "$DOWNSTREAM" >&2
        return 1
    fi

    # Attempt to fetch download size early
    local download_size=""
    if download_size=$(_veracrypt::fetch_download_size \
        "$upstream_version" "$platform_version"); then
        loggers::debug "VERACRYPT: Download size fetched: $download_size bytes."
    else
        loggers::debug "VERACRYPT: Failed to fetch download size during initial check."
    fi

    echo "$upstream_version"
    echo "$platform_version"
    echo "$download_size"
    return 0
}

# ==============================================================================
# SECTION: Update Status Determination
# ==============================================================================

_veracrypt::compare_versions() {
    : <<- 'DOC'
    Compares installed version against latest and returns appropriate status.

    Arguments:
        $1 - installed version string
        $2 - upstream version string
    Outputs:
        update_status ("no_update", "update_available")
DOC

    local installed_version="$1"
    local upstream_version="$2"

    installed_version=$(versions::strip_prefix "$installed_version")
    upstream_version=$(versions::strip_prefix "$upstream_version")

    loggers::debug "VERACRYPT: Installed v=$installed_version vs Latest " \
        "v=$upstream_version"
    responses::determine_status "$installed_version" "$upstream_version"
    return 0
}

# ==============================================================================
# SECTION: Response Generation
# ==============================================================================

_veracrypt::emit_response() {
    : <<- 'DOC'
    Constructs response arguments for success emit.

    Arguments:
        $1 - update_status
        $2 - upstream_version
        $3 - platform_version
        $4 - download_base_url
        $5 - gpg_key_id
        $6 - gpg_fingerprint
        $7 - sig_path (optional)
        $8 - content_length (optional)
    Outputs:
        formatted argument array for responses::emit_success
DOC

    local update_status="$1"
    local upstream_version="$2"
    local platform_version="$3"
    local download_base_url="$4"
    local gpg_key_id="$5"
    local gpg_fingerprint="$6"
    local sig_path="$7"
    local content_length="${8:-}"

    local download_final_url
    download_final_url=$(_veracrypt::build_package_url "$upstream_version" \
        "$platform_version")

    local validated_download_url
    if ! validated_download_url=$(networks::validate_url \
        "$download_final_url"); then
        responses::emit_error "NETWORK_ERROR" \
            "Download link appears invalid or unreachable " \
            "($download_final_url). $DOWNSTREAM" >&2
        return 1
    fi

    local -a response_args=(
        "$update_status"
        "$upstream_version"
        "$PACKAGE_TYPE"
        "${SOURCE_DESCRIPTION}"
        download_url "$validated_download_url"
        gpg_key_id "$gpg_key_id"
        gpg_fingerprint "$gpg_fingerprint"
        install_type "$PACKAGE_TYPE"
    )

    if [[ -n "$sig_path" && -f "$sig_path" ]]; then
        response_args+=(sig_path "$sig_path")
    fi

    if [[ -n "$content_length" ]]; then
        response_args+=(content_length "$content_length")
    fi

    responses::emit_success "${response_args[@]}"
    return 0
}

# ==============================================================================
# SECTION: Helper Functions - Download Metadata
# ==============================================================================

_veracrypt::fetch_download_size() {
    : << 'DOC'
    Performs a HEAD request to retrieve the Content-Length (expected download
    size) in bytes for a specific VeraCrypt package.

    Arguments:
        $1 - upstream version (e.g. '1.26.24')
        $2 - platform version (e.g. '22.04')

    Returns:
        Standard output: content length in bytes (if available)
DOC

    local upstream_version="$1"
    local platform_version="$2"

    local package_url
    package_url=$(_veracrypt::build_package_url "$upstream_version" "$platform_version")

    # One-step HEAD request + parse Content-Length directly
    local content_length
    content_length=$(
        curl -sI -L "$package_url" |
            awk '/[Cc]ontent-[Ll]ength/ {print $2}' | tr -d '\r'
    )

    # Fail fast if no result found
    if [[ -z "$content_length" ]]; then
        loggers::debug "VERACRYPT: Could not determine Content-Length for $package_url"
        return 1
    fi

    echo "$content_length"
    return 0
}

# ==============================================================================
# SECTION: Main Function
# ==============================================================================

veracrypt::check() {
    : <<- 'DOC'
    Main function that checks if there is an update available for VeraCrypt 
    based on the app config.

    Arguments:
        $1 - application config JSON as a string

    Stdout:
        A structured JSON response indicating status, version, URL, signature 
        path, etc.

    Stderr:
        Logs and diagnostic information.
DOC

    local app_config="$1"

    # Parse application configuration to extract key details
    if ! IFS=$'\n' read -rd '' name installed_version cache_key \
        gpg_key_id gpg_fingerprint download_base_url < <(
            _veracrypt::parse_config "$app_config" && printf '\0'
        ); then
        return 1
    fi

    # Validate essential configuration parameters
    if validators::is_empty "$download_base_url"; then
        responses::emit_error "CONFIG_ERROR" "Missing 'download_base_url' in " \
            "config." "$name" >&2
        return 1
    fi

    # Fetch and parse upstream details (latest version and platform version)
    if ! IFS=$'\n' read -rd '' upstream_version platform_version download_size < <(
        _veracrypt::parse_upstream_details "$download_base_url" && printf '\0'
    ); then
        return 1
    fi

    # Determine if an update is available
    local update_status
    update_status=$(_veracrypt::compare_versions "$installed_version" \
        "$upstream_version")

    # If no update is available, emit success response and exit
    if [[ "$update_status" == "no_update" ]]; then
        responses::emit_success "$update_status" "$upstream_version" \
            "$PACKAGE_TYPE" "${SOURCE_DESCRIPTION}" \
            gpg_key_id "$gpg_key_id" \
            gpg_fingerprint "$gpg_fingerprint"
        return 0
    fi

    # Attempt to download the signature file for verification
    local sig_path=""
    local downloaded_sig_path

    if downloaded_sig_path=$(_veracrypt::download_signature \
        "$upstream_version" "$platform_version"); then
        if [[ -f "$downloaded_sig_path" ]]; then
            sig_path="$downloaded_sig_path"
        else
            sig_path=""
        fi
    else
        loggers::debug "VERACRYPT: Signature download failed; continuing " \
            "without verification."
    fi

    # Generate and emit the final response data
    _veracrypt::emit_response \
        "$update_status" "$upstream_version" "$platform_version" \
        "$download_base_url" "$gpg_key_id" "$gpg_fingerprint" "$sig_path" \
        "$download_size"
    return 0
}
