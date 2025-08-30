#!/usr/bin/env bash
# Idempotent guard for gpg module
if [ -n "${PACKWATCH_GPG_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_GPG_LOADED=1

# GPG module; provides functions for GPG key management and verification.
#
# Dependencies:
#   - errors.sh
#   - globals.sh
#   - interfaces.sh
#   - loggers.sh
# ==============================================================================

# Helper: cleanup temporary GPG home unless it's the real user keyring
_gpg_cleanup_home() {
    local home="$1"
    [[ "$home" != "${ORIGINAL_HOME:-$HOME}/.gnupg" ]] && rm -rf "$home"
}

# Prepare a temporary keyring with the given key
_gpg_prepare_temp_keyring_with_key() {
    local source="$1" key_id="$2" key_url="$3"
    local tmp
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"

    case "$source" in
        url)
            local f="$tmp/key.asc"
            if ! curl -fsSL "$key_url" -o "$f"; then
                rm -rf "$tmp"
                return 1
            fi
            if ! gpg --homedir "$tmp" --import "$f" > /dev/null 2>&1; then
                rm -rf "$tmp"
                return 1
            fi
            ;;
        keyserver)
            if ! gpg --homedir "$tmp" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key_id" > /dev/null 2>&1; then
                rm -rf "$tmp"
                return 1
            fi
            ;;
        wkd)
            if ! GNUPGHOME="$tmp" gpg --auto-key-locate clear,wkd --locate-keys "$key_id" > /dev/null 2>&1; then
                rm -rf "$tmp"
                return 1
            fi
            ;;
        user_keyring)
            # Use the permanent user keyring instead of a temp one
            echo "${ORIGINAL_HOME:-$HOME}/.gnupg"
            return 0
            ;;
        *)
            rm -rf "$tmp"
            return 1
            ;;
    esac
    echo "$tmp"
}

# Verify a detached signature against a file
gpg::verify_detached() {
    local file="$1" sig="$2" key_id="$3" expected_fp="$4" source="${5:-user_keyring}" key_url="${6:-}"
    local home
    home=$(_gpg_prepare_temp_keyring_with_key "$source" "$key_id" "$key_url") || return 1

    # Extract actual fingerprint
    local actual_fp
    actual_fp=$(GNUPGHOME="$home" gpg --fingerprint --with-colons "$key_id" 2> /dev/null | awk -F: '/^fpr:/ {print $10}' | head -n1)

    local nx="${expected_fp//[[:space:]]/}" na="${actual_fp//[[:space:]]/}"
    if [[ -z "$na" || "$na" != "$nx" ]]; then
        _gpg_cleanup_home "$home"
        errors::handle_error "GPG_ERROR" "Fingerprint mismatch. Expected $expected_fp, got ${actual_fp:-<none>}"
        return 1
    fi

    # Verify signature
    local gpg_err
    if ! gpg_err=$(GNUPGHOME="$home" gpg --verify "$sig" "$file" 2>&1); then
        _gpg_cleanup_home "$home"
        errors::handle_error "GPG_ERROR" "Signature verification failed: $gpg_err"
        return 1
    fi

    _gpg_cleanup_home "$home"
    return 0
}
