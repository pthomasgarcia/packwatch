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

# The _get_gpg_fingerprint_as_user function has been removed.
# The new approach relies exclusively on temporary GPG keyrings for verification,
# which is more robust and suitable for automation.

_gpg_prepare_temp_keyring_with_key() {
    local source="$1" key_id="$2" key_url="$3"
    local tmp
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"
    case "$source" in
        url)
            local f="$tmp/key.asc"
            curl -fsSL "$key_url" -o "$f" || {
                rm -rf "$tmp"
                return 1
            }
            gpg --homedir "$tmp" --import "$f" > /dev/null 2>&1 || {
                rm -rf "$tmp"
                return 1
            }
            ;;
        keyserver)
            gpg --homedir "$tmp" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key_id" > /dev/null 2>&1 || {
                rm -rf "$tmp"
                return 1
            }
            ;;
        wkd)
            GNUPGHOME="$tmp" gpg --auto-key-locate clear,wkd --locate-keys "$key_id" > /dev/null 2>&1 || {
                rm -rf "$tmp"
                return 1
            }
            ;;
        user_keyring)
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

gpg::verify_detached() {
    local file="$1" sig="$2" key_id="$3" expected_fp="$4" source="${5:-user_keyring}" key_url="${6:-}"
    local home
    home=$(_gpg_prepare_temp_keyring_with_key "$source" "$key_id" "$key_url") || return 1
    local actual_fp
    actual_fp=$(GNUPGHOME="$home" gpg --fingerprint --with-colons "$key_id" 2> /dev/null | awk -F: '/^fpr:/ {print $10}' | head -n1)
    local nx="${expected_fp//[[:space:]]/}" na="${actual_fp//[[:space:]]/}"
    if [[ -z "$na" || "$na" != "$nx" ]]; then
        [[ "$home" != "${ORIGINAL_HOME:-$HOME}/.gnupg" ]] && rm -rf "$home"
        errors::handle_error "GPG_ERROR" "Fingerprint mismatch. Expected $expected_fp, got ${actual_fp:-<none>}"
        return 1
    fi
    GNUPGHOME="$home" gpg --verify "$sig" "$file" > /dev/null 2>&1 || {
        [[ "$home" != "${ORIGINAL_HOME:-$HOME}/.gnupg" ]] && rm -rf "$home"
        errors::handle_error "GPG_ERROR" "Signature verification failed"
        return 1
    }
    [[ "$home" != "${ORIGINAL_HOME:-$HOME}/.gnupg" ]] && rm -rf "$home"

    return 0
}

# The gpg::prompt_import_and_verify function has been removed.
# Interactive key import is not suitable for an automated, non-interactive context.
# Key management should be handled by the user or a separate provisioning script.
