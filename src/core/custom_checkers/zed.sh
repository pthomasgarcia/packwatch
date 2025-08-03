#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/zed.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Zed.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
# ==============================================================================

# Custom checker for Zed
check_zed() {
	local app_config_json="$1" # Now receives JSON string
	local name=$(echo "$app_config_json" | jq -r '.name')
	local app_key=$(echo "$app_config_json" | jq -r '.app_key')
	local flatpak_app_id=$(echo "$app_config_json" | jq -r '.flatpak_app_id')

	local installed_version
	installed_version=$(packages::get_installed_version "$app_key")
	local latest_version
	latest_version=$(
		systems::reattempt_command 3 5 flatpak remote-info flathub "$flatpak_app_id" |
			awk -F: '/Version:/ {print $2}' | xargs
	)

	if [[ -z "$latest_version" ]]; then
		jq -n \
			--arg status "error" \
			--arg error_message "Failed to retrieve latest version for $name." \
			--arg error_type "NETWORK_ERROR" \
			'{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
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
		--arg error_type "NONE" \
		'{
	         "status": $status,
	         "latest_version": $latest_version,
	         "flatpak_app_id": $flatpak_app_id,
	         "install_type": $install_type,
	         "source": $source,
	         "error_type": $error_type
	       }'

	return 0
}
