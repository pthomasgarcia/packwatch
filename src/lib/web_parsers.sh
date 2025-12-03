#!/usr/bin/env bash
# ==============================================================================
# MODULE: web_parsers.sh
# ==============================================================================
# Responsibilities:
#   - Generic web parsing and scraping utilities.
#
# Dependencies:
#   - networks.sh
#   - versions.sh
#   - validators.sh
#   - string_utils.sh
#   - systems.sh
#   - errors.sh
#   - loggers.sh
# ==============================================================================

# Idempotent guard
if [ -n "${PACKWATCH_WEB_PARSERS_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_WEB_PARSERS_LOADED=1

# Extract version from text input
web_parsers::extract_version() {
    local text="$1"
    local regex="${2:-[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*}"
    echo "$text" | grep -Eo "$regex" | head -n1 || true
}

# Parse Content-Disposition header for filename
web_parsers::parse_content_disposition() {
    local content_disp="$1"
    local filename

    if [[ -z "$content_disp" ]]; then
        return
    fi

    # Try filename* format first
    filename="$(sed -n 's/.*filename\*=[^'\'']*'\''[^'\'']*'\''\([^;]*\).*/\1/p' <<< "$content_disp" | head -n1)"

    # Fall back to regular filename format
    if [[ -z "$filename" ]]; then
        filename="$(sed -En 's/.*filename="?([^";]+).*/\1/p' <<< "$content_disp" | sed -n '1p')"
    fi

    echo "$filename"
}

# Detect artifact type from filename
web_parsers::detect_artifact_type() {
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
web_parsers::validate_architecture() {
    local filename="$1"
    local artifact_type="$2"
    local arch_tags_appimage="${3:-x86_64|amd64|x64}"
    local arch_tags_deb="${4:-amd64}"
    local deny_arch_tags="${5:-aarch64|arm64|armv7|armhf|armel|arm}"
    local lname="${filename,,}"

    case "$artifact_type" in
        appimage)
            echo "$lname" | grep -qiE "$arch_tags_appimage" &&
                ! echo "$lname" | grep -qiE "$deny_arch_tags"
            ;;
        deb)
            echo "$lname" | grep -qiE "$arch_tags_deb" &&
                ! echo "$lname" | grep -qiE "$deny_arch_tags"
            ;;
        *)
            return 1
            ;;
    esac
}

# Extract URLs from HTML content
web_parsers::extract_urls_from_html() {
    local html_file="$1"
    local base_url="$2"

    # Extract absolute URLs and decode HTML entities
    grep -Eo 'https?://[^"'\''<>\s]+' "$html_file" | sed -n '1,200p' | sed 's/&#43;/+/g'

    # Extract and resolve relative URLs, then decode HTML entities
    local rel_hrefs
    mapfile -t rel_hrefs < <(
        grep -Eio '<a[^>]+href=["'\''][^"'\'' #>]+["'\'']' "$html_file" |
            sed -E 's/.*href=["'\'']([^"'\''#>]+).*/\1/i' | sed -n '1,200p' | sed 's/&#43;/+/g'
    )

    local rel
    for rel in "${rel_hrefs[@]}"; do
        web_parsers::resolve_relative_url "$rel" "$base_url"
    done
}

# Resolve relative URL against base URL
web_parsers::resolve_relative_url() {
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
web_parsers::select_best_url() {
    local -a candidates=("$@")
    local re_ai="\.appimage(\?|$|[[:punct:]])"
    local re_deb="\.deb(\?|$|[[:punct:]])"
    local arch_tags_appimage="${3:-x86_64|amd64|x64}"
    local arch_tags_deb="${4:-amd64}"
    local deny_arch_tags="${5:-aarch64|arm64|armv7|armhf|armel|arm}"

    # Priority 1: AppImage with x86_64 architecture
    local url
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_ai ]] &&
            echo "$lurl" | grep -qiE "$arch_tags_appimage" &&
            ! echo "$lurl" | grep -qiE "$deny_arch_tags"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 2: AppImage without ARM tags
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_ai ]] &&
            ! echo "$lurl" | grep -qiE "$deny_arch_tags"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 3: DEB with amd64
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_deb ]] &&
            echo "$lurl" | grep -qiE "$arch_tags_deb" &&
            ! echo "$lurl" | grep -qiE "$deny_arch_tags"; then
            echo "$url"
            return 0
        fi
    done

    # Priority 4: DEB without ARM tags
    for url in "${candidates[@]}"; do
        local lurl="${url,,}"
        if [[ "$lurl" =~ $re_deb ]] &&
            ! echo "$lurl" | grep -qiE "$deny_arch_tags"; then
            echo "$url"
            return 0
        fi
    done

    return 1
}

# Check for meta refresh redirect in HTML
web_parsers::check_meta_refresh() {
    local html_file="$1"

    grep -i '<meta[^>]*http-equiv=["'\'']refresh["'\'']' "$html_file" 2> /dev/null |
        sed -n 's/.*content=["'\''][^"'\'']*url=\([^"'\'' >]*\).*/\1/ip' | head -n1
}

# Extract useful fields from raw header lines
# $1: Header file path
# $2: Effective resolved URL
# Returns lines:
#   content-type
#   content-disposition
#   suggested-filename
#   inferred-version
#   content-length
web_parsers::parse_metadata_from_headers() {
    local header_file="$1"
    local resolved_url="$2"

    local content_type content_disp content_length filename version
    content_type=$(awk -F': ' '/^Content-Type:/ {gsub(/\r$/, "", $2); print $2}' "$header_file" 2> /dev/null || true)
    content_disp=$(awk -F': ' '/^Content-Disposition:/ {gsub(/\r$/, "", $2); print $2}' "$header_file" 2> /dev/null || true)
    content_length=$(awk -F': ' '/^Content-Length:/ {gsub(/\r$/, "", $2); print $2}' "$header_file" 2> /dev/null || true)
    filename="$(web_parsers::parse_content_disposition "$content_disp")"

    # Explicitly pass arguments to web_parsers::extract_version to avoid unbound variable errors
    local version_input
    version_input="$(printf '%s\n%s\n%s\n' "$content_disp" "$filename" "$resolved_url")"
    version="$(web_parsers::extract_version "$version_input")"

    printf '%s\n%s\n%s\n%s\n%s\n' "$content_type" "$content_disp" "$filename" "$version" "$content_length"
}
