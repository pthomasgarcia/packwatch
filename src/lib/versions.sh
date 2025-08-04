#!/usr/bin/env bash
# ==============================================================================
# MODULE: versions.sh
# ==============================================================================
# Responsibilities:
#   - Version normalization and comparison
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/versions.sh"
#
#   Then use:
#     versions::compare_strings "1.2.3" "1.2.0"
#     versions::is_newer "2.0.0" "1.9.9"
#     versions::normalize "v1.2.3"
#
# Dependencies:
#   - errors.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Version Comparison
# ------------------------------------------------------------------------------

# Compare two semantic version strings.
# Usage: versions::compare_strings "1.2.3" "1.2.0"
# Returns:
#   0 if $1 > $2
#   1 if $1 == $2
#   2 if $1 < $2
#   3 if error
versions::compare_strings() {
	if [[ $# -ne 2 ]]; then
		errors::handle_error "VALIDATION_ERROR" "versions::compare_strings requires two arguments."
		return 3
	fi

	local v1="$1"
	local v2="$2"

	v1=$(echo "$v1" | grep -oE '^[0-9]+(\.[0-9]+)*')
	v2=$(echo "$v2" | grep -oE '^[0-9]+(\.[0-9]+)*')

	if [[ -z "$v1" ]]; then v1="0"; fi
	if [[ -z "$v2" ]]; then v2="0"; fi

	if dpkg --compare-versions "$v1" gt "$v2" 2>/dev/null; then
		return 0
	elif dpkg --compare-versions "$v1" lt "$v2" 2>/dev/null; then
		return 2
	else
		return 1
	fi
}

# Check if a version string is newer than another.
# Usage: versions::is_newer "2.0.0" "1.9.9"
# Returns 0 if $1 > $2, 1 otherwise.
versions::is_newer() {
	versions::compare_strings "$1" "$2"
	local result=$?
	if [[ "$result" -eq 0 ]]; then
		return 0
	fi
	return 1
}

# ------------------------------------------------------------------------------
# SECTION: Version Normalization
# ------------------------------------------------------------------------------

# Normalize a version string (strip leading v/V, trim whitespace).
# Usage: versions::normalize "v1.2.3"
versions::normalize() {
	local version="$1"
	# Strip leading 'v' or 'V'
	version=$(echo "$version" | sed -E 's/^[vV]//')

	# Convert common pre-release indicators to dpkg-compatible format
	# e.g., -beta.1 -> ~beta1, -rc1 -> ~rc1
	version=$(echo "$version" | sed -E 's/-alpha([0-9]*)/~alpha\1/' | sed -E 's/-beta([0-9]*)/~beta\1/' | sed -E 's/-rc([0-9]*)/~rc\1/')

	# Remove build metadata (after '+') as it's not typically used for comparison
	version=$(echo "$version" | sed -E 's/\+.*$//')

	# Trim whitespace
	echo "$version" | xargs
}

# Extract a version string from a JSON response using a jq expression.
# Usage: versions::extract_from_json "$json_data" ".tag_name" "AppName"
# Returns the normalized version string or "0.0.0" on failure.
versions::extract_from_json() {
	local json_data="$1"
	local jq_expression="$2"
	local app_name="$3"
	local raw_version

	raw_version=$(systems::get_json_value "$json_data" "$jq_expression" "$app_name")
	if [[ $? -ne 0 || -z "$raw_version" || "$raw_version" == "null" ]]; then
		loggers::log_message "WARN" "Failed to extract version for '$app_name' using JSON expression '$jq_expression'. Defaulting to 0.0.0."
		echo "0.0.0"
		return 1
	fi
	local normalized
	normalized=$(versions::normalize "$raw_version")

	if ! validators::check_semver_format "$normalized"; then
		loggers::log_message "WARN" "Invalid semver '$normalized' for '$app_name' extracted from JSON. Defaulting to 0.0.0."
		echo "0.0.0"
		return 1
	fi

	echo "$normalized"
	return 0
}

# Extract a version string from raw text using a regex pattern.
# Usage: versions::extract_from_regex "$text_data" "v([0-9.]+)" "AppName"
# Returns the normalized version string or "0.0.0" on failure.
versions::extract_from_regex() {
	local text_data="$1"
	local regex_pattern="$2"
	local app_name="$3"
	local raw_version

	raw_version=$(echo "$text_data" | grep -oE "$regex_pattern" | head -n1)
	if [[ -z "$raw_version" ]]; then
		loggers::log_message "WARN" "Failed to extract version for '$app_name' using regex '$regex_pattern'. Defaulting to 0.0.0."
		echo "0.0.0"
		return 1
	fi
	local normalized
	normalized=$(versions::normalize "$raw_version")

	if ! validators::check_semver_format "$normalized"; then
		loggers::log_message "WARN" "Invalid semver '$normalized' for '$app_name' extracted by regex. Defaulting to 0.0.0."
		echo "0.0.0"
		return 1
	fi

	echo "$normalized"
	return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
