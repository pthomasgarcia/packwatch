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

    if command -v dpkg &> /dev/null; then
        if dpkg --compare-versions "$v1" gt "$v2" 2> /dev/null; then
            return 0
        elif dpkg --compare-versions "$v1" lt "$v2" 2> /dev/null; then
            return 2
        else
            return 1
        fi
    else
        # Fallback: use sort -V for version comparison
        # Returns: 0 if v1 > v2, 1 if v1 == v2, 2 if v1 < v2
        local sorted
        sorted=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V)
        if [[ "$sorted" == "$v2\n$v1" ]]; then
            return 0 # v1 > v2
        elif [[ "$sorted" == "$v1\n$v2" ]]; then
            return 2 # v1 < v2
        else
            return 1 # v1 == v2 or error
        fi
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

    # Convert common pre-release indicators to dpkg-compatible “~” notation.
    # Handles dash or dot separators and is case-insensitive (alpha, beta, rc).
    # Examples: -alpha.1 → ~alpha1, -Beta2 → ~beta2, -RC.0 → ~rc0
    version=$(echo "$version" |
        sed -E 's/-([aA]lpha|[bB]eta|[rR][cC])[.-]?([0-9]*)/~\L\1\E\2/')

    # Remove build metadata (after '+') as it's not typically used for comparison
    version=$(echo "$version" | sed -E 's/\+.*$//')

    # Trim whitespace
    echo "$version" | xargs
}

# Extract a version string from a JSON response using a jq expression.
# Usage: versions::extract_from_json "$json_source" ".tag_name" "AppName"
# Returns the normalized version string or "0.0.0" on failure.
versions::extract_from_json() {
    local json_source="$1" # Can be a JSON string or a file path
    local jq_expression="$2"
    local app_name="$3"
    local raw_version

    raw_version=$(systems::fetch_json "$json_source" "$jq_expression" "$app_name")
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

# Normalize common version prefixes to compare versions reliably.
# Handles leading whitespace, path-like prefixes (e.g., refs/tags/),
# and textual prefixes like v, version, ver, release, stable.
versions::strip_prefix() {
    local version="$1"

    # Trim leading/trailing whitespace
    version="${version#"${version%%[![:space:]]*}"}"
    version="${version%"${version##*[![:space:]]}"}"

    # Drop common path-like refs (e.g., refs/tags/, releases/)
    version=$(printf '%s' "$version" | sed -E 's#^(refs/tags/|tags/|releases?/)+##I')

    # Drop common textual prefixes followed by separators
    version=$(printf '%s' "$version" | sed -E 's#^(v|version|ver|release|stable)[[:space:]_/:.-]*##I')

    echo "$version"
}

# Extract a version string from raw text using a regex pattern.
# Usage: versions::extract_from_regex "$text_data" "v([0-9.]+)" "AppName"
# Special sentinel: if regex_pattern is the literal string "FILENAME_REGEX" it will
# be replaced internally with the value of $VERSION_FILENAME_REGEX (see globals.sh)
# so callers can avoid duplicating that canonical pattern.
# Returns the normalized version string or "0.0.0" on failure.
versions::extract_from_regex() {
    local text_data="$1"
    local regex_pattern="$2"
    local app_name="$3"

    if [[ "$regex_pattern" == "FILENAME_REGEX" ]]; then
        if [[ -z "${VERSION_FILENAME_REGEX:-}" ]]; then
            loggers::log_message "WARN" "VERSION_FILENAME_REGEX is unset/empty; cannot extract version for '$app_name'. Defaulting to 0.0.0."
            echo "0.0.0"
            return 1
        fi
        regex_pattern="$VERSION_FILENAME_REGEX"
    fi

    local raw_version
    raw_version=$(echo "$text_data" | grep -oE -m1 "$regex_pattern")
    local grep_rc=$?
    case $grep_rc in
        0)
            : # match found, proceed
            ;;
        1)
            loggers::log_message "WARN" "Failed to extract version for '$app_name' using regex '$regex_pattern'. Defaulting to 0.0.0."
            echo "0.0.0"
            return 1
            ;;
        2)
            loggers::log_message "ERROR" "Invalid regex '$regex_pattern' used for '$app_name'."
            echo "0.0.0"
            return 1
            ;;
    esac
    if [[ -z "$raw_version" ]]; then
        # Defensive: in unlikely case of empty despite rc=0
        loggers::log_message "WARN" "Empty version match for '$app_name' with regex '$regex_pattern'. Defaulting to 0.0.0."
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
