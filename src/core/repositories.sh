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
#     repositories::find_asset_url "$release_json" "pattern" "AppName"
#     repositories::find_asset_checksum "$release_json" "filename"
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - networks.sh
#   - systems.sh
#   - versions.sh
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
	networks::fetch_cached_data "$api_url" "json"
}

# Parse the version from a release JSON object.
# Usage: repositories::parse_version_from_release "$release_json" "AppName"
repositories::parse_version_from_release() {
	local release_json="$1"
	local app_name="$2"

	local raw_tag_name
	raw_tag_name=$(systems::get_json_value "$release_json" '.tag_name' "$app_name")
	if [[ $? -ne 0 ]]; then return 1; fi

	local latest_version
	if ! latest_version=$(versions::extract_from_json "$release_json" ".tag_name" "$app_name"); then
		errors::handle_error "PARSING_ERROR" "Failed to get version from latest release." "$app_name"
		return 1
	fi

	if [[ -z "$latest_version" ]]; then
		errors::handle_error "VALIDATION_ERROR" "Failed to detect latest version for '$app_name' from tag '$raw_tag_name'." "$app_name"
		return 1
	fi

	echo "$latest_version"
}

# Find a specific asset's download URL from a release JSON.
# Usage: repositories::find_asset_url "$release_json" "pattern" "AppName"
repositories::find_asset_url() {
	local release_json="$1"
	local filename_pattern="$2"
	local app_name="$3"

	# First, try exact string matching (for patterns like "fastfetch-linux-amd64.deb")
	local url
	url=$(systems::get_json_value "$release_json" ".assets[] | select(.name == \"${filename_pattern}\") | .browser_download_url" "$app_name" 2>/dev/null)

	if [[ -n "$url" ]]; then
		echo "$url"
		return 0
	fi

	# If exact match fails, treat as regex pattern (for patterns with placeholders like "ghostty_%s.ppa2_amd64_25.04.deb")
	# Escape special regex characters except %s which we'll handle as a placeholder
	local escaped_pattern
	escaped_pattern=$(printf '%s\n' "$filename_pattern" | sed 's/[]\/$*.^|()+{}[]/\\&/g; s/%s/.*/g')

	url=$(systems::get_json_value "$release_json" ".assets[] | select(.name | test(\"${escaped_pattern}\")) | .browser_download_url" "$app_name" 2>/dev/null)

	if [[ -n "$url" ]]; then
		echo "$url"
		return 0
	fi

	# If both methods fail, return error
	errors::handle_error "NETWORK_ERROR" "Download URL not found or invalid for '${filename_pattern}'." "$app_name"
	return 1
}

# Find and extract a checksum for a given asset from a release.
# Usage: repositories::find_asset_checksum "$release_json" "filename"
repositories::find_asset_checksum() {
	local release_json="$1"
	local target_filename="$2"

	local checksum_file_url
	checksum_file_url=$(systems::get_json_value "$release_json" '.assets[] | select(.name | (endswith("sha256sum.txt") or endswith("checksums.txt"))) | .browser_download_url' "Repository Release Checksum URL")
	if [[ $? -ne 0 || -z "$checksum_file_url" ]]; then
		return 0 # Not an error if checksum file doesn't exist
	fi

	local temp_checksum_file
	temp_checksum_file=$(systems::create_temp_file "checksum_file")
	if [[ $? -ne 0 ]]; then return 1; fi

	local extracted_checksum=""
	if networks::download_file "$checksum_file_url" "$temp_checksum_file" ""; then
		local checksum_file_content
		checksum_file_content=$(cat "$temp_checksum_file")
		extracted_checksum=$(echo "$checksum_file_content" | grep -oP "^\s*[0-9a-fA-F]+\s+[\*]?${target_filename}\s*$" | awk '{print $1}' | head -n1)
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
