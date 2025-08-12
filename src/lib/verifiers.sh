#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for verifiers module
if [ -n "${PACKWATCH_VERIFIERS_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_VERIFIERS_LOADED=1

# Centralized checksum and signature verification for downloaded artifacts.

# Expected dependencies to be sourced by runtime:
# - loggers.sh, interfaces.sh, errors.sh, systems.sh, networks.sh
# - validators.sh (for extract_checksum_from_file)
# - gpg.sh (conditionally loaded by init/extensions.sh when needed)
# - updates.sh (for updates::trigger_hooks)

# --------------------------------------------------------------------
# Public: compute hash for a file
# Usage: verifiers::compute_checksum "path" ["sha256"|"sha512"]
# Prints hash to stdout
# --------------------------------------------------------------------
verifiers::compute_checksum() {
    local file_path="$1"
    local algorithm="${2:-sha256}"
    case "${algorithm,,}" in
    sha512) sha512sum "$file_path" | awk '{print $1}' ;;
    sha256 | *) sha256sum "$file_path" | awk '{print $1}' ;;
    esac
}

# --------------------------------------------------------------------
# Public: verify file checksum
# Usage: verifiers::verify_checksum "path" "expected" ["sha256"|"sha512"]
# Returns 0 on match, 1 on mismatch
# --------------------------------------------------------------------
verifiers::verify_checksum() {
    local file_path="$1"
    local expected="$2"
    local algorithm="${3:-sha256}"

    local actual
    actual="$(verifiers::compute_checksum "$file_path" "$algorithm")"

    interfaces::print_ui_line "  " "→ " "Expected checksum (${algorithm,,}): $expected"
    interfaces::print_ui_line "  " "→ " "Actual checksum:   $actual"

    if [[ "$expected" == "$actual" ]]; then
        interfaces::print_ui_line "  " "✓ " "Checksum verified." "${COLOR_GREEN}"
        return 0
    else
        interfaces::print_ui_line "  " "✗ " "Checksum verification FAILED." "${COLOR_RED}"
        return 1
    fi
}

# --------------------------------------------------------------------
# Private: emit POST_VERIFY_HOOKS payload (backward compatible)
# --------------------------------------------------------------------
verifiers::_emit_verify_hook() {
    local kind="$1"
    local success_flag="$2"
    local expected="$3"
    local actual="$4"
    local algo="$5"
    local app_name="$6"
    local file_path="$7"
    local download_url="$8"

    # Optional params (safe with `set -u`)
    local key_id="${9-}"
    local fingerprint="${10-}"

    local success_json
    if [[ "$success_flag" -eq 1 ]]; then
        success_json=true
    else
        success_json=false
    fi

    # Backward-compatible core fields plus richer metadata
    local details
    details=$(jq -n \
        --arg phase "verify" \
        --arg kind "$kind" \
        --arg algorithm "$algo" \
        --arg expected "$expected" \
        --arg actual "$actual" \
        --arg file "$file_path" \
        --arg url "$download_url" \
        --arg key_id "$key_id" \
        --arg fingerprint "$fingerprint" \
        --arg app "$app_name" \
        --arg time "$(date -Is)" \
        --arg source "verifiers::verify_artifact" \
        --argjson success "$success_json" \
        '{
            phase: $phase,
            kind: $kind,
            success: $success,
            algorithm: $algorithm,
            expected: $expected,
            actual: $actual,
            file: $file,
            url: $url,
            key_id: $key_id,
            fingerprint: $fingerprint,
            app: $app,
            time: $time,
            source: $source
        }')

    updates::trigger_hooks POST_VERIFY_HOOKS "$app_name" "$details"
}

# --------------------------------------------------------------------
# Public: resolve expected checksum (no repository parsing here)
# Priority:
#  1) direct_checksum (arg 4)
#  2) checksum_url (config)
# Returns checksum to stdout or empty string if not found.
# If checksum_url is configured but download fails, return 1 (hard fail).
# --------------------------------------------------------------------
verifiers::resolve_expected_checksum() {
    local config_ref_name="$1"
    local downloaded_file_path="$2"
    local _download_url_unused="$3"
    local direct_checksum="${4:-}"

    local -n cfg="$config_ref_name"
    local allow_http="${cfg[allow_insecure_http]:-0}"
    local app_name="${cfg[name]:-unknown}"

    # 1) Directly provided
    if [[ -n "$direct_checksum" ]]; then
        loggers::log_message "DEBUG" "Using directly provided checksum for '$app_name'."
        echo "$direct_checksum"
        return 0
    fi

    # 2) From checksum_url (treat as required if set)
    local checksum_url="${cfg[checksum_url]:-}"
    if [[ -n "$checksum_url" ]]; then
        interfaces::print_ui_line "  " "→ " "Downloading checksum for verification..."
        local csf
        csf=$(networks::download_text_to_cache "$checksum_url" "$allow_http") || {
            # Caller will decide how to report; by contract, checksum_url implies hard fail on download error
            echo ""
            return 1
        }
        local expected
        expected=$(validators::extract_checksum_from_file \
            "$csf" "$(basename "$downloaded_file_path" | cut -d'?' -f1)")
        systems::unregister_temp_file "$csf"
        if [[ -n "$expected" ]]; then
            echo "$expected"
            return 0
        fi
        # If the file was fetched but didn’t contain an entry, we just return empty.
    fi

    echo "" # No checksum found
    return 0
}

# -----------------------------
# Public: verify GPG signature
# Uses sig_url override or ${download_url}.sig; if no override and .sig fails,
# attempts ${download_url}.asc as a fallback.
# Returns 0 on success, 1 on failure.
# -----------------------------
verifiers::verify_signature() {
    local config_ref_name="$1"
    local downloaded_file_path="$2"
    local download_url="$3"

    local -n cfg="$config_ref_name"
    local app_name="${cfg[name]:-unknown}"
    local allow_http="${cfg[allow_insecure_http]:-0}"
    local gpg_key_id="${cfg[gpg_key_id]:-}"
    local gpg_fingerprint="${cfg[gpg_fingerprint]:-}"
    local sig_url_override="${cfg[sig_url]:-}"

    if [[ -z "$gpg_key_id" || -z "$gpg_fingerprint" ]]; then
        loggers::log_message "DEBUG" "No gpg_key_id or gpg_fingerprint configured for '$app_name'. Skipping GPG verification."
        return 0
    fi

    local sig_download_url
    local used_fallback=0
    if [[ -n "$sig_url_override" ]]; then
        sig_download_url="$sig_url_override"
    else
        sig_download_url="${download_url}.sig"
    fi

    interfaces::print_ui_line "  " "→ " "Downloading signature for verification..."
    local sigf
    sigf=$(networks::download_text_to_cache "$sig_download_url" "$allow_http") || {
        # Try .asc fallback only if no explicit override was set
        if [[ -z "$sig_url_override" ]]; then
            local asc_url="${download_url}.asc"
            if networks::url_exists "$asc_url"; then
                used_fallback=1
                sigf=$(networks::download_text_to_cache "$asc_url" "$allow_http") || {
                    interfaces::print_ui_line "  " "✗ " "Signature download failed." "${COLOR_RED}"
                    verifiers::_emit_verify_hook "signature" 0 "$gpg_fingerprint" "<download-error>" "pgp" \
                        "$app_name" "$downloaded_file_path" "$download_url" "$gpg_key_id" "$gpg_fingerprint"
                    errors::handle_error "NETWORK_ERROR" "Failed to download signature file from '$sig_download_url' (and .asc fallback)." "$app_name"
                    return 1
                }
            else
                interfaces::print_ui_line "  " "✗ " "Signature download failed." "${COLOR_RED}"
                verifiers::_emit_verify_hook "signature" 0 "$gpg_fingerprint" "<download-error>" "pgp" \
                    "$app_name" "$downloaded_file_path" "$download_url" "$gpg_key_id" "$gpg_fingerprint"
                errors::handle_error "NETWORK_ERROR" "Failed to download signature file from '$sig_download_url'." "$app_name"
                return 1
            fi
        else
            interfaces::print_ui_line "  " "✗ " "Signature download failed." "${COLOR_RED}"
            verifiers::_emit_verify_hook "signature" 0 "$gpg_fingerprint" "<download-error>" "pgp" \
                "$app_name" "$downloaded_file_path" "$download_url" "$gpg_key_id" "$gpg_fingerprint"
            errors::handle_error "NETWORK_ERROR" "Failed to download signature file from '$sig_download_url'." "$app_name"
            return 1
        fi
    }

    # Ensure GPG helpers are loaded (idempotent lazy-load; fixes early-call ordering)
    if ! declare -F gpg::verify_detached >/dev/null 2>&1; then
        if [[ -z "${CORE_DIR:-}" ]]; then
            local _v_this_dir
            _v_this_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
            # verifiers.sh lives in src/lib → CORE_DIR is src/core
            CORE_DIR="$(cd -- "${_v_this_dir}/../core" && pwd)"
            unset _v_this_dir
        fi
        local _gpg_path="${CORE_DIR}/../lib/gpg.sh"
        if [[ -f "$_gpg_path" ]]; then
            # shellcheck source=/dev/null
            source "$_gpg_path"
        fi
        unset _gpg_path
    fi

    # Hard fail if the function is still missing
    if ! declare -F gpg::verify_detached >/dev/null 2>&1; then
        systems::unregister_temp_file "$sigf"
        interfaces::print_ui_line "  " "✗ " "Missing GPG helpers." "${COLOR_RED}"
        verifiers::_emit_verify_hook "signature" 0 "$gpg_fingerprint" "<no-helper>" "pgp" \
            "$app_name" "$downloaded_file_path" "$download_url" "$gpg_key_id" "$gpg_fingerprint"
        errors::handle_error "GPG_ERROR" "Missing gpg functions (gpg.sh not sourced)." "$app_name"
        return 1
    fi

    local which_url="$sig_download_url"
    [[ "$used_fallback" -eq 1 ]] && which_url="${download_url}.asc"

    loggers::log_message "DEBUG" "Performing GPG signature verification for '$app_name'. Key ID: '$gpg_key_id', Fingerprint: '$gpg_fingerprint'"
    if ! gpg::verify_detached "$downloaded_file_path" "$sigf" "$gpg_key_id" "$gpg_fingerprint" "user_keyring" ""; then
        systems::unregister_temp_file "$sigf"
        interfaces::print_ui_line "  " "✗ " "Signature verification FAILED." "${COLOR_RED}"
        verifiers::_emit_verify_hook "signature" 0 "$gpg_fingerprint" "<no-hash>" "pgp" \
            "$app_name" "$downloaded_file_path" "$download_url" "$gpg_key_id" "$gpg_fingerprint"
        errors::handle_error "GPG_ERROR" "GPG signature verification failed for '$app_name'." "$app_name"
        return 1
    fi

    systems::unregister_temp_file "$sigf"
    interfaces::print_ui_line "  " "✓ " "Signature verified." "${COLOR_GREEN}"
    verifiers::_emit_verify_hook "signature" 1 "$gpg_fingerprint" "<no-hash>" "pgp" \
        "$app_name" "$downloaded_file_path" "$which_url" "$gpg_key_id" "$gpg_fingerprint"
    return 0
}

# --------------------------------------------------------------------
# Public: main verification entry point
# Usage: verifiers::verify_artifact config_ref_name file_path download_url [direct_checksum]
# Returns 0 on success, 1 on failure
# --------------------------------------------------------------------
verifiers::verify_artifact() {
    local config_ref_name="$1"
    local downloaded_file_path="$2"
    local download_url="$3"
    local direct_checksum="${4:-}"

    local -n cfg="$config_ref_name"
    local app_name="${cfg[name]:-unknown}"
    local checksum_algorithm="${cfg[checksum_algorithm]:-sha256}"
    local skip_checksum="${cfg[skip_checksum]:-0}"

    loggers::log_message "DEBUG" "Verifying downloaded artifact for '$app_name': '$downloaded_file_path'"

    # 1) Checksum (optional)
    if [[ "$skip_checksum" -ne 1 ]]; then
        local expected
        expected=$(verifiers::resolve_expected_checksum "$config_ref_name" "$downloaded_file_path" "$download_url" "$direct_checksum") || {
            verifiers::_emit_verify_hook "checksum" 0 "<resolve-error>" "<no-hash>" "${checksum_algorithm,,}" \
                "$app_name" "$downloaded_file_path" "$download_url"
            return 1
        }
        if [[ -n "$expected" ]]; then
            if verifiers::verify_checksum "$downloaded_file_path" "$expected" "$checksum_algorithm"; then
                verifiers::_emit_verify_hook "checksum" 1 "$expected" "<matching>" "${checksum_algorithm,,}" \
                    "$app_name" "$downloaded_file_path" "$download_url"
            else
                verifiers::_emit_verify_hook "checksum" 0 "$expected" "<mismatch>" "${checksum_algorithm,,}" \
                    "$app_name" "$downloaded_file_path" "$download_url"
                errors::handle_error "VALIDATION_ERROR" "Checksum verification failed for '$app_name'." "$app_name"
                return 1
            fi
        fi
    fi

    # 2) Signature (optional)
    verifiers::verify_signature "$config_ref_name" "$downloaded_file_path" "$download_url" || return 1

    return 0
}

# --------------------------------------------------------------------
# Public: compare checksums of two files (utility for DEB flow)
# Usage: verifiers::compare_files_checksum file_a file_b [algorithm]
# Returns 0 if equal, 1 otherwise
# --------------------------------------------------------------------
verifiers::compare_files_checksum() {
    local file_a="$1"
    local file_b="$2"
    local algorithm="${3:-sha256}"
    local a
    a=$(verifiers::compute_checksum "$file_a" "$algorithm")
    local b
    b=$(verifiers::compute_checksum "$file_b" "$algorithm")
    [[ "$a" == "$b" ]]
}
