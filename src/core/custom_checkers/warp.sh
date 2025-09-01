#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp.
#
# Dependencies:
#   - responses.sh
#   - networks.sh
#   - versions.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

_warp::get_latest_version_from_url() {
    local actual_deb_url="$1"
    local filename
    filename=$(basename "$actual_deb_url")
    echo "$filename" | grep -oP \
        '[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]{2}\.[0-9]{2})?(\.stable)?(\.[0-9]+)?(_[0-9]+)?'
}

_warp::perform_md5_check() {
    local name="$1"
    local downloaded_file="$2"
    local actual_deb_url="$3"

    if [[ -f "$downloaded_file" ]]; then
        # shellcheck disable=SC2034
        local -A temp_app_config=(
            ["name"]="$name"
            ["skip_checksum"]="true"
            ["skip_md5_check"]="false"
        )
        local temp_app_config_ref="temp_app_config"

        if ! verifiers::verify_artifact "$temp_app_config_ref" \
            "$downloaded_file" "$actual_deb_url"; then
            responses::emit_error "VALIDATION_ERROR" \
                "MD5 verification failed for $name." "$name"
            return 1
        fi
    fi
    return 0
}

check_warp() {
    local app_config_json="$1"

    local cache_key
    cache_key="warp_$(hashes::generate "$app_config_json")"
    systems::cache_json "$app_config_json" "$cache_key"

    local name app_key download_dir download_url_base
    name=$(systems::fetch_cached_json "$cache_key" "name")
    app_key=$(systems::fetch_cached_json "$cache_key" "app_key")
    download_dir=$(systems::fetch_cached_json "$cache_key" "download_dir")
    download_url_base=$(systems::fetch_cached_json "$cache_key" "download_url_base")

    if [[ -z "$name" || -z "$app_key" ]]; then
        responses::emit_error "CONFIG_ERROR" \
            "Missing required fields: name/app_key." "${name:-warp}"
        return 1
    fi

    if [[ -z "$download_dir" ]]; then
        download_dir="${HOME}/.cache/packwatch/artifacts/${name}"
    fi

    local installed_version
    installed_version=$(packages::fetch_version "$app_key")

    local url="$download_url_base"
    local actual_deb_url
    if ! actual_deb_url=$(networks::get_effective_url "$url"); then
        responses::emit_error "NETWORK_ERROR" \
            "Failed to resolve download URL for $name." "$name"
        return 1
    fi

    local latest_version_raw
    latest_version_raw=$(_warp::get_latest_version_from_url "$actual_deb_url")

    local latest_version
    latest_version=$(versions::strip_prefix "$latest_version_raw")

    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to extract version from resolved filename for $name." "$name"
        return 1
    fi

    installed_version=$(versions::strip_prefix "$installed_version")

    # Determine status
    local output_status
    output_status=$(responses::determine_status "$installed_version" \
        "$latest_version")

    # Early exit if up-to-date
    if [[ "$output_status" == "UP_TO_DATE" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" \
            "Official API"
        return 0
    fi

    # Emit success with the real URL + filename
    responses::emit_success "$output_status" "$latest_version" "deb" \
        "Official API" download_url "$actual_deb_url" \
        filename "$(basename "$actual_deb_url")" install_type "deb"

    local version_prefix
    version_prefix=$(echo "$latest_version" | cut -d'.' -f1-3)
    local versioned_dir="v${version_prefix}"

    mkdir -p "$download_dir/$versioned_dir"
    local downloaded_file
    downloaded_file="${download_dir}/${versioned_dir}/$(basename "$actual_deb_url")"

    _warp::perform_md5_check "$name" "$downloaded_file" "$actual_deb_url"
    if ! _warp::perform_md5_check "$name" "$downloaded_file" \
        "$actual_deb_url"; then
        return 1
    fi

    return 0
}
