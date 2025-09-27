#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp terminal application.
#
# Dependencies:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - configs.sh
# ==============================================================================

# Constants for repo querying and version detection
readonly WARP_APT_REPO_URL='https://releases.warp.dev/linux/deb/dists/stable/main/binary-amd64/Packages'
readonly WARP_PACKAGE_NAME='warp-terminal'
readonly WARP_VERSION_PATTERN='/^Package: '$WARP_PACKAGE_NAME'$/ {found=1} found && /^Version:/ {print $2; exit}'

# Validates presence of expected input value
# $1: Value to test
# $2: Name of expected field (for logging purposes)
_warp::validate_input() {
    local input="$1"
    local input_name="$2"
    
    if [[ -z "$input" ]]; then
        loggers::debug "WARP: Empty $input_name provided"
        return 1
    fi
    return 0
}

# Fetches and parses latest available package version from official APT repo
# Returns: Latest version string or fails if not parsable
_warp::get_latest_version_from_repo() {
    local packages_content
    
    # Download APT Packages file
    if ! packages_content=$(networks::fetch_and_load "$WARP_APT_REPO_URL" "text" "Warp" \
        "Failed to fetch Warp apt repository package list."); then
        loggers::debug "WARP: Failed to fetch packages from APT repo"
        return 1
    fi
    
    # Ensure retrieved content exists
    if ! _warp::validate_input "$packages_content" "packages content"; then
        loggers::debug "WARP: Empty packages content retrieved"
        return 1
    fi
    
    # Extract version using AWK
    local version
    version=$(echo "$packages_content" | awk "$WARP_VERSION_PATTERN")
    
    if [[ -z "$version" ]]; then
        loggers::debug "WARP: Failed to extract version from APT Packages file."
        return 1
    fi
    
    # Return successfully parsed version
    echo "$version"
}

# Main updater check entrypoint for Warp terminal.
# Determines whether an update is required by comparing installed vs remote versions,
# resolves final download URL, and emits structured output.
# $1: Config JSON payload containing app metadata
warp::check() {
    local app_config_json="$1"

    # ---------------------------------------------------------------------------
    # STEP 1: Validate and load application config
    # ---------------------------------------------------------------------------
    if ! _warp::validate_input "$app_config_json" "config JSON"; then
        responses::emit_error "CONFIG_ERROR" "Missing config payload." "Warp"
        return 1
    fi

    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        responses::emit_error "CONFIG_ERROR" "Failed initializing Warp info cache." "Warp"
        return 1
    fi

    local name="${app_info["name"]}"
    local app_key="${app_info["app_key"]}"
    local cache_key="${app_info["cache_key"]}"

    # Attempt to retrieve current installed version dynamically, fall back to static
    local installed_version
    if ! installed_version=$(packages::fetch_version "$app_key"); then
        installed_version="${app_info["installed_version"]}"
    fi
    if ! _warp::validate_input "$installed_version" "current version"; then
        responses::emit_error "CONFIG_ERROR" "Unable to determine installed version of $name." "$name"
        return 1
    fi

    # Load base download URL
    local download_url_base
    download_url_base=$(systems::fetch_cached_json "$cache_key" "download_url_base")
    if ! _warp::validate_input "$download_url_base" "download URL"; then
        responses::emit_error "CONFIG_ERROR" "Required download URL is missing in config." "$name"
        return 1
    fi

    # ---------------------------------------------------------------------------
    # STEP 2: Get latest version from APT repository
    # ---------------------------------------------------------------------------
    local latest_version
    if ! latest_version=$(_warp::get_latest_version_from_repo); then
        responses::emit_error "PARSING_ERROR" \
            "Failed extracting upstream version for $name. May be source issue?" "$name"
        return 1
    fi

    # Strip non-version components and normalize both sides
    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version" | sed 's/^0\.//')

    loggers::debug "WARP: installed='$installed_version' latest='$latest_version' base_url='$download_url_base'"

    # ---------------------------------------------------------------------------
    # STEP 3: Determine update status
    # ---------------------------------------------------------------------------
    local output_status
    output_status=$(responses::determine_status "$installed_version" "$latest_version")

    if [[ "$output_status" == "no_update" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" "Warp Apt Repo"
        return 0
    fi

    # ---------------------------------------------------------------------------
    # STEP 4: Resolve effective download link via HTTP redirection resolution
    # ---------------------------------------------------------------------------
    local actual_deb_url
    if ! actual_deb_url=$(networks::get_effective_url "$download_url_base"); then
        responses::emit_error "NETWORK_ERROR" \
            "Download link did not resolve to valid target for $name." "$name"
        return 1
    fi

    local validated_download_url
    if ! validated_download_url=$(networks::validate_url "$actual_deb_url"); then
        responses::emit_error "NETWORK_ERROR" \
            "Resolved download URL invalid/unreachable: $actual_deb_url" "$name"
        return 1
    fi

    # ---------------------------------------------------------------------------
    # STEP 5: Construct and send update-available response with actionable meta
    # ---------------------------------------------------------------------------
    responses::emit_success \
        "$output_status" \
        "$latest_version" \
        "deb" \
        "Warp Apt Repo" \
        download_url "$validated_download_url" \
        filename "$(basename "$validated_download_url")" \
        install_type "deb"

    return 0
}
