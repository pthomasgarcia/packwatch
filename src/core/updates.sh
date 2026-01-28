#!/usr/bin/env bash
# src/core/updates.sh
# ==============================================================================
# MODULE: updates.sh
# ==============================================================================
# Responsibilities:
#   - Orchestration of individual and overall update flow for various app types.
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/updates.sh"
#
#   Then use:
#     updates::check_application "AppKey" 1 5
#     updates::perform_all_checks "${apps_to_check[@]}"
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Module Sources
# ------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$CORE_DIR/updates/common.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/github.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/direct_download.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/appimage.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/flatpak.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/script.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/custom.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/updates/validation.sh"

# --- GLOBAL DECLARATIONS FOR EXTENSIBILITY ---
# These associative arrays and functions are defined globally for modularity
# and extensibility across the updates module and other sourced scripts.

# 1. Plugin Architecture for App Types
# Maps app 'type' to the function that handles its update check.
declare -A UPDATE_HANDLERS
UPDATE_HANDLERS["github_release"]="updates::check_github_release"
UPDATE_HANDLERS["direct_download"]="updates::check_direct_download"
UPDATE_HANDLERS["appimage"]="updates::check_appimage"
UPDATE_HANDLERS["script"]="updates::check_script"
# New type for script-based installations
UPDATE_HANDLERS["flatpak"]="updates::check_flatpak"
# Renamed for consistency as it also checks
UPDATE_HANDLERS["custom"]="updates::handle_custom_check"

# Configuration Validation Schema (as per user's existing schema files)

# Event Hooks
# Arrays to store function names to be called at specific events.
declare -a PRE_CHECK_HOOKS
declare -a POST_CHECK_HOOKS
declare -a PRE_INSTALL_HOOKS
declare -a POST_INSTALL_HOOKS
declare -a POST_VERIFY_HOOKS
declare -a ERROR_HOOKS

# --- GLOBAL HOOK SNAPSHOT ---
# Snapshot of the initial state of pre-install hooks, allowing app-specific
# checks to be added without losing the global baseline.
declare -a DEFAULT_PRE_INSTALL_HOOKS
DEFAULT_PRE_INSTALL_HOOKS=("${PRE_INSTALL_HOOKS[@]}")

updates::register_hook() {
    local hook_type="$1"
    local function_name="$2"
    case "$hook_type" in
        "pre_check") PRE_CHECK_HOOKS+=("$function_name") ;;
        "post_check") POST_CHECK_HOOKS+=("$function_name") ;;
        "pre_install") PRE_INSTALL_HOOKS+=("$function_name") ;;
        "post_install") POST_INSTALL_HOOKS+=("$function_name") ;;
        "error") ERROR_HOOKS+=("$function_name") ;;
        "post_verify") POST_VERIFY_HOOKS+=("$function_name") ;;
        *) loggers::warn "Unknown hook type: $hook_type" ;;
    esac
}

updates::trigger_hooks() {
    local hooks_array_name="$1" # Name of the array variable
    local app_name="$2"
    local details_json="${3:-}"
    # Optional JSON string with status/error/version details

    # Validate that the array name is provided
    if [[ -z "$hooks_array_name" ]]; then
        loggers::warn "No hooks array name provided to trigger_hooks"
        return 1
    fi

    # Check if the variable exists
    if ! (declare -p "$hooks_array_name" > /dev/null 2>&1); then
        loggers::warn "Hooks array '$hooks_array_name' does not exist"
        return 1
    fi

    # Bash-specific: use nameref to avoid eval and safely iterate hooks.
    # If POSIX sh compatibility is needed, this function requires a shim.
    if [[ $(declare -p "$hooks_array_name" 2> /dev/null) != declare*'-a '* ]]; then
        # Not a regular indexed array (could be empty, unset, or different type)
        return 0
    fi

    # shellcheck disable=SC2178 # Nameref assignment pattern
    declare -n hook_array_ref="$hooks_array_name"
    local hook_func
    for hook_func in "${hook_array_ref[@]}"; do
        if [[ -n "$hook_func" ]] && declare -F "$hook_func" > /dev/null; then
            if ! "$hook_func" "$app_name" "$details_json"; then
                loggers::warn "Hook function '$hook_func' failed for '$app_name'. Halting hook chain."
                return 1 # Propagate failure
            fi
        elif [[ -n "$hook_func" ]]; then
            loggers::warn "Hook '$hook_func' is not a callable function."
        fi
    done
}

# ------------------------------------------------------------------------------
# SECTION: Main Application Update Dispatcher (Individual App)
# ------------------------------------------------------------------------------

# Updates module; checks for updates for a single application defined in config.
updates::check_application() {
    # Reset hooks to the global default before adding app-specific ones
    PRE_INSTALL_HOOKS=("${DEFAULT_PRE_INSTALL_HOOKS[@]}")

    local app_key="$1"
    local current_index="$2"
    local total_apps="$3"

    if [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Empty app key provided"
        updates::trigger_hooks ERROR_HOOKS "unknown" \
            "{\"phase\": \"cli_parsing\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Empty app key provided.\"}"
        counters::inc_failed
        return 1
    fi

    declare -A _current_app_config
    if ! configs::get_app_config "$app_key" "_current_app_config"; then
        errors::handle_error "CONFIG_ERROR" "Failed to retrieve configuration for app: '$app_key'" "$app_key"
        updates::trigger_hooks ERROR_HOOKS "$app_key" \
            "{\"phase\": \"config_retrieval\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Failed to retrieve configuration.\"}"
        return 1
    fi

    local app_display_name="${_current_app_config[name]:-$app_key}"
    interfaces::display_header "$app_display_name" "$current_index" "$total_apps"

    # Conditionally register the pre-install hook for checking running processes.
    if [[ "${_current_app_config[prompt_to_kill_running_processes]:-false}" == "true" && -n "${_current_app_config[binary_name]:-}" ]]; then
        updates::register_hook "pre_install" "updates::pre_install_check_running_processes"
    fi

    # Validate the current application's configuration
    local app_type="${_current_app_config[type]:-}"
    if ! updates::_validate_app_config "$app_type" "_current_app_config"; then
        interfaces::print_ui_line "  " "✗ " "Config error: Missing required fields." "${COLOR_RED}"
        counters::inc_failed
        loggers::output "" # Blank line after each app block
        return 1
    fi

    if [[ -z "${_current_app_config[type]:-}" ]]; then
        errors::handle_error "CONFIG_ERROR" \
            "Application '$app_key' missing 'type' field." "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" \
            "{\"phase\": \"config_validation\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Application missing 'type' field.\"}"
        interfaces::print_ui_line "  " "✗ " "Config error: Missing app type." "${COLOR_RED}"
        counters::inc_failed
        loggers::output ""
        return 1
    fi

    local app_check_status=0
    local handler_func="${UPDATE_HANDLERS[$app_type]}"

    if [[ -n "$handler_func" ]]; then
        updates::trigger_hooks PRE_CHECK_HOOKS "$app_display_name"
        "$handler_func" "_current_app_config" || app_check_status=1
        updates::trigger_hooks POST_CHECK_HOOKS "$app_display_name"
    else
        errors::handle_error "CONFIG_ERROR" "Unknown update type '$app_type'" "$app_display_name"
        interfaces::print_ui_line "  " "✗ " "Config error: Unknown update type." "${COLOR_RED}"
        app_check_status=1
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" \
            "{\"error_type\": \"CONFIG_ERROR\", \"message\": \"Unknown app type: ${app_type}\"}"
    fi

    if [[ "$app_check_status" -ne 0 ]]; then
        counters::inc_failed
    fi
    loggers::output "" # Blank line after each app block
    return "$app_check_status"
}

# ------------------------------------------------------------------------------
# SECTION: Overall Update Orchestration
# ------------------------------------------------------------------------------

# Orchestrates the update checks for a list of applications.
# Usage: updates::perform_all_checks "${apps_to_check_array[@]}"
updates::perform_all_checks() {
    local -a apps_to_check=("$@")
    local total_apps=${#apps_to_check[@]}
    local current_index=1

    for app_key in "${apps_to_check[@]}"; do
        updates::check_application "$app_key" "$current_index" "$total_apps" ||
            true
        ((current_index++))
    done
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
