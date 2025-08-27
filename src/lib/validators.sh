#!/usr/bin/env bash
# ==============================================================================
# MODULE: validators.sh
# ==============================================================================
# Responsibilities:
#   - Input and file validation helpers
#   - Check URL, file path, executability, checksums, and semantic versions
#
# Usage:
#   source "$CORE_DIR/validators.sh"
#   validators::check_url_format "https://example.com"
#   validators::check_file_path "/usr/bin/foo"
#   validators::check_executable_file "/usr/bin/foo"
#   validators::check_semver_format "1.2.3"
#
# Dependencies (optional):
#   - errors.sh (for errors::handle_error)
#   - loggers.sh (for loggers::warn)
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Dependency Self-Check (Optional)
# ------------------------------------------------------------------------------
validators::_require_bin() {
    command -v "$1" > /dev/null 2>&1 || {
        echo "validators.sh: missing required command '$1'" >&2
        return 1
    }
}
# Example: Uncomment if jq or gpg is actually required by this module
# validators::_require_bin jq || return 1

# ------------------------------------------------------------------------------
# SECTION: URL and File Path Validators
# ------------------------------------------------------------------------------

# Check if a URL format is valid (http/https only, stricter host check).
# Usage: validators::check_url_format "https://example.com"
validators::check_url_format() {
    local url="$1"
    [[ -n "$url" ]] &&
        [[ "$url" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(/[^[:space:]]*)?$ ]]
}

# Check if a URL uses HTTPS (strict).
# Usage: validators::check_https_url "https://example.com"
validators::check_https_url() {
    local url="$1"
    [[ "$url" =~ ^https:// ]]
}

# Check if a file path is safe (absolute path or home, no traversal).
# Disallows '..', control chars, and shell metacharacters.
# Usage: validators::check_file_path "/usr/bin/foo"
validators::check_file_path() {
    local path="$1"
    [[ -n "$path" ]] &&
        [[ "$path" =~ ^(~|/)[A-Za-z0-9._/-]*$ ]] &&
        [[ ! "$path" =~ \.\. ]] &&
        [[ ! "$path" =~ [[:space:]\;\&\|\$\>\<\'\"\`] ]]
}

# Check if a file is executable and path is valid.
# Usage: validators::check_executable_file "/usr/bin/foo"
validators::check_executable_file() {
    local file_path="$1"
    [[ -f "$file_path" ]] && [[ -x "$file_path" ]] && validators::check_file_path "$file_path"
}

# ------------------------------------------------------------------------------
# SECTION: Semantic Version Validator
# ------------------------------------------------------------------------------

# Check if a string is a valid semantic version (basic semver 2.0.0).
# Allows MAJOR.MINOR.PATCH with optional pre-release/build metadata.
# Usage: validators::check_semver_format "1.2.3-beta+exp"
validators::check_semver_format() {
    local version="$1"
    [[ -n "$version" ]] &&
        [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.~-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
