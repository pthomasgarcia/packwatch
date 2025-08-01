#!/usr/bin/env bash

# Custom checker for Warp with direct curl calls
check_warp() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local installed_version
    installed_version=$(packages::get_installed_version "$app_key")

    local url="https://app.warp.dev/get_warp?package=deb"
    local html_content
    html_content=$(systems::reattempt_command 3 5 curl -s -L -A "${NETWORK_CONFIG[USER_AGENT]}" "$url")
    if [ $? -ne 0 ] || [ -z "$html_content" ]; then
        jq -n --arg name "$name" '{status: "error", error_message: "Failed to fetch download page for \($name).", error_code: "NETWORK_ERROR"}'
        return 1
    fi

    local latest_version_raw
    latest_version_raw=$(echo "$html_content" | grep -oP 'window\.warp_app_version="v\K[^"]+' | head -1)
    local latest_version
    latest_version=$(echo "$latest_version_raw" | sed 's/^v//')

    if [[ -z "$latest_version" ]]; then
        jq -n --arg name "$name" '{status: "error", error_message: "Failed to extract version for \($name).", error_code: "VALIDATION_ERROR"}'
        return 1
    fi

    local actual_deb_url=""
    actual_deb_url=$(systems::reattempt_command 3 5 curl -s -L \
        -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
        -o /dev/null \
        -w "%{url_effective}\n" \
        "https://app.warp.dev/download?package=deb" | tr -d '\r')

    if [[ -z "$actual_deb_url" ]] || ! validators::check_url_format "$actual_deb_url"; then
        jq -n --arg name "$name" '{status: "error", error_message: "Failed to resolve download URL for \($name).", error_code: "NETWORK_ERROR"}'
        return 1
    fi

    local output_status="success"
    if ! updates::is_needed "$installed_version" "$latest_version"; then
        output_status="no_update"
    fi

    jq -n \
        --arg status "$output_status" \
        --arg latest_version "$latest_version" \
        --arg download_url "$actual_deb_url" \
        --arg install_type "deb" \
        --arg source "Official API" \
        '{
          "status": $status,
          "latest_version": $latest_version,
          "download_url": $download_url,
          "install_type": $install_type,
          "source": $source
        }'

    return 0
}