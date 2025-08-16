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

# Find a digest SHA256 for a given asset from the GitHub release JSON.
repositories::find_asset_digest() {
    local release_json_path="$1"
    local target_filename="$2"
    local app_name="$3"

    # Find the asset with the matching name and extract its sha256 digest.
    # The digest is expected to be in the format "sha256:<hash>"
    local digest
    digest=$(jq -r --arg name "$target_filename" \
        '.assets[] | select(.name == $name) | .digest' \
        "$release_json_path" 2> /dev/null)

    if [[ -z "$digest" ]] || [[ ! "$digest" == sha256:* ]]; then
        loggers::log_message "WARN" "Could not find sha256 digest for '$target_filename' in release assets for '$app_name'."
        return 1
    fi

    # Extract the hash part from "sha256:<hash>"
    local checksum
    checksum="${digest#sha256:}"

    if [[ -z "$checksum" ]] || [[ ${#checksum} -ne 64 ]]; then
        loggers::log_message "WARN" "Invalid sha256 digest format for '$target_filename' in release assets for '$app_name': $digest"
        return 1
    fi

    echo "$checksum"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
