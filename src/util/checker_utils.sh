#!/usr/bin/env bash
# ==============================================================================
# MODULE: util/checker_utils.sh
# ==============================================================================
# Responsibilities:
#   - Minimal utilities for custom checkers.
#
# Dependencies:
#   - updates.sh
# ==============================================================================

# Minimal utilities for custom checkers

checker_utils::determine_status() {
	local installed_version="$1"
	local latest_version="$2"

	if ! updates::is_needed "$installed_version" "$latest_version"; then
		echo "no_update"
	else
		echo "success"
	fi
}

checker_utils::strip_version_prefix() {
	local version="$1"
	echo "${version#v}"
}
