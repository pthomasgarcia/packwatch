#!/usr/bin/env bash
# ==============================================================================
# MODULE: custom_checkers/warp.sh
# ==============================================================================
# Responsibilities:
#   - Custom logic to check for updates for Warp.
#
# Dependencies:
#   - util/checker_utils.sh
#   - errors.sh
#   - packages.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# Custom checker for Warp with direct curl calls
check_warp() {
	local app_config_json="$1" # Now receives JSON string
	local name=$(echo "$app_config_json" | jq -r '.name')
	local app_key=$(echo "$app_config_json" | jq -r '.app_key')
	local installed_version
	installed_version=$(packages::get_installed_version "$app_key")

	local url="https://app.warp.dev/get_warp?package=deb"
	local html_content_path # This will now be a file path
	if ! html_content_path=$(networks::fetch_cached_data "$url" "html") || [[ ! -f "$html_content_path" ]]; then
		jq -n \
			--arg status "error" \
			--arg error_message "Failed to fetch download page for $name." \
			--arg error_type "NETWORK_ERROR" \
			'{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
		return 1
	fi

	local latest_version_raw
	# Read content from the file for regex matching
	local html_content
	html_content=$(cat "$html_content_path")
	# loggers::log_message "DEBUG" "Warp HTML content (first 500 chars): ${html_content:0:500}..."
	latest_version_raw=$(echo "$html_content" | grep -oP '[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.stable_[0-9]+' | head -1)
	loggers::log_message "DEBUG" "Extracted latest_version_raw for Warp: '$latest_version_raw'"

	# Use the new utility function for consistency
	local latest_version
	latest_version=$(checker_utils::strip_version_prefix "$latest_version_raw")

	if [[ -z "$latest_version" ]]; then
		jq -n \
			--arg status "error" \
			--arg error_message "Failed to extract version for $name." \
			--arg error_type "PARSING_ERROR" \
			'{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
		return 1
	fi

	local actual_deb_url=""
	actual_deb_url=$(networks::get_effective_url "https://app.warp.dev/download?package=deb")

	if [[ -z "$actual_deb_url" ]] || ! validators::check_url_format "$actual_deb_url"; then
		jq -n \
			--arg status "error" \
			--arg error_message "Failed to resolve download URL for $name." \
			--arg error_type "NETWORK_ERROR" \
			'{ "status": $status, "error_message": $error_message, "error_type": $error_type }'
		return 1
	fi

	local output_status
	output_status=$(checker_utils::determine_status "$installed_version" "$latest_version")

	jq -n \
		--arg status "$output_status" \
		--arg latest_version "$latest_version" \
		--arg download_url "$actual_deb_url" \
		--arg install_type "deb" \
		--arg source "Official API" \
		--arg error_type "NONE" \
		'{
	         "status": $status,
	         "latest_version": $latest_version,
	         "download_url": $download_url,
	         "install_type": $install_type,
	         "source": $source,
	         "error_type": $error_type
	       }'

	return 0
}
