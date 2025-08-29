#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp.
#
# Dependencies:
#   - json_response.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

check_warp() {
    local app_config_json="$1" # JSON string

    # Generate cache key and cache all fields at once
    local cache_key
    local _hash
    _hash="$(hash_utils::generate_hash "$app_config_json")"
    cache_key="warp_${_hash}"
    systems::cache_json_fields "$app_config_json" "$cache_key"

    # Retrieve required fields
    local name app_key download_dir
    name=$(systems::get_cached_json_value "$cache_key" "name")
    app_key=$(systems::get_cached_json_value "$cache_key" "app_key")
    download_dir=$(systems::get_cached_json_value "$cache_key" "download_dir")

    if [[ -z "$name" || -z "$app_key" ]]; then
        json_response::emit_error "CONFIG_ERROR" \
            "Missing required fields: name/app_key." "${name:-warp}"
        return 1
    fi

    # Fallback if download_dir not set in JSON
    if [[ -z "$download_dir" ]]; then
        download_dir="${HOME}/.cache/packwatch/artifacts/${name}"
    fi

    # Get installed version
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    # 🔑 Resolve the real .deb URL
    local url="https://app.warp.dev/download?package=deb"
    local actual_deb_url
    if ! actual_deb_url=$(networks::get_effective_url "$url"); then
        json_response::emit_error "NETWORK_ERROR" \
            "Failed to resolve download URL for $name." "$name"
        return 1
    fi

    # Extract filename from the resolved URL
    local filename
    filename=$(basename "$actual_deb_url")

    # Extract latest version directly from the filename
    local latest_version_raw
    latest_version_raw=$(echo "$filename" | grep -oP '[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.stable(\.[0-9]+)?(_[0-9]+)?')

    local latest_version
    latest_version=$(versions::strip_version_prefix "$latest_version_raw")

    if [[ -z "$latest_version" ]]; then
        json_response::emit_error "PARSING_ERROR" \
            "Failed to extract version from resolved filename for $name." "$name"
        return 1
    fi

    # Normalize installed version
    installed_version=$(versions::strip_version_prefix "$installed_version")

    # Determine status
    local output_status
    output_status=$(json_response::determine_status \
        "$installed_version" "$latest_version")

    # Early exit if up-to-date
    if [[ "$output_status" == "UP_TO_DATE" ]]; then
        json_response::emit_success "$output_status" "$latest_version" \
            "deb" "Official API"
        return 0
    fi

    # Emit success with the real URL + filename
    json_response::emit_success "$output_status" "$latest_version" \
        "deb" "Official API" \
        download_url "$actual_deb_url" \
        filename "$filename"

    # -------------------------------------------------------------------------
    # 🛡️ MD5 check: only run if a new download will happen
    # -------------------------------------------------------------------------

    # Build versioned subdir for cache: vYYYY.MM.DD
    local version_prefix
    version_prefix=$(echo "$latest_version" | cut -d'.' -f1-3) # e.g. 2025.08.27
    local versioned_dir="v${version_prefix}"

    local downloaded_file="${download_dir}/${versioned_dir}/${filename}"

    if [[ -f "$downloaded_file" ]]; then
        # The dpkg-deb sanity check is now handled by packages::process_deb_package
        # Prepare a temporary config for verifiers::verify_artifact for MD5 check
        # We explicitly skip checksum as Warp does not publish them.
        # shellcheck disable=SC2034
        local -A temp_app_config=(
            ["name"]="$name"
            ["skip_checksum"]="true"
            ["skip_md5_check"]="false" # Ensure MD5 check is performed
        )
        # Use a nameref for the temporary config
        local temp_app_config_ref="temp_app_config"

        # Perform MD5 verification using the generalized verifiers::verify_artifact
        if ! verifiers::verify_artifact "$temp_app_config_ref" "$downloaded_file" "$actual_deb_url"; then
            return 1
        fi
    fi

    return 0
}
