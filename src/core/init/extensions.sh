#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for extensions module
if [ -n "${PACKWATCH_EXTENSIONS_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_EXTENSIONS_LOADED=1

# Packwatch Phase 4: Extensions
# Purpose: Load optional modules or specialized custom checker scripts
# only if they are
# required by the currently configured and enabled applications. This
# optimizes
# startup by avoiding loading unneeded code.

# Required: All modules from Phase 0-3b (bootloader, interface, scaffolding, runtime, business).
# This phase relies on configs.sh having populated CUSTOM_APP_KEYS and ALL_APP_CONFIGS.

# --- Logic to determine which optional modules/checkers are needed ---
# We will iterate through all *enabled* application configurations to
# check for
# dependencies on GPG (e.g., if gpg_key_id is set) or custom checker scripts.

# Loop through all app keys that were loaded and enabled by configs.sh
# CUSTOM_APP_KEYS is populated by configs::populate_globals_from_json
for _packwatch_app_key in "${CUSTOM_APP_KEYS[@]}"; do
    # Retrieve the full config for this app. configs::get_app_config populates
    # a temporary associative array (_packwatch_cfg) by nameref.
    declare -A _packwatch_cfg=()
    if ! configs::get_app_config "$_packwatch_app_key" "_packwatch_cfg"; then
        loggers::warn "Failed to retrieve config for app '$_packwatch_app_key' \
during optional module check."
        continue # Skip this app, it's already an error.
    fi

    # 1. Check for GPG dependency
    if [[ -n "${_packwatch_cfg[gpg_key_id]:-}" || -n "${_packwatch_cfg[gpg_fingerprint]:-}" ]]; then
        _PACKWATCH_NEED_GPG=1
    fi

    # 2. Check for Custom Checker script dependency
    if [[ "${_packwatch_cfg[type]:-}" == "custom" && -n "${_packwatch_cfg[custom_checker_script]:-}" ]]; then
        _PACKWATCH_NEEDED_CUSTOM_CHECKERS+=("${_packwatch_cfg[custom_checker_script]}")
    fi
done

# --- Sourcing the identified optional modules ---

# Load GPG if any configured app requires it
if [[ $_PACKWATCH_NEED_GPG -eq 1 ]]; then
    # Derive CORE_DIR if not already set.
    # extensions.sh lives at: .../src/core/init/extensions.sh
    # => one level up from this file is .../src/core
    if [[ -z "${CORE_DIR:-}" ]]; then
        _packwatch_this_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        CORE_DIR="$(cd -- "${_packwatch_this_dir}/.." && pwd)"
    fi

    # Single authoritative location for gpg.sh relative to CORE_DIR
    _packwatch_gpg_path="${CORE_DIR}/../lib/gpg.sh"
    if [[ -f "$_packwatch_gpg_path" ]]; then
        # shellcheck source=/dev/null
        source "$_packwatch_gpg_path"
    else
        loggers::error \
            "gpg.sh not found at expected path: ${_packwatch_gpg_path} \
(CORE_DIR=${CORE_DIR})" \
            "extensions"
    fi

    unset _packwatch_this_dir _packwatch_gpg_path
fi

# Load only the specific custom checker modules that are needed
for _packwatch_checker_script in "${_PACKWATCH_NEEDED_CUSTOM_CHECKERS[@]}"; do
    # Basic path sanitization before sourcing a dynamic script
    # This helps prevent simple path traversal attempts.
    case "$_packwatch_checker_script" in
    */* | *..* | "~"*) # Disallow path separators, parent dirs, and home tilde
        loggers::error \
            "Attempted to source unsafe custom checker path: \
'$_packwatch_checker_script'. Skipping." \
            "extensions"
        continue
        ;;
    esac

    _packwatch_checker_path="$CORE_DIR/custom_checkers/$_packwatch_checker_script"

    if [[ -f "$_packwatch_checker_path" ]]; then
        loggers::debug "Sourcing custom checker: '$_packwatch_checker_path'"
        # shellcheck source=/dev/null # This is a dynamic source, can't be checked statically
        source "$_packwatch_checker_path"
    else
        loggers::error \
            "Custom checker script not found: '$_packwatch_checker_path' for a \
configured app. Check configuration." \
            "extensions"
        # Note: We don't exit here; let the updates::handle_custom_check
        # function fail
        # when it can't find the associated function, allowing other apps to
        # proceed.
    fi
done

# --- Cleanup local variables to avoid leaking into global namespace ---
# Variables prefixed with _packwatch_ to reduce risk of collision
unset _packwatch_app_key _packwatch_cfg _packwatch_checker_script _packwatch_checker_path

# ==============================================================================
# END OF MODULE
# ==============================================================================
