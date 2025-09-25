#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/cursor.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Cursor.
#
# Dependencies:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
# ==============================================================================

# Constants
readonly CURSOR_API_ENDPOINT="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
readonly USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
readonly VERSION_REGEX='[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*'
readonly ARCH_TAGS_APPIMAGE='x86_64|amd64|x64'
readonly ARCH_TAGS_DEB='amd64'
readonly DENY_ARCH_TAGS='aarch64|arm64|armv7|armhf|armel|arm'

# Configuration parsing and validation
cursor::parse_config() {
    local app_config_json="$1"
    local cache_key
    cache_key="cursor_$(hashes::generate "$app_config_json")"

    systems::cache_json "$app_config_json" "$cache_key"

    local name install_path_config app_key
    name=$(systems::fetch_cached_json "$cache_key" "name")
    install_path_config=$(systems::fetch_cached_json "$cache_key" "install_path")
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")

    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "PARSING_ERROR" \
            "Missing 'name' or 'app_key' in config JSON." "${name:-cursor}"
        return 1
    fi

    printf '%s\n%s\n%s\n' "$name" "$install_path_config" "$app_key"
}

# Path resolution with environment variable expansion
cursor::resolve_install_path() {
    local install_path_config="$1"
    local artifact_filename="$2"

    local original_home="${ORIGINAL_HOME:-$HOME}"
    local install_base_dir="$install_path_config"

    # Expand environment variables
    install_base_dir="${install_base_dir//\$HOME/$original_home}"
    install_base_dir="${install_base_dir//\$\{HOME\}/$original_home}"
    [[ "$install_base_dir" == "~"* ]] && install_base_dir="${install_base_dir/#\~/$original_home}"
    [[ -z "$install_base_dir" ]] && install_base_dir="$original_home"

    mkdir -p -- "$install_base_dir" || {
        responses::emit_error "FILESYSTEM_ERROR" \
            "Unable to create install directory '$install_base_dir'." "cursor"
        return 1
    }

    echo "${install_base_dir%/}/${artifact_filename}"
}

# Extract version from text input
cursor::extract_version() {
    grep -Eo "$VERSION_REGEX" | head -n1 || true
}

# Parse Content-Disposition header for filename
cursor::parse_content_disposition() {
    local content_disp="$1"
    local filename

    # Try filename* format first
    filename="$(sed -n 's/.*filename\*=[^'\'']*'\''[^'\'']*'\''\([^;]*\).*/\1/p' <<< "$content_disp" | head -n1)"

    # Fall back to regular filename format
    if [[ -z "$filename" ]]; then
        filename="$(sed -En 's/.*filename="?([^";]+).*/\1/p' <<< "$content_disp" | sed -n '1p')"
    fi

    echo "$filename"
}

# Detect artifact type from filename
cursor::detect_artifact_type() {
    local name="${1,,}"

    if [[ "$name" =~ \.appimage($|[._-]) ]]; then
        echo "appimage"
    elif [[ "$name" =~ \.deb($|[._-]) ]]; then
        echo "deb"
    elif [[ "$name" =~ \.rpm($|[._-]) ]]; then
        echo "rpm"
    else
        echo "unknown"
    fi
}

# Validate architecture compatibility
cursor::validate_architecture() {
    local filename="$1"
    local artifact_type="$2"
    local lname="${filename,,}"

    case "$artifact_type" in
        appimage)
            echo "$lname" | grep -qiE "$ARCH_TAGS_APPIMAGE" &&
                ! echo "$lname" | grep -qiE "$DENY_ARCH_TAGS"
            ;;
        deb)
            echo "$lname" | grep -qiE "$ARCH_TAGS_DEB" &&
                ! echo "$lname" | grep -qiE "$DENY_ARCH_TAGS"
            ;;
        *)
            return 1
            ;;
    esac
}

# Perform HTTP request and capture headers/body
cursor::http_request() {
    local url="$1"
    local method="${2:-GET}"
    local header_file="$3"
    local body_file="${4:-}"

    # Initialize header file
    : > "$header_file"

    local curl_args=(-fsSL "$url" -A "$USER_AGENT" -D "$header_file")

    if [[ "$method" == "HEAD" ]]; then
        curl_args=(-fsSIL "$url" -A "$USER_AGENT" -D "$header_file" -o /dev/null)
    elif [[ -n "$body_file" ]]; then
        curl_args+=(-o "$body_file")
        : > "$body_file"
    else
        curl_args+=(-o /dev/null)
    fi

    timeout 30s curl "${curl_args[@]}" -w '%{url_effective}' 2> /dev/null
}

# Extract URLs from HTML content
cursor::extract_urls_from_html() {
    local html_file="$1"
    local base_url="$2"

    # Extract absolute URLs
    grep -Eo 'https?://[^"'\''<>\s]+' "$html_file" | sed -n '1,200p'

    # Extract and resolve relative URLs
    local rel_hrefs
    mapfile -t rel_hrefs < <(
        grep -Eio '<a[^>]+href=["'\''][^"'\'' #>]+["'\'']' "$html_file" |
            sed -E 's/.*href=["'\'']([^"'\''#>]+).*/\1/i' | sed -n '1,200p'
    )

    local rel
    for rel in "${rel_hrefs[@]}"; do
        cursor::resolve_relative_url "$rel" "$base_url"
    done
}

# Resolve relative URL against base URL
cursor::resolve_relative_url() {
    local rel="$1"
    local base_url="$2"

    if [[ "$rel" =~ ^https?:// ]]; then
        echo "$rel"
    elif [[ "$rel" =~ ^// ]]; then
        local proto
        proto="$(awk -F: '{print $1}' <<< "$base_url")"
        echo "${proto}:$rel"
    elif [[ "$rel" =~ ^/ ]]; then
        echo "$(awk -F/ '{print $1"//"$3}' <<< "$base_url")$rel"
    else
        local base_no_q base_dir
        base_no_q="${base_url%%[\?#]*}"
        base_dir="${base_no_q%/*}"
        echo "$base_dir/$rel"
    fi
}

# Select best download URL from candidates
cursor::select_best_url() {
    local -a candidates=("$@")
    local re_ai="\.appimage(\?|$|[[:punct:]])"
    local re_deb="\.deb(\?|$|[[:punct:]])"

    # Priority 1: AppImage with x86_64 architecture
    local url
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_ai ]] &&
            echo "$lurl" | grep -qiE "$ARCH_TAGS_APPIMAGE" &&
            ! echo "$lurl" | grep -qiE "$DENY_ARCH_TAGS"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 2: AppImage without ARM tags
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_ai ]] &&
            ! echo "$lurl" | grep -qiE "$DENY_ARCH_TAGS"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 3: DEB with amd64
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_deb ]] &&
            echo "$lurl" | grep -qiE "$ARCH_TAGS_DEB" &&
            ! echo "$lurl" | grep -qiE "$DENY_ARCH_TAGS"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 4: DEB without ARM tags
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_deb ]] &&
            ! echo "$lurl" | grep -qiE "$DENY_ARCH_TAGS"; then
            echo "$url"
            return 0
        fi
    done

    return 1
}

# Parse download information from HTTP response
cursor::parse_download_info() {
    local header_file="$1"
    local final_url="$2"

    local content_type content_disp filename version content_length
    content_type="$(grep -i '^Content-Type:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' | awk -F': ' '{print $2}' || true)"
    content_disp="$(grep -i '^Content-Disposition:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' || true)"
    content_length="$(grep -i '^Content-Length:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' | awk -F': ' '{print $2}' || true)"
    filename="$(cursor::parse_content_disposition "$content_disp")"
    version="$(printf '%s\n%s\n%s\n' "$content_disp" "$filename" "$final_url" | cursor::extract_version)"

    printf '%s\n%s\n%s\n%s\n%s\n' "$content_type" "$content_disp" "$filename" "$version" "$content_length"
}

# Check for meta refresh redirect in HTML
cursor::check_meta_refresh() {
    local html_file="$1"

    grep -i '<meta[^>]*http-equiv=["'\'']refresh["'\'']' "$html_file" 2> /dev/null |
        sed -n 's/.*content=["'\''][^"'\'']*url=\([^"'\'' >]*\).*/\1/ip' | head -n1
}

# Resolve download URL and metadata
cursor::resolve_download() {
    local tmpdir="$1"
    local header_file="$tmpdir/headers.txt"
    local body_file="$tmpdir/body.html"

    # Try HEAD request first
    local final_url
    if ! final_url="$(cursor::http_request "$CURSOR_API_ENDPOINT" "HEAD" "$header_file")"; then
        # Fallback to GET if HEAD is blocked
        final_url="$(cursor::http_request "$CURSOR_API_ENDPOINT" "GET" "$header_file")"
    fi

    [[ -z "$final_url" ]] && return 1

    local download_info
    mapfile -t download_info < <(cursor::parse_download_info "$header_file" "$final_url")
    local content_type="${download_info[0]}"
    local content_disp="${download_info[1]}"
    local filename="${download_info[2]}"
    local version="${download_info[3]}"

    local final_name_part
    final_name_part="$(basename "${final_url%%[\?#]*}")"
    local chosen_name="${filename:-$final_name_part}"
    local artifact_type
    artifact_type="$(cursor::detect_artifact_type "$chosen_name")"

    # Determine if we need to parse HTML for better options
    local need_html_parse="false"
    if [[ "$artifact_type" != "appimage" && "$artifact_type" != "deb" ]] ||
        [[ -z "$version" ]] ||
        [[ "$content_type" == *"text/html"* ]] ||
        ! cursor::validate_architecture "$chosen_name" "$artifact_type"; then
        need_html_parse="true"
    fi

    if [[ "$need_html_parse" == "true" ]]; then
        cursor::resolve_from_html "$tmpdir"
    else
        local content_type content_disp filename version content_length
        mapfile -t download_info < <(cursor::parse_download_info "$header_file" "$final_url")
        content_type="${download_info[0]}"
        content_disp="${download_info[1]}"
        filename="${download_info[2]}"
        version="${download_info[3]}"
        content_length="${download_info[4]}" # New: Content-Length

        printf '%s\n%s\n%s\n%s\n%s\n' "$final_url" "$version" "$artifact_type" "$chosen_name" "$content_length"
    fi
}

# Resolve download from HTML content
cursor::resolve_from_html() {
    local tmpdir="$1"
    local header_file="$tmpdir/headers.txt"
    local body_file="$tmpdir/body.html"

    # Get HTML content
    local final_url
    final_url="$(cursor::http_request "$CURSOR_API_ENDPOINT" "GET" "$header_file" "$body_file")"

    [[ -z "$final_url" ]] && return 1

    # Check for meta refresh redirect
    local refresh_url
    refresh_url="$(cursor::check_meta_refresh "$body_file")"

    if [[ -n "$refresh_url" ]]; then
        printf '%s\n\n\n\n' "$refresh_url"
        return 0
    fi

    # Extract and select best URL from HTML
    local -a candidates
    mapfile -t candidates < <(cursor::extract_urls_from_html "$body_file" "$final_url")

    local best_url
    if best_url="$(cursor::select_best_url "${candidates[@]}")"; then
        # Resolve the selected URL
        local resolved_url
        if ! resolved_url="$(cursor::http_request "$best_url" "HEAD" "$header_file")"; then
            resolved_url="$(cursor::http_request "$best_url" "GET" "$header_file")"
        fi

        [[ -z "$resolved_url" ]] && return 1

        local download_info
        mapfile -t download_info < <(cursor::parse_download_info "$header_file" "$resolved_url")
        local version="${download_info[3]}"
        local filename="${download_info[2]}"
        local content_length="${download_info[4]}" # New: Content-Length

        local final_name_part
        final_name_part="$(basename "${resolved_url%%[\?#]*}")"
        local chosen_name="${filename:-$final_name_part}"
        local artifact_type
        artifact_type="$(cursor::detect_artifact_type "$chosen_name")"

        printf '%s\n%s\n%s\n%s\n%s\n' "$resolved_url" "$version" "$artifact_type" "$chosen_name" "$content_length"
    else
        return 1
    fi
}

# Main checker function
cursor::check() {
    local app_config_json="$1"

    # Parse configuration
    local config_info
    mapfile -t config_info < <(cursor::parse_config "$app_config_json") || return 1
    local name="${config_info[0]}"
    local install_path_config="${config_info[1]}"
    local app_key="${config_info[2]}"

    # Get installed version
    local installed_version
    installed_version=$(packages::fetch_version "$app_key")

    # Set up temporary directory
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    # Fetch API response
    local api_response_path="$tmpdir/api_response"
    local final_url
    final_url=$(cursor::http_request "$CURSOR_API_ENDPOINT" "GET" "$tmpdir/headers.txt" "$api_response_path")

    if [[ -z "$final_url" ]]; then
        responses::emit_error "NETWORK_ERROR" "Failed to fetch Cursor API response for $name." "$name"
        return 1
    fi

    # Attempt to parse as JSON first
    local actual_download_url="" latest_version="" content_length="" artifact_type=""
    if systems::is_valid_json "$api_response_path"; then
        actual_download_url=$(systems::fetch_json "$api_response_path" '.downloadUrl // empty')
        latest_version=$(systems::fetch_json "$api_response_path" '.version // empty')

        if [[ -n "$actual_download_url" && -n "$latest_version" ]]; then
            loggers::debug "CURSOR: Parsed API response as JSON. Resolving final download URL."
            local download_header_file="$tmpdir/download_headers.txt"
            local resolved_download_url
            if ! resolved_download_url=$(cursor::http_request "$actual_download_url" "HEAD" "$download_header_file"); then
                resolved_download_url=$(cursor::http_request "$actual_download_url" "GET" "$download_header_file")
            fi

            if [[ -n "$resolved_download_url" ]]; then
                actual_download_url="$resolved_download_url"
                artifact_type="$(cursor::detect_artifact_type "$(basename "${actual_download_url%%[\?#]*}")")"
                local download_info
                mapfile -t download_info < <(cursor::parse_download_info "$download_header_file" "$resolved_download_url")
                content_length="${download_info[4]}"
            else
                loggers::warn "CURSOR: Could not resolve download URL headers."
                # Fallback to HTML parsing if resolution fails
                actual_download_url=""
                latest_version=""
            fi
        else
            loggers::debug "CURSOR: JSON response missing required keys, falling back to HTML parsing."
            actual_download_url=""
            latest_version=""
        fi
    fi

    if [[ -z "$actual_download_url" || -z "$latest_version" ]]; then
        loggers::debug "CURSOR: API response is not valid JSON or was incomplete, attempting to parse as HTML."
        local download_info
        mapfile -t download_info < <(cursor::resolve_download "$tmpdir")
        if [[ ${#download_info[@]} -lt 5 ]]; then
            responses::emit_error "PARSING_ERROR" "Could not resolve download information for $name from HTML." "$name"
            return 1
        fi
        actual_download_url="${download_info[0]}"
        latest_version="${download_info[1]}"
        artifact_type="${download_info[2]}"
        content_length="${download_info[4]}"
    fi

    # Post-parsing validation and processing
    if [[ -z "$actual_download_url" ]]; then
        responses::emit_error "PARSING_ERROR" "Could not resolve download URL for $name." "$name"
        return 1
    fi

    if [[ -z "$latest_version" ]]; then
        latest_version="$(echo "$actual_download_url" | cursor::extract_version)"
    fi

    if [[ "$artifact_type" == "unknown" || -z "$artifact_type" ]]; then
        artifact_type="$(cursor::detect_artifact_type "$(basename "${actual_download_url%%[\?#]*}")")"
    fi

    local artifact_filename_final
    case "$artifact_type" in
        appimage) artifact_filename_final="cursor.AppImage" ;;
        deb) artifact_filename_final="cursor.deb" ;;
        *)
            responses::emit_error "PARSING_ERROR" "Unsupported artifact type '$artifact_type' for $name." "$name"
            return 1
            ;;
    esac

    local install_target_path
    install_target_path="$(cursor::resolve_install_path "$install_path_config" "$artifact_filename_final")" || return 1

    latest_version="$(versions::strip_prefix "${latest_version:-}")"

    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Could not determine version for $name." "$name"
        return 1
    fi

    local resolved_url
    if ! resolved_url=$(networks::validate_url "$actual_download_url"); then
        responses::emit_error "NETWORK_ERROR" "Invalid or unresolved download URL for $name (url=$actual_download_url)." "$name"
        return 1
    fi

    loggers::debug "CURSOR: installed_version='$installed_version' latest_version='$latest_version' url='$resolved_url' type='$artifact_type'"

    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    responses::emit_success "$output_status" "$latest_version" "$artifact_type" \
        "Official API (JSON with HTML fallback)" \
        download_url "$resolved_url" \
        install_target_path "$install_target_path" \
        app_key "$app_key" \
        content_length "$content_length"

    return 0
}
