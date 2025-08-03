#!/usr/bin/env bash

# Custom checker for Zed
check_zed() {
	local -n app_config_ref=$1
	local name="${app_config_ref[name]}"
	local app_key="${app_config_ref[app_key]}"
	local flatpak_app_id="${app_config_ref[flatpak_app_id]}"

	local installed_version
	installed_version=$(packages::get_installed_version "$app_key")
	local latest_version
	latest_version=$(
		systems::reattempt_command 3 5 flatpak remote-info flathub "$flatpak_app_id" |
			awk -F: '/Version:/ {print $2}' | xargs
	)

	if [[ -z "$latest_version" ]]; then
		errors::handle_error "CUSTOM_CHECKER_ERROR" "Failed to retrieve latest version for $name." "zed"
		return 1
	fi

	# STRIP LEADING 'v'
	installed_version=$(checker_utils::strip_version_prefix "$installed_version")
	latest_version=$(checker_utils::strip_version_prefix "$latest_version")

	loggers::log_message "DEBUG" "ZED: installed_version='$installed_version' latest_version='$latest_version'"

	local output_status
	output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

	jq -n \
		--arg status "$output_status" \
		--arg latest_version "$latest_version" \
		--arg flatpak_app_id "$flatpak_app_id" \
		--arg install_type "flatpak" \
		--arg source "Flathub" \
		'{
          "status": $status,
          "latest_version": $latest_version,
          "flatpak_app_id": $flatpak_app_id,
          "install_type": $install_type,
          "source": $source
        }'

	return 0
}
