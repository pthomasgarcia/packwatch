#!/usr/bin/env bash
# ==============================================================================
# MODULE: repositories.sh
# ==============================================================================
# Responsibilities:
#   - Repository API interactions (currently GitHub, extensible for others)
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/repositories.sh"
#
#   Then use:
#     repositories::get_latest_release_info "owner" "repo"
#     repositories::parse_version_from_release "$release_json" "AppName"
#     repositories::find_asset_url "release_json" "pattern" "AppName"
#     repositories::find_asset_checksum "release_json" "filename"
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - networks.sh
#   - systems.sh
#   - versions.sh
#   - validators.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: GitHub API Functions
# ------------------------------------------------------------------------------

# Fetch the latest release JSON from the GitHub API.
# Usage: repositories::get_latest_release_info "owner" "repo"
repositories::get_latest_release_info() {
    local repo_owner="$1"
    local repo_name="$2"
    local api_url="https://api.github.com/repos/${repo_owner}/${repo_name}/releases"
    local response_file
    response_file=$(networks::fetch_cached_data "$api_url" "json")
    local ret=$?
    echo "$response_file" # Explicitly echo the file path
    return $ret
}

# Parse the version from a release JSON object.
# Usage: repositories::parse_version_from_release "$release_json" "AppName"
repositories::parse_version_from_release() {
    local release_json_path="$1" # Now expects a file path
    local app_name="$2"

    local raw_tag_name
    raw_tag_name=$(systems::get_json_value "$release_json_path" '.tag_name' "$app_name")
    if [[ -z "$raw_tag_name" ]]; then
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"parse_version\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to get raw tag name.\"}"
        return 1
    fi

    local latest_version
    latest_version=$(versions::normalize "$raw_tag_name")

    if [[ -z "$latest_version" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to detect latest version for '$app_name' from tag '$raw_tag_name'." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"parse_version\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Failed to detect latest version from tag.\"}"
        return 1
    fi

    echo "$latest_version"
}

# Find a specific asset's download URL from a release JSON.
# Usage: repositories::find_asset_url "$release_json_path" "pattern" "AppName"
repositories::find_asset_url() {
    local release_json_path="$1" # Path to a single release JSON object
    local filename_pattern="$2"
    local app_name="$3"

    # Build a regex from the pattern:
    # - Escape regex meta characters
    # - Replace %s with .*
    local escaped_pattern
    escaped_pattern=$(printf '%s' "$filename_pattern" |
        sed 's/[.[\*^$+?{|}()\\]/\\&/g; s/%s/.*/g')

    # Single jq pass:
    # 1) exact name match
    # 2) regex fallback
    # Return the first URL found.
    local url
    url=$(
        jq -r --arg pat "$filename_pattern" --arg re "$escaped_pattern" '
          [
            (.assets[]? | select(.name == $pat) | .browser_download_url),
            (.assets[]? | select(.name | test($re)) | .browser_download_url)
          ]
          | flatten
          | map(select(. != null))
          | .[0] // empty
        ' "$release_json_path" 2> /dev/null
    )

    if [[ -n "$url" ]]; then
        if validators::check_https_url "$url"; then
            echo "$url"
            return 0
        else
            errors::handle_error "SECURITY_ERROR" "Rejected insecure HTTP URL for '${filename_pattern}': '$url'" "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" '{"phase":"download","error_type":"SECURITY_ERROR","message":"Insecure HTTP URL rejected."}'
            return 1
        fi
    fi

    errors::handle_error "NETWORK_ERROR" "Download URL not found or invalid for '${filename_pattern}'." "$app_name"
    updates::trigger_hooks ERROR_HOOKS "$app_name" '{"phase":"download","error_type":"NETWORK_ERROR","message":"Download URL not found or invalid."}'
    return 1
}

# Find and extract a checksum for a given asset from a release's body text.
# Usage: repositories::extract_checksum_from_release_body "$release_json_path" "$checksum_pattern" "$app_name" "$checksum_algorithm"
repositories::extract_checksum_from_release_body() {
    local release_json_path="$1"
    local checksum_pattern="$2" # e.g. "fastfetch-linux-amd64/fastfetch-linux-amd64.deb"
    local app_name="${3:-Unknown}"
    local checksum_algorithm="${4:-sha256}"
    local expected_checksum=""

    if [[ -z "$checksum_pattern" ]]; then
        loggers::log_message "DEBUG" "No checksum_pattern provided for '$app_name'. Skipping body checksum extraction."
        echo ""
        return 0
    fi
    if [[ ! -f "$release_json_path" ]]; then
        loggers::log_message "ERROR" "Release JSON file not found: '$release_json_path' (app: $app_name)"
        echo ""
        return 1
    fi

    # Extract and normalize the release body
    local release_body
    release_body=$(jq -r '.body // ""' "$release_json_path" 2> /dev/null)
    if [[ $? -ne 0 || -z "$release_body" ]]; then
        loggers::log_message "WARN" "Failed to extract release body from JSON for '$app_name'."
        echo ""
        return 0
    fi
    release_body=$(printf '%s' "$release_body" | tr -d '\r')

    # Algorithm -> expected hex length + header markers
    local valid_length header_markers=()
    case "${checksum_algorithm,,}" in
        sha512)
            valid_length=128
            header_markers=("SHA512SUMS" "SHA-512" "SHA512")
            ;;
        sha256 | *)
            checksum_algorithm="sha256"
            valid_length=64
            header_markers=("SHA256SUMS" "SHA-256" "SHA256")
            ;;
    esac

    # Build candidate filename patterns to match against:
    #  1) the provided pattern as-is (may include path)
    #  2) its basename (in case body lists only the filename)
    #  3) if the provided pattern has no slash but Fastfetch-style path exists, try known dirname prefix
    # We also support a user-provided alternation using "|" (don’t escape the pipe).
    IFS='|' read -r -a user_alts <<< "$checksum_pattern"
    declare -a candidates=()
    for p in "${user_alts[@]}"; do
        candidates+=("$p")
        candidates+=("$(basename -- "$p")")
        # If no slash in p, add a fastfetch-style path variant as a fallback
        if [[ "$p" != */* ]]; then
            candidates+=("fastfetch-linux-amd64/$p")
        fi
    done

    # Escape each candidate for grep -E (except we already split alternations above)
    _escape_for_egrep() { printf '%s' "$1" | sed 's/[.[\*^$+?{|}()\\]/\\&/g'; }

    # Helper: try to find a matching line in provided blob using a filename candidate
    _pick_matching_line_for() {
        local blob="$1"
        local fname="$2"
        local re
        re=$(_escape_for_egrep "$fname")
        grep -E "^[0-9a-fA-F]{${valid_length}}[[:space:]]+(\*|)?${re}([[:space:]]|\$)" <<< "$blob" | head -n1
    }

    # Prefer the algorithm’s code block under its header; otherwise search entire body
    local checksum_block="" in_correct_section=0 in_code_block=0
    while IFS= read -r line; do
        local UL=${line^^}
        if ((in_correct_section == 0)); then
            for mk in "${header_markers[@]}"; do
                if [[ "$UL" == *"$mk"* ]]; then
                    in_correct_section=1
                    break
                fi
            done
            ((in_correct_section == 1)) && continue
        fi
        if ((in_correct_section == 1)) && [[ $line == \`\`\`* ]]; then
            if ((in_code_block == 0)); then
                in_code_block=1
                continue
            else
                break
            fi
        fi
        ((in_code_block == 1)) && checksum_block+="$line"$'\n'
    done <<< "$release_body"

    # 1) Try candidates in the algorithm section block
    local matching_line=""
    if [[ -n "$checksum_block" ]]; then
        for cand in "${candidates[@]}"; do
            matching_line=$(_pick_matching_line_for "$checksum_block" "$cand")
            [[ -n "$matching_line" ]] && break
        done
    fi

    # 2) Fallback: search the whole body
    if [[ -z "$matching_line" ]]; then
        for cand in "${candidates[@]}"; do
            matching_line=$(_pick_matching_line_for "$release_body" "$cand")
            [[ -n "$matching_line" ]] && break
        done
    fi

    # 3) Last resort: scan each fenced block
    if [[ -z "$matching_line" ]]; then
        local block="" fence=0
        while IFS= read -r line; do
            if [[ $line == \`\`\`* ]]; then
                if ((fence == 0)); then
                    fence=1
                    block=""
                else
                    for cand in "${candidates[@]}"; do
                        local m
                        m=$(_pick_matching_line_for "$block" "$cand")
                        if [[ -n "$m" ]]; then
                            matching_line="$m"
                            break
                        fi
                    done
                    ((${#matching_line})) && break
                    fence=0
                    block=""
                fi
                continue
            fi
            ((fence == 1)) && block+="$line"$'\n'
        done <<< "$release_body"
    fi

    if [[ -n "$matching_line" ]]; then
        expected_checksum=$(awk '{print $1}' <<< "$matching_line" | tr -d '[:space:]')
        if [[ -n "$expected_checksum" ]] &&
            [[ ${#expected_checksum} -eq $valid_length ]] &&
            [[ "$expected_checksum" =~ ^[0-9a-fA-F]+$ ]]; then
            echo "$expected_checksum"
            return 0
        fi
        loggers::log_message "WARN" "Extracted checksum for '$app_name' has invalid format/length for $checksum_algorithm."
        echo ""
        return 0
    else
        loggers::log_message "WARN" "No line found for any of: '${candidates[*]}' with $checksum_algorithm in release body for '$app_name'."
        echo ""
        return 0
    fi
}

# Find and extract a checksum for a given asset from a release.
# Usage: repositories::find_asset_checksum "$release_json" "filename"
repositories::find_asset_checksum() {
    local release_json_path="$1" # Now expects a file path
    local target_filename="$2"
    local app_name="$3"

    local checksum_file_url
    checksum_file_url=$(systems::get_json_value "$release_json_path" '.assets[] | select(.name | (endswith("sha256sum.txt") or endswith("checksums.txt"))) | .browser_download_url' "Repository Release Checksum URL")
    if [[ $? -ne 0 || -z "$checksum_file_url" ]]; then
        return 0 # Not an error if checksum file doesn't exist
    fi

    local temp_checksum_file
    temp_checksum_file=$(systems::create_temp_file "checksum_file")
    if ! temp_checksum_file=$(systems::create_temp_file "checksum_file"); then
        updates::trigger_hooks ERROR_HOOKS "$app_name" '{"phase": "checksum_download", "error_type": "SYSTEM_ERROR", "message": "Failed to create temporary file for checksum."}'
        return 1
    fi

    local extracted_checksum=""
    if networks::download_file "$checksum_file_url" "$temp_checksum_file" ""; then
        local checksum_file_content
        checksum_file_content=$(cat "$temp_checksum_file")
        extracted_checksum=$(echo "$checksum_file_content" |
            grep -Ei "^[0-9a-f]{64}\s+(\*|)${target_filename//\./\\.}\s*$" |
            awk '{print $1}' | head -n1)
    else
        loggers::log_message "WARN" "Failed to download checksum file from '$checksum_file_url'"
    fi

    rm -f "$temp_checksum_file"
    systems::unregister_temp_file "$temp_checksum_file"
    echo "$extracted_checksum"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
