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
	echo "$version" | sed -E 's/^[vV]//' | xargs
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
