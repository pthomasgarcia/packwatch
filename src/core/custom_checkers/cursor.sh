#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/cursor.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic for updating Cursor IDE binary (Debian/AppImage).
#   - Handles both API-driven discovery and HTML parsing fallback.
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

# Constants
readonly CURSOR_API_ENDPOINT="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
readonly CURSOR_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
readonly CURSOR_DEFAULT_APPIMAGE_NAME="cursor.AppImage"
readonly CURSOR_DEFAULT_DEB_NAME="cursor.deb"
readonly CURSOR_SUPPORTED_TYPES=("appimage" "deb")

# Validates presence of input data
# $1: Input value
# $2: Field name for logging context
_cursor::validate_input() {
    local input="$1" field="$2"
    if [[ -z "$input" ]]; then
        loggers::debug "CURSOR: Missing required $field"
        return 1
    fi
    return 0
}

# Checks and validates installation path config
# $1: Configured install path string
# $2: Program name
# $3: Config hash
_cursor::validate_install_path_config() {
    local path_str="$1"
    local name="$2"
    if ! _cursor::validate_input "$path_str" "install_path_config"; then
        responses::emit_error "PARSING_ERROR" "Install path unresolved for $name." "$name"
        return 1
    fi
    return 0
}

# Expands environment variables in user-specified path, ensures parent dirs exist
# $1: Base install path string (may contain environment variables e.g., $HOME)
# $2: Artifact filename
# Returns: Fully expanded path where binary will be placed
_cursor::resolve_install_path() {
    local install_path_config="$1"
    local artifact_filename="$2"

    # Expand $HOME only
    local expanded_path
    expanded_path="$(printf '%s' "$install_path_config" | sed "s|\$HOME|$HOME|g")"
    [[ -z "$expanded_path" ]] && expanded_path="$HOME"

    if ! mkdir -p -- "$expanded_path"; then
        responses::emit_error "FILESYSTEM_ERROR" "Cannot access/install to $expanded_path" "cursor"
        return 1
    fi

    printf %s "${expanded_path%/}/${artifact_filename}"
}

# ------------------------------------------------------------------------------
# Metadata Parsing Helpers
# ------------------------------------------------------------------------------

# Fetch HTTP response headers via cURL HEAD request
# $1: Resource URL
# $2: Destination header file
# Returns success/failure state of remote fetch
_cursor::_download::fetch_headers_for_url() {
    local url="$1"
    local dst="$2"
    if ! curl -fsSIL "$url" -A "$CURSOR_USER_AGENT" -D "$dst" -o /dev/null; then
        loggers::debug "CURSOR: Failed fetching headers for $url"
        return 1
    fi
    return 0
}

# Traverse HTML markup to locate downloadable asset links
# $1: Temp dir holding downloaded documents
# $2: Last known redirect URL from upstream endpoint
_cursor::_download::_html_scraper::extract_best_asset_url() {
    local workdir="$1"
    local baseurl="$2"

    local html_doc="$workdir/page.html"
    if ! networks::download_file "$baseurl" "$html_doc" "" "" true -H "User-Agent: $CURSOR_USER_AGENT"; then
        loggers::debug "CURSOR: Failed downloading landing page"
        return 1
    fi

    local refresh_target
    refresh_target="$(web_parsers::check_meta_refresh "$html_doc")"
    if [[ -n "$refresh_target" ]]; then
        # Resolve meta refresh target and fetch headers to get Content-Length
        local resolved_asset_url
        if ! resolved_asset_url="$(networks::get_effective_url "$refresh_target")"; then
            loggers::debug "CURSOR: Meta refresh target does not resolve cleanly"
            return 1
        fi

        local head_file="$workdir/asset-head.tmp"
        if ! _cursor::_download::fetch_headers_for_url "$resolved_asset_url" "$head_file"; then
            return 1
        fi

        local -a parsed_array
        mapfile -t parsed_array < <(web_parsers::parse_metadata_from_headers "$head_file" "$resolved_asset_url")

        local asset_name
        asset_name="$(web_parsers::parse_content_disposition "${parsed_array[1]:-}")"
        asset_name="${asset_name:-$(basename "$resolved_asset_url")}"

        local detected_type
        detected_type="$(web_parsers::detect_artifact_type "$asset_name")"

        printf '%s\n%s\n%s\n%s\n' "$resolved_asset_url" "${parsed_array[3]:-}" "$detected_type" "${parsed_array[4]:-}"
        return 0
    fi

    local -a hrefs_map
    mapfile -t hrefs_map < <(web_parsers::extract_urls_from_html "$html_doc" "$baseurl")
    local selected_link
    if ! selected_link="$(web_parsers::select_best_url "${hrefs_map[@]}")"; then
        loggers::debug "CURSOR: No viable asset link discovered during parsing"
        return 1
    fi

    local resolved_asset_url
    if ! resolved_asset_url="$(networks::get_effective_url "$selected_link")"; then
        loggers::debug "CURSOR: Asset link does not resolve cleanly"
        return 1
    fi

    local head_file="$workdir/asset-head.tmp"
    if ! _cursor::_download::fetch_headers_for_url "$resolved_asset_url" "$head_file"; then
        return 1
    fi

    local -a parsed_array
    mapfile -t parsed_array < <(web_parsers::parse_metadata_from_headers "$head_file" "$resolved_asset_url")

    local asset_name
    asset_name="$(web_parsers::parse_content_disposition "${parsed_array[1]:-}")"
    asset_name="${asset_name:-$(basename "$resolved_asset_url")}"

    local detected_type
    detected_type="$(web_parsers::detect_artifact_type "$asset_name")"

    printf '%s\n%s\n%s\n%s\n' "$resolved_asset_url" "${parsed_array[3]:-}" "$detected_type" "${parsed_array[4]:-}"
}

## API-based metadata fetching
# $1: Temp working dir
# $2: Log label ("Cursor")
# Outputs: url\nversion\ntype\ncontent-length OR exits
_cursor::_download::from_api() {
    local tmpdir="$1"
    local name="$2"

    local api_response="$tmpdir/api.json"
    if ! networks::download_file "$CURSOR_API_ENDPOINT" "$api_response" "" "" false; then
        loggers::debug "CURSOR: Failed downloading JSON API"
        return 1
    fi

    if ! systems::is_valid_json "$api_response"; then
        loggers::debug "CURSOR: Received invalid JSON at $CURSOR_API_ENDPOINT"
        return 1
    fi

    # Prefer the AppImage asset
    local version url content_len=""
    version=$(jq -r '.version // empty' "$api_response" 2>/dev/null)
    url=$(jq -r '.downloadUrl // empty' "$api_response" 2>/dev/null)

    if [[ -z "$version" || -z "$url" ]]; then
        loggers::debug "CURSOR: JSON missing version or downloadUrl"
        return 1
    fi

    # 🔑 Perform HEAD request on downloadUrl to capture Content-Length and ETag
    # We pipe curl output (headers on stdout via -I) to awk
    local headers
    if ! headers=$(curl -sI -A "$CURSOR_USER_AGENT" "$url"); then
        loggers::debug "CURSOR: Failed HEAD request for metadata"
        return 1
    fi

    local content_len etag
    content_len=$(echo "$headers" | awk '/[Cc]ontent-[Ll]ength/ {print $2}' | tr -d '\r')
    etag=$(echo "$headers" | awk '/[Ee][Tt]ag/ {print $2}' | tr -d '\r"' | sed 's/^W\///') # Strip quotes and weak indicator

    # Detect artifact type from filename in URL
    local inferred_type
    inferred_type="$(web_parsers::detect_artifact_type "$(basename -- "$url")")"

    printf '%s\n%s\n%s\n%s\n%s\n' "$url" "$version" "$inferred_type" "$content_len" "$etag"
}

# Attempt manual traversal of download pages + redirects and extract assets
# $1: Working temp directory
# $2: Log label ("Cursor")
# Outputs: url\nversion\ntype\nlength
_cursor::_download::from_html_redirects() {
    local tmpdir="$1"
    local name="$2"

    loggers::warn "CURSOR: Fallback route engaged – manual parsing mode enabled."

    local final_url
    if ! final_url="$(networks::get_effective_url "$CURSOR_API_ENDPOINT")"; then
        loggers::debug "CURSOR: Unresolveable redirect chain"
        return 1
    fi

    local header_file="$tmpdir/headers.txt"
    if ! _cursor::_download::fetch_headers_for_url "$final_url" "$header_file"; then
        loggers::debug "CURSOR: Initial attempt to grab headers failed."
        return 1
    fi

    local -a lines
    mapfile -t lines < <(web_parsers::parse_metadata_from_headers "$header_file" "$final_url")

    declare -A meta=(
        [url]="$final_url"
        [version]="${lines[3]:-}"
        [type]="$(web_parsers::detect_artifact_type "${lines[2]:-$(basename "$final_url")}")"
        [length]="${lines[4]:-}"
    )

    # If result doesn’t pass muster, fall back manually scanning
    if [[ ("${meta[type]}" != "appimage" && "${meta[type]}" != "deb") || -z "${meta[version]}" ]]; then
        loggers::debug "CURSOR: Inconclusive parse, proceeding to deep html walk..."
        _cursor::_download::_html_scraper::extract_best_asset_url "$tmpdir" "$final_url"
    else
        printf '%s\n%s\n%s\n%s\n' "${meta[url]}" "${meta[version]}" "${meta[type]}" "${meta[length]}"
    fi
}

# Top-level resolver that orchestrates fetching process
# $1: Work directory location
# $2: Label display name ("Cursor")
# Results emitted as lines: url\nversion\ntype\nsize
_cursor::_download::resolve() {
    local tempdir="$1"
    local label="$2"

    local result
    if result=$(_cursor::_download::from_api "$tempdir" "$label"); then
        local -a rdata
        mapfile -t rdata <<<"$result"

        local url="${rdata[0]:-}"
        local ver="${rdata[1]:-}"
        local type="${rdata[2]:-}"
        local leng="${rdata[3]:-}"
        local etag="${rdata[4]:-}"

        # If API didn't provide type, infer from URL if available
        if [[ -z "$type" && -n "$url" ]]; then
            type="$(web_parsers::detect_artifact_type "$(basename -- "$url")")"
        fi

        printf '%s\n%s\n%s\n%s\n%s\n' "$url" "$ver" "$type" "$leng" "$etag"
        return 0
    fi

    _cursor::_download::from_html_redirects "$tempdir" "$label"
}

# Verifies artifact compatibility with allowed types list
# $1: Candidate type ('deb','appimage')
# $2: Application name
_cursor::validate_artifact_type() {
    local candidate="$1"
    local appname="$2"

    local t
    for t in "${CURSOR_SUPPORTED_TYPES[@]}"; do
        if [[ "$candidate" == "$t" ]]; then
            return 0
        fi
    done

    responses::emit_error "PLATFORM_UNSUPPORTED" "Type '$candidate' unsupported for $appname" "$appname"
    return 1
}

# Provides default filename depending on artifact kind
# $1: Detected package type ("appimage"/"deb")
# Returns: Suggested filename ("cursor.AppImage" etc.)
_cursor::get_artifact_filename() {
    case "$1" in
    appimage) printf %s "$CURSOR_DEFAULT_APPIMAGE_NAME" ;;
    deb) printf %s "$CURSOR_DEFAULT_DEB_NAME" ;;
    *)
        loggers::error "CURSOR: Cannot resolve artifact type for filename"
        return 1
        ;;
    esac
}

# Entry point to check for available Cursor upgrades
# Fetches latest stable version and returns structured metadata
# for downstream consumption.
# $1: Application JSON configuration blob
cursor::check() {
    local json_cfg="$1"

    # --------------------------------------------------------------------------
    # STEP 1: Load and validate configuration
    # --------------------------------------------------------------------------
    if ! _cursor::validate_input "$json_cfg" "app configuration"; then
        responses::emit_error "CONFIG_ERROR" "Missing cursor app config." "Cursor"
        return 1
    fi

    local -A ctx_data
    if ! configs::get_cached_app_info "$json_cfg" ctx_data; then
        responses::emit_error "CACHE_ERROR" "Could not decode config" "Cursor"
        return 1
    fi

    local name="${ctx_data[name]}"
    local appkey="${ctx_data[app_key]}"
    local instver="${ctx_data[installed_version]}"
    local ckey="${ctx_data[cache_key]}"

    local installdir
    installdir="$(systems::fetch_cached_json "$ckey" "install_path")"
    if ! _cursor::validate_install_path_config "$installdir" "$name" "$ckey"; then
        return 1
    fi

    # --------------------------------------------------------------------------
    # STEP 2: Create temporary workspace and begin metadata resolution
    # --------------------------------------------------------------------------
    local wdir
    wdir="$(mktemp -d)" || {
        responses::emit_error "FILESYSTEM_ERROR" "Failed to create temp dir for downloads" "Cursor"
        return 1
    }
    local cursor_cleanup_ready=0
    trap 'if (( cursor_cleanup_ready )); then [[ -n "${wdir:-}" ]] && rm -fr "$wdir"; fi' RETURN

    # --------------------------------------------------------------------------
    # STEP 3: Attempt to fetch update metadata via API or HTML fallback
    # --------------------------------------------------------------------------
    declare -a meta_lines
    if ! mapfile -t meta_lines < <(_cursor::_download::resolve "$wdir" "$name"); then
        cursor_cleanup_ready=1
        responses::emit_error "DOWNLOAD_ERROR" "Failed to resolve metadata for $name" "$name"
        return 1
    fi
    # shellcheck disable=SC2034
    cursor_cleanup_ready=1

    declare -A meta=(
        [url]="${meta_lines[0]:-}"
        [version]="${meta_lines[1]:-}"
        [type]="${meta_lines[2]:-"unknown"}"
        [length]="${meta_lines[3]:-}"
        [etag]="${meta_lines[4]:-}"
    )

    # --------------------------------------------------------------------------
    # STEP 4: Validate resolved metadata and double-check type/indexing
    # --------------------------------------------------------------------------
    local pkgurl="${meta[url]}"
    local pkgver="${meta[version]}"
    local pkgtype="${meta[type]}"
    local pgleng="${meta[length]}"
    local pgetag="${meta[etag]}"

    if [[ -z "$pkgurl" || -z "$pkgver" || -z "$pkgtype" ]]; then
        responses::emit_error "MISSING_DEPENDENCY" "Incomplete information from server for $name" "$name"
        return 1
    fi

    if ! _cursor::validate_artifact_type "$pkgtype" "$name"; then
        return 1
    fi

    # Normalize version before comparing
    local normalized_version
    normalized_version="$(versions::strip_prefix "$pkgver")"

    loggers::debug "CURSOR: installed='$instver' latest='$normalized_version' url='$pkgurl' type='$pkgtype' bytes=$pgleng"

    # --------------------------------------------------------------------------
    # STEP 5: Determine whether an update is needed
    # --------------------------------------------------------------------------
    local status_code
    status_code="$(responses::determine_status "$instver" "$normalized_version")"

    # --------------------------------------------------------------------------
    # STEP 6: Prepare final structured response and send it
    # --------------------------------------------------------------------------
    local -a args=(
        "$status_code" "$normalized_version" "$pkgtype" "Official API Endpoint"
        download_url "$pkgurl"
        app_key "$appkey"
    )

    if [[ -n "$pgleng" ]]; then
        args+=(content_length "$pgleng")
    fi

    if [[ -n "$pgetag" ]]; then
        args+=(expected_checksum "$pgetag")
        args+=(checksum_algorithm "s3_etag")
    fi

    if [[ "$status_code" == "success" ]]; then
        local final_validated_url
        if ! final_validated_url="$(networks::validate_url "$pkgurl")"; then
            responses::emit_error "NETWORK_ERROR" "Invalid resolved URL: $pkgurl" "$name"
            return 1
        fi
        args[5]=$final_validated_url # Update index for download_url in array

        local bin_name target_path
        if ! bin_name="$(_cursor::get_artifact_filename "$pkgtype")"; then
            responses::emit_error "INTERNAL_ERROR" "Failed to get default name for type '$pkgtype'" "$name"
            return 1
        fi
        if ! target_path="$(_cursor::resolve_install_path "$installdir" "$bin_name")"; then
            return 1
        fi
        args+=(install_target_path "$target_path")
    fi

    responses::emit_success "${args[@]}"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
