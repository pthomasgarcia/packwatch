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
#   - web_parsers.sh
# ==============================================================================

# Constants
readonly CURSOR_API_ENDPOINT="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
readonly USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

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

# Parse download information from HTTP response
cursor::parse_download_info() {
    local header_file="$1"
    local final_url="$2"

    local content_type content_disp filename version content_length
    content_type="$(grep -i '^Content-Type:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' | awk -F': ' '{print $2}' || true)"
    content_disp="$(grep -i '^Content-Disposition:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' || true)"
    content_length="$(grep -i '^Content-Length:' "$header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' | awk -F': ' '{print $2}' || true)"
    filename="$(web_parsers::parse_content_disposition "$content_disp")"
    version="$(printf '%s\n%s\n%s\n' "$content_disp" "$filename" "$final_url" | web_parsers::extract_version)"

    printf '%s\n%s\n%s\n%s\n%s\n' "$content_type" "$content_disp" "$filename" "$version" "$content_length"
}

# Resolve download URL and metadata
cursor::resolve_download() {
    local tmpdir="$1"
    local header_file="$tmpdir/headers.txt"
    local body_file="$tmpdir/body.html"

    # Try HEAD request first
    local final_url
    if ! final_url="$(networks::get_effective_url "$CURSOR_API_ENDPOINT")"; then
        responses::emit_error "NETWORK_ERROR" "Failed to resolve effective URL for Cursor." "cursor"
        return 1
    fi

    # Fetch headers for the final URL
    curl -fsSIL "$final_url" -A "$USER_AGENT" -D "$header_file" -o /dev/null

    local download_info
    mapfile -t download_info < <(cursor::parse_download_info "$header_file" "$final_url")
    local content_type="${download_info[0]}"
    local filename="${download_info[2]}"
    local version="${download_info[3]}"

    local final_name_part
    final_name_part="$(basename "${final_url%%[\?#]*}")"
    local chosen_name="${filename:-$final_name_part}"
    local artifact_type
    artifact_type="$(web_parsers::detect_artifact_type "$chosen_name")"

    # Determine if we need to parse HTML for better options
    local need_html_parse="false"
    if [[ "$artifact_type" != "appimage" && "$artifact_type" != "deb" ]] ||
        [[ -z "$version" ]] ||
        [[ "$content_type" == *"text/html"* ]] ||
        ! web_parsers::validate_architecture "$chosen_name" "$artifact_type"; then
        need_html_parse="true"
    fi

    if [[ "$need_html_parse" == "true" ]]; then
        cursor::resolve_from_html "$tmpdir"
    else
        local content_length="${download_info[4]}"
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
    local cached_file
    if ! cached_file=$(networks::fetch_cached_data "$CURSOR_API_ENDPOINT" "html"); then
        responses::emit_error "NETWORK_ERROR" "Failed to fetch HTML content for Cursor." "cursor"
        return 1
    fi
    cat "$cached_file" > "$body_file"
    final_url="$CURSOR_API_ENDPOINT" # The base URL for resolving relative links

    # Check for meta refresh redirect
    local refresh_url
    refresh_url="$(web_parsers::check_meta_refresh "$body_file")"

    if [[ -n "$refresh_url" ]]; then
        printf '%s\n\n\n\n' "$refresh_url"
        return 0
    fi

    # Extract and select best URL from HTML
    local -a candidates
    mapfile -t candidates < <(web_parsers::extract_urls_from_html "$body_file" "$final_url")

    local best_url
    if best_url="$(web_parsers::select_best_url "${candidates[@]}")"; then
        # Resolve the selected URL
        local resolved_url
        if ! resolved_url="$(networks::get_effective_url "$best_url")"; then
            responses::emit_error "NETWORK_ERROR" "Failed to resolve best URL for Cursor." "cursor"
            return 1
        fi

        # Fetch headers for the resolved URL
        curl -fsSIL "$resolved_url" -A "$USER_AGENT" -D "$header_file" -o /dev/null

        local download_info
        mapfile -t download_info < <(cursor::parse_download_info "$header_file" "$resolved_url")
        local version="${download_info[3]}"
        local filename="${download_info[2]}"
        local content_length="${download_info[4]}"

        local final_name_part
        final_name_part="$(basename "${resolved_url%%[\?#]*}")"
        local chosen_name="${filename:-$final_name_part}"
        local artifact_type
        artifact_type="$(web_parsers::detect_artifact_type "$chosen_name")"

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

    local latest_version=""
    local actual_download_url=""
    local artifact_type=""
    local content_length=""

    # Fetch API response (JSON) to get the latest version and download URLs
    local api_response_path="$tmpdir/api_response"
    if ! networks::download_file "$CURSOR_API_ENDPOINT" "$api_response_path" "" "" "false" > /dev/null 2>&1; then
        responses::emit_error "NETWORK_ERROR" "Failed to fetch Cursor API response for $name." "$name"
        return 1
    fi

    if systems::is_valid_json "$api_response_path"; then
        latest_version=$(systems::fetch_json "$api_response_path" '.version // empty')
        # Prefer AppImage URL if available, otherwise fallback to debUrl
        actual_download_url=$(systems::fetch_json "$api_response_path" '.downloadUrl // .debUrl // empty')
        # If we got a download URL from JSON, try to get its content length
        if [[ -n "$actual_download_url" ]]; then
            local download_header_file="$tmpdir/download_headers.txt"
            curl -fsSIL "$actual_download_url" -A "$USER_AGENT" -D "$download_header_file" -o /dev/null
            content_length="$(grep -i '^Content-Length:' "$download_header_file" 2> /dev/null | tail -n1 | sed 's/\r$//' | awk -F': ' '{print $2}' || true)"
        fi
    else
        loggers::warn "CURSOR: API response is not valid JSON, falling back to HTML parsing (less efficient)."
        # Fallback to HTML parsing if JSON is invalid or incomplete
        local download_info
        mapfile -t download_info < <(cursor::resolve_download "$tmpdir")
        if [[ ${#download_info[@]} -ge 5 ]]; then
            actual_download_url="${download_info[0]}"
            latest_version="${download_info[1]}"
            artifact_type="${download_info[2]}"
            content_length="${download_info[4]}"
        fi
    fi

    # Post-parsing validation and processing
    if [[ -z "$actual_download_url" ]]; then
        responses::emit_error "PARSING_ERROR" "Could not resolve download URL for $name." "$name"
        return 1
    fi

    if [[ -z "$latest_version" ]]; then
        latest_version="$(echo "$actual_download_url" | web_parsers::extract_version)"
    fi

    if [[ "$artifact_type" == "unknown" || -z "$artifact_type" ]]; then
        artifact_type="$(web_parsers::detect_artifact_type "$(basename "${actual_download_url%%[\?#]*}")")"
    fi

    latest_version="$(versions::strip_prefix "${latest_version:-}")"

    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" "Could not determine version for $name." "$name"
        return 1
    fi

    loggers::debug "CURSOR: installed_version='$installed_version' latest_version='$latest_version' url='$actual_download_url' type='$artifact_type'"

    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    if [[ "$output_status" == "success" ]]; then
        local resolved_url
        if ! resolved_url=$(networks::validate_url "$actual_download_url"); then
            responses::emit_error "NETWORK_ERROR" "Invalid or unresolved download URL for $name (url=$actual_download_url)." "$name"
            return 1
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

        responses::emit_success "$output_status" "$latest_version" "$artifact_type" \
            "Official API (JSON with HTML fallback)" \
            download_url "$resolved_url" \
            install_target_path "$install_target_path" \
            app_key "$app_key" \
            content_length "$content_length"
    else
        responses::emit_success "$output_status" "$latest_version" "$artifact_type" \
            "Official API (JSON with HTML fallback)" \
            download_url "$actual_download_url" \
            app_key "$app_key" \
            content_length "$content_length"
    fi

    return 0
}
