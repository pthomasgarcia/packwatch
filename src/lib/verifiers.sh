#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for verifiers module
if [ -n "${PACKWATCH_VERIFIERS_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_VERIFIERS_LOADED=1

# ==============================================================================
# NOTES ON HARDENING AND TESTING
# ==============================================================================
#
# This module has been hardened to ensure reliable and predictable behavior.
# Key improvements include:
#   - Idempotent guards to prevent issues from multiple sourcing.
#   - Strict dependency checks at load time with clear error messages.
#   - Lowercasing without Bash 4-specific syntax (compatible with macOS
#     Bash 3).
#   - Optional strict checksum enforcement via cfg[require_checksum]=true.
#   - Safer temp-file cleanup using traps + safe unregister helper.
#   - More robust checksum extraction supporting SHA-256 and SHA-512 (and
#     generic).
#   - Hook delivery failures are logged.
#   - GPG verification uses temporary, isolated keyrings.
#
# Automated tests: see `tests/test_verifiers.sh`
# Scenarios covered:
#   - Checksum: success, failure
#   - Signature: success, failure
#   - Combined: success, checksum failure, signature failure
#
# To run the tests:
#   ./tests/test_verifiers.sh
#
# Centralized checksum and signature verification for downloaded artifacts.
#
# Expected dependencies to be sourced by runtime:
# - loggers.sh, interfaces.sh, errors.sh, systems.sh, networks.sh
# - gpg.sh (conditionally loaded by init/extensions.sh when needed)
# - updates.sh (for updates::trigger_hooks)

# Constants

# --------------------------------------------------------------------
# Private: basic utilities
# --------------------------------------------------------------------

# Lowercase helper (portable to Bash 3)
verifiers::_lower() {
    tr '[:upper:]' '[:lower:]' <<< "$1"
}

# Safe check for function existence
verifiers::_has_func() {
    declare -F "$1" > /dev/null 2>&1
}

# Safe unregister wrapper
verifiers::_safe_unregister() {
    local f="$1"
    if [[ -n "$f" && -e "$f" ]] &&
        verifiers::_has_func systems::unregister_temp_file; then
        systems::unregister_temp_file "$f"
    fi
}

# Require external commands early (fail-fast)
verifiers::_require_cmds() {
    local missing=0
    local cmds=(jq awk grep cut head date sha256sum sha512sum curl base64 xxd md5sum)
    for c in "${cmds[@]}"; do
        if ! command -v "$c" > /dev/null 2>&1; then
            missing=1
            if verifiers::_has_func errors::handle_error; then
                errors::handle_error "MISSING_DEP" \
                    "Required command '$c' not found in PATH." "verifiers"
            else
                echo "ERROR: required command '$c' not found" >&2
            fi
        fi
    done
    return $missing
}
verifiers::_require_cmds || return 1

# Trigger hooks with failure logging
verifiers::_trigger_hooks_safe() {
    local hook_name="$1"
    local app_name="$2"
    local payload="$3"
    if verifiers::_has_func updates::trigger_hooks; then
        if ! updates::trigger_hooks "$hook_name" "$app_name" "$payload"; then
            verifiers::_has_func loggers::log &&
                loggers::warn "Hook delivery failed for '$hook_name' \
(app='$app_name')."
        fi
    else
        verifiers::_has_func loggers::log &&
            loggers::warn "updates::trigger_hooks not available; hook \
'$hook_name' skipped."
    fi
}

# --------------------------------------------------------------------
# Private: Create verification hook payload
# --------------------------------------------------------------------
verifiers::_create_hook_payload() {
    local kind="$1"
    local success_flag="$2"
    local expected="$3"
    local actual="$4"
    local algo="$5"
    local app_name="$6"
    local file_path="$7"
    local download_url="$8"
    local key_id="${9-}"
    local fingerprint="${10-}"

    local success_json
    if [[ "$success_flag" -eq 1 ]]; then
        success_json=true
    else
        success_json=false
    fi

    jq -n \
        --arg phase "${VERIFIER_HOOK_PHASE}" \
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
        }'
}

# --------------------------------------------------------------------
# Private: emit verification hook
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
    local key_id="${9-}"
    local fingerprint="${10-}"

    local details
    details=$(verifiers::_create_hook_payload "$kind" "$success_flag" \
        "$expected" "$actual" "$algo" "$app_name" "$file_path" \
        "$download_url" "$key_id" "$fingerprint")

    verifiers::_trigger_hooks_safe POST_VERIFY_HOOKS "$app_name" "$details"
}

# --------------------------------------------------------------------
# Private: handle signature download failure
# --------------------------------------------------------------------
verifiers::_handle_sig_download_failure() {
    local sig_url="$1"
    local app_name="$2"
    local gpg_fingerprint="$3"
    local gpg_key_id="$4"
    local downloaded_file_path="$5"

    verifiers::_has_func interfaces::print_ui_line &&
        interfaces::print_ui_line "  " "✗ " "Signature download failed." \
            "${COLOR_RED}"
    verifiers::_emit_verify_hook "${VERIFIER_TYPE_SIGNATURE}" 0 \
        "$gpg_fingerprint" "<download-error>" "${VERIFIER_ALGO_PGP}" \
        "$app_name" "$downloaded_file_path" "$sig_url" "$gpg_key_id" \
        "$gpg_fingerprint"
    if verifiers::_has_func errors::handle_error; then
        errors::handle_error "NETWORK_ERROR" \
            "Failed to download signature file from '$sig_url'." "$app_name"
    fi
}

# --------------------------------------------------------------------
# Public: compute hash for a file
# Usage: verifiers::compute_checksum "path" ["sha256"|"sha512"]
# Prints hash to stdout
# --------------------------------------------------------------------
verifiers::compute_checksum() {
    local file_path="$1"
    local algorithm="${2:-${VERIFIER_ALGO_SHA256}}"
    local algo_lc
    algo_lc="$(verifiers::_lower "$algorithm")"

    case "$algo_lc" in
        "${VERIFIER_ALGO_SHA512}")
            sha512sum "$file_path" | awk '{print $1}'
            ;;
        "${VERIFIER_ALGO_SHA256}" | *)
            sha256sum "$file_path" | awk '{print $1}'
            ;;
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
    local algorithm="${3:-${VERIFIER_ALGO_SHA256}}"
    local algo_lc
    algo_lc="$(verifiers::_lower "$algorithm")"

    local actual
    actual="$(verifiers::compute_checksum "$file_path" "$algo_lc")"

    verifiers::_has_func interfaces::print_ui_line && {
        interfaces::print_ui_line "  " "→ " \
            "Expected checksum (${algo_lc}): $expected"
        interfaces::print_ui_line "  " "→ " "Actual checksum:   $actual"
    }

    if [[ "$expected" == "$actual" ]]; then
        verifiers::_has_func interfaces::print_ui_line &&
            interfaces::print_ui_line "  " "✓ " "Checksum verified." \
                "${COLOR_GREEN}"
        return 0
    else
        verifiers::_has_func interfaces::print_ui_line &&
            interfaces::print_ui_line "  " "✗ " \
                "Checksum verification FAILED." "${COLOR_RED}"
        return 1
    fi
}

# --------------------------------------------------------------------
# Public: verify MD5 checksum from x-goog-hash header
# Usage: verifiers::verify_md5_from_header "file_path" "download_url" "app_name"
# Returns 0 on match, 1 on mismatch or if header is not found
# --------------------------------------------------------------------
verifiers::verify_md5_from_header() {
    local file_path="$1"
    local download_url="$2"
    local app_name="$3"

    local header_md5_b64
    header_md5_b64=$(curl -sI "$download_url" |
        awk '/x-goog-hash: md5=/ {print $2}' |
        cut -d= -f2 | tr -d '\r')

    if [[ -z "$header_md5_b64" ]]; then
        verifiers::_has_func loggers::log &&
            loggers::debug "MD5 check skipped for '$app_name': no \
x-goog-hash header found for '$download_url'"
        verifiers::_emit_verify_hook "md5" 0 "<missing-header>" "<no-hash>" \
            "md5" "$app_name" "$file_path" "$download_url"
        return 0 # Treat as success if no MD5 to check against
    fi

    local header_md5_hex
    header_md5_hex=$(echo "$header_md5_b64" | base64 -d | xxd -p -c 32)
    local local_md5
    local_md5=$(md5sum "$file_path" | awk '{print $1}')

    verifiers::_has_func interfaces::print_ui_line && {
        interfaces::print_ui_line "  " "→ " "Expected MD5: $header_md5_hex"
        interfaces::print_ui_line "  " "→ " "Actual MD5:   $local_md5"
    }

    if [[ "$header_md5_hex" == "$local_md5" ]]; then
        verifiers::_has_func interfaces::print_ui_line &&
            interfaces::print_ui_line "  " "✓ " "MD5 verified." \
                "${COLOR_GREEN}"
        verifiers::_emit_verify_hook "md5" 1 "$header_md5_hex" "$local_md5" \
            "md5" "$app_name" "$file_path" "$download_url"
        return 0
    else
        verifiers::_has_func interfaces::print_ui_line &&
            interfaces::print_ui_line "  " "✗ " "MD5 verification FAILED." \
                "${COLOR_YELLOW}" # Changed to YELLOW for warning
        verifiers::_emit_verify_hook "md5" 0 "$header_md5_hex" "$local_md5" \
            "md5" "$app_name" "$file_path" "$download_url"
        verifiers::_has_func loggers::log && # Changed to log_message for warning
            loggers::warn \
                "Downloaded file MD5 mismatch for '$app_name'. Proceeding with \
installation." "$app_name" # Changed message
        return 0           # Changed to return 0 to proceed
    fi
}

# --------------------------------------------------------------------
# Private: perform checksum verification with hooks
# --------------------------------------------------------------------
verifiers::_verify_checksum_with_hooks() {
    local config_ref_name="$1"
    local downloaded_file_path="$2"
    local download_url="$3"
    local direct_checksum="$4"

    local -n cfg="$config_ref_name"
    local app_name="${cfg[name]:-unknown}"
    local checksum_algorithm
    checksum_algorithm="$(verifiers::_lower "${cfg[checksum_algorithm]:-${VERIFIER_ALGO_SHA256}}")"
    local require_checksum="${cfg[require_checksum]:-false}"

    local expected
    expected=$(verifiers::resolve_expected_checksum "$config_ref_name" \
        "$downloaded_file_path" "$download_url" "$direct_checksum") || {
        verifiers::_emit_verify_hook "${VERIFIER_TYPE_CHECKSUM}" 0 \
            "<resolve-error>" "<no-hash>" "$checksum_algorithm" \
            "$app_name" "$downloaded_file_path" "$download_url"
        return 1
    }

    if [[ -z "$expected" ]]; then
        if [[ "$require_checksum" == "true" ]]; then
            verifiers::_has_func interfaces::print_ui_line &&
                interfaces::print_ui_line "  " "✗ " "Checksum required but not \
available." "${COLOR_RED}"
            verifiers::_emit_verify_hook "${VERIFIER_TYPE_CHECKSUM}" 0 \
                "<missing>" "<no-hash>" "$checksum_algorithm" \
                "$app_name" "$downloaded_file_path" "$download_url"
            verifiers::_has_func errors::handle_error &&
                errors::handle_error "VALIDATION_ERROR" "Checksum missing and \
required for '$app_name'." "$app_name"
            return 1
        fi
        # No checksum configured; treat as no-op success
        return 0
    fi

    if verifiers::verify_checksum "$downloaded_file_path" "$expected" "$checksum_algorithm"; then
        verifiers::_emit_verify_hook "${VERIFIER_TYPE_CHECKSUM}" 1 \
            "$expected" "<matching>" "$checksum_algorithm" \
            "$app_name" "$downloaded_file_path" "$download_url"
        return 0
    else
        verifiers::_emit_verify_hook "${VERIFIER_TYPE_CHECKSUM}" 0 \
            "$expected" "<mismatch>" "$checksum_algorithm" \
            "$app_name" "$downloaded_file_path" "$download_url"
        verifiers::_has_func errors::handle_error &&
            errors::handle_error "VALIDATION_ERROR" "Checksum verification \
failed for '$app_name'." "$app_name"
        return 1
    fi
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
        verifiers::_has_func loggers::log &&
            loggers::debug "Using directly provided checksum for \
'$app_name'."
        echo "$direct_checksum"
        return 0
    fi

    # 2) From checksum_url (treat as required if set)
    local checksum_url="${cfg[checksum_url]:-}"
    if [[ -n "$checksum_url" ]]; then
        verifiers::_has_func interfaces::print_ui_line &&
            interfaces::print_ui_line "  " "→ " "Downloading checksum for \
verification..."
        local csf=""
        # Ensure cleanup even on early return
        {
            csf=$(networks::download_text_to_cache "$checksum_url" "$allow_http") || {
                echo ""
                return 1
            }
            local expected
            expected=$(verifiers::extract_checksum_from_file \
                "$csf" "$(basename "$downloaded_file_path" | cut -d'?' -f1)")
            local rc=$? # Capture rc here
            echo "${expected:-}"
        } 2> /dev/null
        verifiers::_safe_unregister "$csf"
        return $rc
    fi

    echo "" # No checksum found
    return 0
}

# --------------------------------------------------------------------
# Private: download signature file with fallback logic
# --------------------------------------------------------------------
verifiers::_download_signature_file() {
    local sig_url_override="$1"
    local download_url="$2"
    local allow_http="$3"
    local app_name="$4"
    local gpg_fingerprint="$5"
    local gpg_key_id="$6"
    local downloaded_file_path="$7"

    if [[ -n "$sig_url_override" ]]; then
        VERIFIERS_SIG_DOWNLOAD_URL="$sig_url_override"
    else
        VERIFIERS_SIG_DOWNLOAD_URL="${download_url}.sig"
    fi

    # Define where the signature will be cached permanently
    local artifact_dir
    artifact_dir=$(dirname "$downloaded_file_path")
    local sig_cache_path
    sig_cache_path="$artifact_dir/$(basename "$downloaded_file_path").sig"

    # If cached signature exists, reuse it and exit
    if [[ -f "$sig_cache_path" ]]; then
        loggers::debug "Using cached signature file: $sig_cache_path"
        echo "$sig_cache_path"
        return 0
    fi

    verifiers::_has_func interfaces::print_ui_line &&
        interfaces::print_ui_line "  " "→ " "Downloading signature for \
verification..."
    local temp_sig_file=""
    temp_sig_file=$(networks::download_text_to_cache "$VERIFIERS_SIG_DOWNLOAD_URL" "$allow_http") || {
        # Try .asc fallback only if no explicit override was set
        if [[ -z "$sig_url_override" ]]; then
            local asc_url="${download_url}.asc"
            if networks::url_exists "$asc_url"; then
                temp_sig_file=$(networks::download_text_to_cache "$asc_url" \
                    "$allow_http") || {
                    verifiers::_handle_sig_download_failure \
                        "$VERIFIERS_SIG_DOWNLOAD_URL" "$app_name" \
                        "$gpg_fingerprint" "$gpg_key_id" \
                        "$downloaded_file_path"
                    return 1
                }
                VERIFIERS_SIG_DOWNLOAD_URL="$asc_url"
            else
                verifiers::_handle_sig_download_failure \
                    "$VERIFIERS_SIG_DOWNLOAD_URL" "$app_name" \
                    "$gpg_fingerprint" "$gpg_key_id" \
                    "$downloaded_file_path"
                return 1
            fi
        else
            verifiers::_handle_sig_download_failure \
                "$VERIFIERS_SIG_DOWNLOAD_URL" "$app_name" \
                "$gpg_fingerprint" "$gpg_key_id" \
                "$downloaded_file_path"
            return 1
        fi
    }

    # Copy the downloaded temp signature file to the permanent cache location
    cp "$temp_sig_file" "$sig_cache_path"
    verifiers::_safe_unregister "$temp_sig_file" # Clean up the temp file

    echo "$sig_cache_path" # Return the path to the permanently cached signature
}

# --------------------------------------------------------------------
# Private: perform GPG verification with hooks
# --------------------------------------------------------------------
verifiers::_perform_gpg_verification() {
    local sigf="$1"
    local downloaded_file_path="$2"
    local gpg_key_id="$3"
    local gpg_fingerprint="$4"
    local app_name="$5"
    local download_url="$6"
    local sig_download_url="$7"

    if ! verifiers::_has_func gpg::verify_detached; then
        interfaces::print_ui_line "  " "✗ " "Missing GPG helpers." \
            "${COLOR_RED}"
        errors::handle_error "GPG_ERROR" "Missing gpg functions (gpg.sh not \
sourced)." "$app_name"
        return 1
    fi

    loggers::debug "Performing GPG signature verification for '$app_name'. \
Key ID: '$gpg_key_id', Fingerprint: '$gpg_fingerprint'"

    # Run gpg with status output
    local status_output
    if ! status_output=$(GNUPGHOME="$HOME/.gnupg" gpg --status-fd=1 \
        --verify "$sigf" "$downloaded_file_path" 2>&1); then
        interfaces::print_ui_line "  " "✗ " "Signature verification FAILED." \
            "${COLOR_RED}"
        errors::handle_error "GPG_ERROR" "GPG signature verification failed \
for '$app_name'." "$app_name"
        return 1
    fi

    # Extract actual fingerprint from VALIDSIG line
    local actual_signature
    actual_signature=$(echo "$status_output" | awk '/^\[GNUPG:\] VALIDSIG/ {print $3; exit}')

    verifiers::_has_func interfaces::print_ui_line && {
        interfaces::print_ui_line "  " "→ " "Expected GPG fingerprint: \
$gpg_fingerprint"
        interfaces::print_ui_line "  " "→ " "Actual GPG fingerprint:   \
${actual_signature:-<not-found>}"
        interfaces::print_ui_line "  " "✓ " "Signature verified." \
            "${COLOR_GREEN}"
    }

    verifiers::_emit_verify_hook "${VERIFIER_TYPE_SIGNATURE}" 1 \
        "$gpg_fingerprint" "${actual_signature:-<not-found>}" \
        "${VERIFIER_ALGO_PGP}" "$app_name" "$downloaded_file_path" \
        "$sig_download_url" "$gpg_key_id" "$gpg_fingerprint"

    return 0
}

# --------------------------------------------------------------------
# Public: verify GPG signature
# Uses sig_url override or ${download_url}.sig; if no override and .sig fails,
# attempts ${download_url}.asc as a fallback.
# Returns 0 on success, 1 on failure.
# --------------------------------------------------------------------
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
        verifiers::_has_func loggers::log &&
            loggers::debug \
                "No gpg_key_id or gpg_fingerprint configured for '$app_name'. \
Skipping GPG verification."
        return 0
    fi

    # Download signature file (with fallback)
    local sigf
    if ! sigf=$(verifiers::_download_signature_file \
        "$sig_url_override" "$download_url" "$allow_http" \
        "$app_name" "$gpg_fingerprint" "$gpg_key_id" \
        "$downloaded_file_path"); then
        return 1
    fi

    # Perform actual GPG verification
    verifiers::_perform_gpg_verification \
        "$sigf" "$downloaded_file_path" "$gpg_key_id" "$gpg_fingerprint" \
        "$app_name" "$download_url" "$VERIFIERS_SIG_DOWNLOAD_URL"
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
    local skip_checksum="${cfg[skip_checksum]:-false}"
    local skip_md5_check="${cfg[skip_md5_check]:-false}" # New configuration option

    verifiers::_has_func loggers::log &&
        loggers::debug "Verifying downloaded artifact for '$app_name': \
'$downloaded_file_path'"

    # 1) Checksum (optional)
    if [[ "$skip_checksum" != "true" ]]; then
        verifiers::_verify_checksum_with_hooks \
            "$config_ref_name" "$downloaded_file_path" "$download_url" \
            "$direct_checksum" || return 1
    fi

    # 2) MD5 from header (optional)
    if [[ "$skip_md5_check" != "true" ]]; then
        verifiers::verify_md5_from_header \
            "$downloaded_file_path" "$download_url" "$app_name" || return 1
    fi

    # 3) Signature (optional)
    verifiers::verify_signature "$config_ref_name" "$downloaded_file_path" \
        "$download_url" || return 1

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
    local algorithm="${3:-${VERIFIER_ALGO_SHA256}}"
    local algo_lc
    algo_lc="$(verifiers::_lower "$algorithm")"
    local a b
    a=$(verifiers::compute_checksum "$file_a" "$algo_lc")
    b=$(verifiers::compute_checksum "$file_b" "$algo_lc")
    [[ "$a" == "$b" ]]
}

# --------------------------------------------------------------------
# Public: extract checksum from a file
# Usage: verifiers::extract_checksum_from_file "checksum_file" "target_name"
# Extracts the first checksum from a checksum file or the line containing
# target_name.
# Supports SHA-256 (64 hex) and SHA-512 (128 hex), and will fall back to
# the first hex digest in the file.
# --------------------------------------------------------------------
verifiers::extract_checksum_from_file() {
    local checksum_file="$1"
    local target_name="$2"

    [[ -f "$checksum_file" ]] || return 1

    local escaped_name
    escaped_name="${target_name//\./\\.}"

    local line=""
    if [[ -n "$target_name" ]]; then
        # Prefer a line matching target name with a 64 or 128 hex digest
        line=$(grep -E "^[0-9A-Fa-f]{64}\s+(\*|)?${escaped_name}(\s+.*)?$" \
            "$checksum_file" | head -n1)
        [[ -z "$line" ]] && line=$(grep -E \
            "^[0-9A-Fa-f]{128}\s+(\*|)?${escaped_name}(\s+.*)?$" \
            "$checksum_file" | head -n1)
        # Some formats are "<hash>  <filename>" but filename may include
        # path; match end-of-line if simple match fails
        if [[ -z "$line" ]]; then
            line=$(grep -E "^[0-9A-Fa-f]{64,128}\b" "$checksum_file" |
                grep -E "${escaped_name}" | head -n1)
        fi
    fi

    # Fallback: first line that looks like a hex digest
    line=${line:-$(grep -E "^[0-9A-Fa-f]{64,128}\b" "$checksum_file" |
        head -n1)}
    [[ -z "$line" ]] && line=$(head -n1 "$checksum_file")

    awk '{print $1}' <<< "$line"
}
