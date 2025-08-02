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

# Check if a file path is safe (prevents directory traversal).
# Usage: validators::check_file_path "/usr/bin/foo"
validators::check_file_path() {
    local path="$1"
    [[ -n "$path" ]] && \
    [[ ! "$path" =~ \.\. ]] && \
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

# Verify a file's checksum against an expected value.
# Usage: validators::verify_checksum "/tmp/file" "abc123" "sha256"
validators::verify_checksum() {
    local file_path="$1"
    local expected_checksum="$2"
    local algorithm="${3:-sha256}" # Default to sha256 if not provided

    if [[ ! -f "$file_path" ]]; then
        errors::handle_error "VALIDATION_ERROR" "File not found for checksum verification: '$file_path'"
        return 1
    fi

    local actual_checksum
    case "$algorithm" in
        sha256) actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1) ;;
        sha1)   actual_checksum=$(sha1sum "$file_path" | cut -d' ' -f1) ;;
        md5)    actual_checksum=$(md5sum "$file_path" | cut -d' ' -f1) ;;
        *)
            errors::handle_error "VALIDATION_ERROR" "Unsupported checksum algorithm: '$algorithm'"
            return 1
            ;;
    esac

    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Checksum mismatch for '$file_path': expected '$expected_checksum', got '$actual_checksum'"
        return 1
    fi

    loggers::log_message "DEBUG" "Checksum verified for '$file_path'"
    loggers::print_ui_line "  " "✓ " "Checksum verified." _color_green
    return 0
}

# Verify a GPG key's fingerprint against an expected value.
# Usage: validators::verify_gpg_key "KEYID" "FINGERPRINT" "AppName"
validators::verify_gpg_key() {
    local key_id="$1"
    local expected_fingerprint="$2"
    local app_name="${3:-unknown}"

    if [[ -z "$key_id" ]] || [[ -z "$expected_fingerprint" ]]; then
        errors::handle_error "GPG_ERROR" "Missing GPG key ID or fingerprint for GPG verification" "$app_name"
        return 1
    fi

    local actual_fingerprint
    local original_user_id_for_sudo=""
    if [[ -n "$ORIGINAL_USER" ]]; then
        original_user_id_for_sudo=$(getent passwd "$ORIGINAL_USER" | cut -d: -f3 2>/dev/null)
    fi

    if [[ -z "$original_user_id_for_sudo" ]]; then
        loggers::log_message "WARN" "ORIGINAL_USER is invalid or empty ('$ORIGINAL_USER'). Cannot perform GPG verification as original user. Attempting as current user (root)."
        actual_fingerprint=$(gpg --fingerprint --with-colons "$key_id" 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | head -n1)
    else
        actual_fingerprint=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
            gpg --fingerprint --with-colons "$key_id" 2>/dev/null | \
            awk -F: '/^fpr:/ {print $10}' | head -n1)
    fi

    if [[ -z "$actual_fingerprint" ]]; then
        errors::handle_error "GPG_ERROR" "GPG key not found in keyring for user '$ORIGINAL_USER': '$key_id'" "$app_name"
        loggers::log_message "INFO" "Please import the GPG key manually and verify its fingerprint:"
        loggers::log_message "INFO" "  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys '$key_id'"
        loggers::log_message "INFO" "  gpg --fingerprint '$key_id'"
        return 1
    fi

    local normalized_expected
    normalized_expected="${expected_fingerprint//[[:space:]]/}"
    local normalized_actual
    normalized_actual="${actual_fingerprint//[[:space:]]/}"

    if [[ "$normalized_actual" != "$normalized_expected" ]]; then
        errors::handle_error "GPG_ERROR" "GPG key fingerprint mismatch. Expected: '$expected_fingerprint', Got: '$actual_fingerprint'" "$app_name"
        return 1
    fi

    loggers::log_message "DEBUG" "GPG key verification successful for: '$key_id'"
    loggers::print_ui_line "  " "✓ " "GPG key verified: $key_id" _color_green
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
