#!/usr/bin/env bash
# ==============================================================================
# MODULE: validators.sh
# ==============================================================================
# Responsibilities:
#   - Input and file validation helpers
#   - Check URL, file path, executability, checksums, and GPG keys
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/validators.sh"
#
#   Then use:
#     validators::check_url_format "https://example.com"
#     validators::check_file_path "/usr/bin/foo"
#     validators::check_executable_file "/usr/bin/foo"
#     validators::verify_checksum "/tmp/file" "abc123" "sha256"
#     validators::verify_gpg_key "KEYID" "FINGERPRINT" "AppName"
#
# Dependencies:
#   - errors.sh
#   - globals.sh
#   - loggers.sh
#   - interfaces.sh
#   - gpg.sh # Added for _get_gpg_fingerprint_as_user
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: URL and File Path Validators
# ------------------------------------------------------------------------------

# Check if a URL format is valid (http/https, basic domain/path check).
# Usage: validators::check_url_format "https://example.com"
validators::check_url_format() {
    local url="$1"
    [[ -n "$url" ]] && [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]
}

# Check if a URL uses HTTPS.
# Usage: validators::check_https_url "https://example.com"
# Returns 0 if the URL starts with https://, 1 otherwise.
validators::check_https_url() {
    local url="$1"
    if [[ "$url" =~ ^https:// ]]; then
        return 0 # Valid HTTPS URL
    else
        return 1 # Invalid (not HTTPS)
    fi
}

# Check if a file path is safe (prevents directory traversal).
# Usage: validators::check_file_path "/usr/bin/foo"
validators::check_file_path() {
    local path="$1"
    [[ -n "$path" ]] &&
        [[ ! "$path" =~ \.\. ]] &&
        [[ "$path" =~ ^(~|\/)([a-zA-Z0-9.\/_-]*)$ ]]
}

# Check if a file is executable.
# Usage: validators::check_executable_file "/usr/bin/foo"
validators::check_executable_file() {
    local file_path="$1"
    [[ -f "$file_path" ]] && [[ -x "$file_path" ]] && validators::check_file_path "$file_path"
}

# ------------------------------------------------------------------------------
# SECTION: Checksum and GPG Validators
# ------------------------------------------------------------------------------

# # Verify a GPG key's fingerprint against an expected value.
# # Usage: validators::verify_gpg_key "KEYID" "FINGERPRINT" "AppName"
# validators::verify_gpg_key() {
#     local key_id="$1"
#     local expected_fingerprint="$2"
#     local app_name="${3:-unknown}"

#     if [[ -z "$key_id" ]] || [[ -z "$expected_fingerprint" ]]; then
#         errors::handle_error "GPG_ERROR" "Missing GPG key ID or fingerprint for GPG verification" "$app_name"
#         return 1
#     fi

#     local actual_fingerprint

#     # Ensure gpg.sh is sourced to use _get_gpg_fingerprint_as_user
#     # shellcheck source=/dev/null
#     source "$LIB_DIR/gpg.sh"

#     actual_fingerprint=$(_get_gpg_fingerprint_as_user "$key_id")

#     if [[ -z "$actual_fingerprint" ]]; then
#         loggers::log_message "ERROR" "GPG fingerprint retrieval failed for key ID '$key_id'. This may indicate a security downgrade if falling back to root."
#         errors::handle_error "GPG_ERROR" "GPG key not found in keyring for user '$ORIGINAL_USER': '$key_id'" "$app_name"
#         loggers::log_message "INFO" "Please import the GPG key manually and verify its fingerprint:"
#         loggers::log_message "INFO" "  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys '$key_id'"
#         loggers::log_message "INFO" "  gpg --fingerprint '$key_id'"
#         return 1
#     fi

#     local normalized_expected
#     normalized_expected="${expected_fingerprint//[[:space:]]/}"
#     local normalized_actual
#     normalized_actual="${actual_fingerprint//[[:space:]]/}"

#     if [[ "$normalized_actual" != "$normalized_expected" ]]; then
#         errors::handle_error "GPG_ERROR" "GPG key fingerprint mismatch. Expected: '$expected_fingerprint', Got: '$actual_fingerprint'" "$app_name"
#         return 1
#     fi

#     loggers::log_message "DEBUG" "GPG key verification successful for: '$key_id'"
#     interfaces::print_ui_line "  " "✓ " "GPG key verified: $key_id" "${COLOR_GREEN}"
#     return 0
# }

validators::extract_checksum_from_file() {
    local checksum_file="$1"
    local target_name="$2"
    [[ -f "$checksum_file" ]] || return 1
    local line
    if [[ -n "$target_name" ]]; then
        line=$(grep -Ei "^[0-9a-f]{64}\s+(\*|)${target_name//\./\\.}\s*$" "$checksum_file" | head -n1)
    fi
    line=${line:-$(head -n1 "$checksum_file")}
    awk '{print $1}' <<<"$line"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================

# Check if a string is a valid semantic version (basic check).
# Allows for X.Y.Z, X.Y, X, and optional pre-release/build metadata.
# Usage: validators::check_semver_format "1.2.3"
# Returns 0 for valid, 1 for invalid.
validators::check_semver_format() {
    local version="$1"
    # Regex for semantic versioning: MAJOR.MINOR.PATCH-prerelease+build
    # Allows for just major, major.minor, major.minor.patch
    # Allows alphanumeric for pre-release and build metadata
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*(-[0-9a-zA-Z.-]+)?(\+[0-9a-zA-Z.-]+)?$ ]]
}
