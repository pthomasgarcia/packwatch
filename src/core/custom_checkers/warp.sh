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
#   - configs.sh
# ==============================================================================

_warp::get_latest_version_from_repo() {
    curl -s https://releases.warp.dev/linux/deb/dists/stable/main/binary-amd64/Packages |
        awk '/^Package: warp-terminal$/ {found=1} found && /^Version:/ {print $2; exit}'
}

warp::check() {
    local app_config_json="$1"

    local -A app_info
    if ! configs::get_cached_app_info "$app_config_json" app_info; then
        return 1
    fi

    local name="${app_info["name"]}"
    local app_key="${app_info["app_key"]}"
    local installed_version
    if ! installed_version=$(packages::fetch_version "$app_key"); then
        installed_version="${app_info["installed_version"]}"
    fi
    local cache_key="${app_info["cache_key"]}"

    local download_url_base
    download_url_base=$(systems::fetch_cached_json "$cache_key" "download_url_base")

    local latest_version
    latest_version=$(_warp::get_latest_version_from_repo)

    if [[ -z "$latest_version" ]]; then
        responses::emit_error "PARSING_ERROR" \
            "Failed to extract version from apt repo for $name." "$name"
        return 1
    fi

    installed_version=$(versions::strip_prefix "$installed_version")
    latest_version=$(versions::strip_prefix "$latest_version" | sed 's/^0\.//')

    local output_status
    output_status=$(responses::determine_status "$installed_version" \
        "$latest_version")

    if [[ "$output_status" == "no_update" ]]; then
        responses::emit_success "$output_status" "$latest_version" "deb" \
            "Warp Apt Repo"
        return 0
    fi

    # If an update is needed, resolve the download URL from the website
    local actual_deb_url
    if ! actual_deb_url=$(networks::get_effective_url "$download_url_base"); then
        responses::emit_error "NETWORK_ERROR" \
            "Failed to resolve download URL for $name." "$name"
        return 1
    fi

    responses::emit_success "$output_status" "$latest_version" "deb" \
        "Warp Apt Repo" download_url "$actual_deb_url" \
        filename "$(basename "$actual_deb_url")" install_type "deb"

    return 0
}
