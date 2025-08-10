#!/usr/bin/env bash
# ==============================================================================
# MODULE: updates.sh
# ==============================================================================
# Responsibilities:
#   - Update logic for each app type
#   - Orchestration of individual and overall update flow
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/updates.sh"
#
#   Then use:
#     updates::check_application "AppKey" 1 5
#     updates::perform_all_checks "${apps_to_check[@]}"
#
# Dependencies:
#   - util/checker_utils.sh
#   - configs.sh
#   - counters.sh
#   - errors.sh
#   - globals.sh
#   - gpg.sh # Ensure gpg.sh is sourced for _get_gpg_fingerprint_as_user
#   - interfaces.sh
#   - loggers.sh
#   - networks.sh
#   - notifiers.sh
#   - packages.sh
#   - repositories.sh
#   - systems.sh
#   - validators.sh
#   - versions.sh
# ==============================================================================

# --- GLOBAL DECLARATIONS FOR EXTENSIBILITY ---
# These associative arrays and functions are defined globally for modularity
# and extensibility across the updates module and potentially other sourced scripts.

# 1. Plugin Architecture for App Types
# Maps app 'type' to the function that handles its update check.
declare -A UPDATE_HANDLERS
UPDATE_HANDLERS["github_deb"]="updates::check_github_deb"
UPDATE_HANDLERS["direct_deb"]="updates::check_direct_deb"
UPDATE_HANDLERS["appimage"]="updates::check_appimage"
UPDATE_HANDLERS["script"]="updates::check_script"   # New type for script-based installations
UPDATE_HANDLERS["flatpak"]="updates::check_flatpak" # Renamed for consistency as it also checks
UPDATE_HANDLERS["custom"]="updates::handle_custom_check"

# 4. Configuration Validation Schema (as per user's existing schema files)
# Defines required fields for each app type.
declare -A APP_TYPE_VALIDATIONS
APP_TYPE_VALIDATIONS["github_deb"]="name,package_name,repo_owner,repo_name,filename_pattern_template"
APP_TYPE_VALIDATIONS["direct_deb"]="name,package_name,download_url"
APP_TYPE_VALIDATIONS["appimage"]="name,install_path,download_url"
APP_TYPE_VALIDATIONS["script"]="name,download_url,version_url,version_regex" # New type for script-based installations
APP_TYPE_VALIDATIONS["flatpak"]="name,flatpak_app_id"
APP_TYPE_VALIDATIONS["custom"]="name,custom_checker_script,custom_checker_func"

# ------------------------------------------------------------------------------
# SECTION: Generic Installation Flow
# ------------------------------------------------------------------------------

# Generic function to handle the common installation flow elements.
# This includes prompting the user, handling dry runs, and updating the installed version.
# Usage: updates::process_installation "app_name" "app_key" "latest_version" "install_command_func" "install_command_args..."
#   app_name           - Display name of the application.
#   app_key            - Unique key of the application.
#   latest_version     - The version to be installed.
#   install_command_func - Name of the function to call for the actual installation.
#   install_command_args - Arguments to pass to the install_command_func.
updates::process_installation() {
    local app_name="$1"
    local app_key="$2"
    local latest_version="$3"
    local install_command_func="$4"
    shift 4
    local -a install_command_args=("$@")

    local current_installed_version
    current_installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    local prompt_msg
    prompt_msg="Do you want to install ${FORMAT_BOLD}${app_name}${FORMAT_RESET} v${latest_version}?"
    if [[ "$current_installed_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update ${FORMAT_BOLD}${app_name}${FORMAT_RESET} to v${latest_version}?"
    fi

    notifiers::send_notification "$app_name Update Available" "v$latest_version ready for install" "normal"

    updates::trigger_hooks PRE_INSTALL_HOOKS "$app_name" # Pre-install hook

    if "$UPDATES_PROMPT_CONFIRM_IMPL" "$prompt_msg" "Y"; then # DI applied
        updates::on_install_start "$app_name"                 # Hook
        if [[ $DRY_RUN -eq 1 ]]; then
            loggers::log_message "DEBUG" "  [DRY RUN] Would execute installation command: '$install_command_func ${install_command_args[*]}'."
            if ! "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"; then # DI applied
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name' in dry run."
            fi
            interfaces::print_ui_line "  " "[DRY RUN] " "Installation simulated for ${FORMAT_BOLD}$app_name${FORMAT_RESET}." "${COLOR_YELLOW}"
            return 0
        fi

        if "$install_command_func" "${install_command_args[@]}"; then
            if ! "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"; then # DI applied
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but installation was successful."
            fi
            updates::on_install_complete "$app_name" # Hook
            counters::inc_updated
            return 0
        else
            errors::handle_error "INSTALLATION_ERROR" "Installation failed for '$app_name'." "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Installation failed.\"}"
            return 1
        fi
    else
        updates::on_install_skipped "$app_name" # Hook
        counters::inc_skipped
        return 0
    fi
}

# ------------------------------------------------------------------------------
# SECTION: Version Fetching Helpers
# ------------------------------------------------------------------------------

# Fetch version from GitHub release
updates::_fetch_github_version() {
    local repo_owner="$1"
    local repo_name="$2"
    local app_name="$3"

    local api_response_file # This will now be a file path
    if ! api_response_file=$("$UPDATES_GET_LATEST_RELEASE_INFO_IMPL" "$repo_owner" "$repo_name"); then
        errors::handle_error "NETWORK_ERROR" "Failed to fetch GitHub releases for '$app_name'." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to fetch GitHub releases.\"}"
        return 1
    fi

    local latest_release_json_path # This will be the path to the JSON file
    if ! latest_release_json_path=$("$UPDATES_GET_JSON_VALUE_IMPL" "$api_response_file" '.[0]' "$app_name"); then
        errors::handle_error "PARSING_ERROR" "Failed to parse latest release information." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to parse latest release information.\"}"
        return 1
    fi

    local latest_version
    if ! latest_version=$(repositories::parse_version_from_release "$latest_release_json_path" "$app_name"); then
        errors::handle_error "PARSING_ERROR" "Failed to get version from latest release." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"check\", \"error_type\": \"PARSING_ERROR\", \"message\": \"Failed to get version from latest release.\"}"
        return 1
    fi

    echo "$latest_version"
    echo "$latest_release_json_path" # Return the path to the JSON file
    return 0
}

# Fetch version from direct URL with regex
updates::_fetch_version_from_url() {
    local version_url="$1"
    local version_regex="$2"
    local app_name="$3"

    local latest_version="0.0.0"
    local api_response_file # This will now be a file path
    if api_response_file=$(networks::fetch_cached_data "$version_url" "json") && [[ -f "$api_response_file" ]]; then
        local parsed_version
        if parsed_version=$(versions::extract_from_json "$api_response_file" ".tag_name" "$app_name"); then
            latest_version="$parsed_version"
        else
            # If JSON extraction fails, try regex from the file content
            local file_content
            file_content=$(cat "$api_response_file")
            if parsed_version=$(versions::extract_from_regex "$file_content" "$version_regex" "$app_name"); then
                latest_version="$parsed_version"
            else
                loggers::log_message "WARN" "Could not extract version from '$version_url' for '$app_name' using JSON or regex. Defaulting to 0.0.0."
            fi
        fi
    fi

    echo "$latest_version"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: URL Construction Helpers
# ------------------------------------------------------------------------------

# Build download URL from release JSON
updates::_build_download_url() {
    local release_json="$1"
    local filename_template="$2"
    local version="$3"
    local app_name="$4"

    local download_filename
    download_filename=$(printf "$filename_template" "$version")

    local download_url
    download_url=$(repositories::find_asset_url "$release_json" "$download_filename" "$app_name")
    if [[ $? -ne 0 || -z "$download_url" ]] || ! validators::check_url_format "$download_url"; then
        errors::handle_error "NETWORK_ERROR" "Download URL not found or invalid for '$download_filename'." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Download URL not found or invalid.\"}"
        return 1
    fi

    echo "$download_url"
    return 0
}

# Extract checksum from release JSON
updates::_extract_release_checksum() {
    local release_json="$1"
    local filename_template="$2"
    local version="$3"
    local app_name="$4"

    local download_filename
    download_filename=$(printf "%s" "$filename_template" "$version")

    local expected_checksum
    if ! expected_checksum=$(repositories::find_asset_checksum "$release_json" "$download_filename" "$app_name"); then
        interfaces::print_ui_line "  " "✗ " "Failed to get GitHub checksum." "${COLOR_RED}"
        echo ""
        return 0
    fi

    echo "$expected_checksum"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Script-based Update Flow
# ------------------------------------------------------------------------------

updates::process_script_installation() {
    local -n app_config_ref=$1 # Now accepts app_config_ref directly
    local latest_version="$2"
    local download_url="$3"

    local app_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}" # Get from config

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url" || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for script update flow (version, URL, or app_key missing)" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"script_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Invalid parameters for script update flow.\"}"
        return 1
    fi

    local temp_script_path
    local base_filename_for_tmp
    base_filename_for_tmp="$(basename "$download_url" | cut -d'?' -f1 | sed 's/\.sh$//')"
    base_filename_for_tmp=$(systems::sanitize_filename "$base_filename_for_tmp")
    if ! temp_script_path=$(mktemp "/tmp/${base_filename_for_tmp}.XXXXXX.sh"); then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file for script: '${base_filename_for_tmp}.XXXXXX.sh'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"script_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Failed to create temporary file.\"}"
        return 1
    fi
    TEMP_FILES+=("$temp_script_path")

    updates::on_download_start "$app_name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_script_path" "" "" "$allow_http"; then # DI applied, added allow_http
        errors::handle_error "NETWORK_ERROR" "Failed to download script" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download script.\"}"
        return 1
    fi
    updates::on_download_complete "$app_name" "$temp_script_path" # Hook

    # Perform verification after download
    if ! updates::verify_downloaded_artifact app_config_ref "$temp_script_path" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded script: '$app_name'." "$app_name"
        return 1
    fi

    if ! chmod +x "$temp_script_path"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to make script executable: '$temp_script_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to make script executable.\"}"
        return 1
    fi

    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "sudo" \
        "bash" \
        "$temp_script_path"
}

# Updates module; checks for updates for a script-based application.
updates::check_script() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local version_url="${app_config_ref[version_url]}"
    local version_regex="${app_config_ref[version_regex]}"
    local source="Script Download"

    # Configuration validation (same as before)
    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid download URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid download URL configured." "${COLOR_RED}"
        return 1
    fi
    if ! validators::check_url_format "$version_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid version URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid version URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid version URL configured." "${COLOR_RED}"
        return 1
    fi
    if [[ -z "$version_regex" ]]; then
        errors::handle_error "CONFIG_ERROR" "Missing version regex in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Missing version regex configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Missing version regex configured." "${COLOR_RED}"
        return 1
    fi

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    # Use the new helper function
    local latest_version
    latest_version=$(updates::_fetch_version_from_url "$version_url" "$version_regex" "$name")

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_script_installation \
            app_config_ref \
            "${latest_version}" \
            "${download_url}"
    else
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
    fi

    return 0
}

# 7. Progress Tracking Callbacks
# Helper function for formatting bytes for progress tracking
_format_bytes() {
    local bytes="$1"
    if ((bytes < 1024)); then
        echo "${bytes} B"
    elif ((bytes < 1024 * 1024)); then
        # Convert to KB with 1 decimal place using pure bash
        local kb_int=$((bytes / 1024))
        local kb_frac=$(((bytes * 10 / 1024) % 10))
        printf "%d.%d KB" "$kb_int" "$kb_frac"
    elif ((bytes < 1024 * 1024 * 1024)); then
        # Convert to MB with 1 decimal place using pure bash
        local mb_int=$((bytes / (1024 * 1024)))
        local mb_frac=$(((bytes * 10 / (1024 * 1024)) % 10))
        printf "%d.%d MB" "$mb_int" "$mb_frac"
    else
        # Convert to GB with 1 decimal place using pure bash
        local gb_int=$((bytes / (1024 * 1024 * 1024)))
        local gb_frac=$(((bytes * 10 / (1024 * 1024 * 1024)) % 10))
        printf "%d.%d GB" "$gb_int" "$gb_frac"
    fi
}

# Placeholder functions for download/install progress.
updates::on_download_start() {
    local app_name="$1"
    local file_size="$2"                                                                         # Can be 'unknown' or actual size
    interfaces::print_ui_line "  " "→ " "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}..." >&2 # Redirect to stderr
    loggers::log_message "INFO" "Starting download for $app_name (Size: $file_size)."
}

updates::on_download_progress() {
    local app_name="$1"
    local downloaded="$2"
    local total="$3"
    local percent=$(((downloaded * 100) / total))
    interfaces::print_ui_line "  " "⤓ " "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}: $percent% ($(_format_bytes "$downloaded") / $(_format_bytes "$total"))" >&2 # Redirect to stderr
    # Note: Requires underlying networks::download_file to call this callback.
}

updates::on_download_complete() {
    local app_name="$1"
    local file_path="$2"
    interfaces::print_ui_line "  " "✓ " "Download for ${FORMAT_BOLD}$app_name${FORMAT_RESET} complete." "${COLOR_GREEN}" >&2 # Redirect to stderr
    loggers::log_message "INFO" "Download complete for $app_name: $file_path"
}

updates::on_install_start() {
    local app_name="$1"
    interfaces::print_ui_line "  " "→ " "Preparing to install ${FORMAT_BOLD}$app_name${FORMAT_RESET}..." >&2 # Redirect to stderr
    loggers::log_message "INFO" "Starting installation for $app_name."
}

updates::on_install_complete() {
    local app_name="$1"
    interfaces::print_ui_line "  " "✓ " "${FORMAT_BOLD}$app_name${FORMAT_RESET} installed/updated successfully." "${COLOR_GREEN}" >&2 # Redirect to stderr
    loggers::log_message "INFO" "Installation complete for $app_name."
    notifiers::send_notification "${app_name} Updated" "Successfully installed." "normal"
}

updates::on_install_skipped() {
    local app_name="$1"
    interfaces::print_ui_line "  " "🞨 " "Installation for ${FORMAT_BOLD}$app_name${FORMAT_RESET} skipped." "${COLOR_YELLOW}" >&2 # Redirect to stderr
    loggers::log_message "INFO" "Installation skipped for $app_name."
}

# 9. Dependency Injection for Testing
# These variables hold the actual function names. They can be overridden for testing.
UPDATES_DOWNLOAD_FILE_IMPL="${UPDATES_DOWNLOAD_FILE_IMPL:-networks::download_file}"
UPDATES_GET_JSON_VALUE_IMPL="${UPDATES_GET_JSON_VALUE_IMPL:-systems::get_json_value}"
UPDATES_PROMPT_CONFIRM_IMPL="${UPDATES_PROMPT_CONFIRM_IMPL:-interfaces::confirm_prompt}"
UPDATES_GET_INSTALLED_VERSION_IMPL="${UPDATES_GET_INSTALLED_VERSION_IMPL:-packages::get_installed_version}"
UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL="${UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL:-packages::update_installed_version_json}"
UPDATES_GET_LATEST_RELEASE_INFO_IMPL="${UPDATES_GET_LATEST_RELEASE_INFO_IMPL:-repositories::get_latest_release_info}"
UPDATES_EXTRACT_DEB_VERSION_IMPL="${UPDATES_EXTRACT_DEB_VERSION_IMPL:-packages::extract_deb_version}"
UPDATES_FLATPAK_SEARCH_IMPL="${UPDATES_FLATPAK_SEARCH_IMPL:-flatpak search}" # Direct binary call

# 10. Event Hooks
# Arrays to store function names to be called at specific events.
declare -a PRE_CHECK_HOOKS
declare -a POST_CHECK_HOOKS
declare -a PRE_INSTALL_HOOKS
declare -a POST_INSTALL_HOOKS
declare -a ERROR_HOOKS

updates::register_hook() {
    local hook_type="$1"
    local function_name="$2"
    case "$hook_type" in
    "pre_check") PRE_CHECK_HOOKS+=("$function_name") ;;
    "post_check") POST_CHECK_HOOKS+=("$function_name") ;;
    "pre_install") PRE_INSTALL_HOOKS+=("$function_name") ;;
    "post_install") POST_INSTALL_HOOKS+=("$function_name") ;;
    "error") ERROR_HOOKS+=("$function_name") ;;
    *) loggers::log_message "WARN" "Unknown hook type: $hook_type" ;;
    esac
}

updates::trigger_hooks() {
    local hooks_array_name="$1" # Name of the array variable
    local app_name="$2"
    local details_json="${3:-}" # Optional JSON string with status/error/version details

    # Validate that the array name is provided
    if [[ -z "$hooks_array_name" ]]; then
        loggers::log_message "WARN" "No hooks array name provided to trigger_hooks"
        return 1
    fi

    # Check if the variable exists
    if ! declare -p "$hooks_array_name" >/dev/null 2>&1; then
        loggers::log_message "WARN" "Hooks array '$hooks_array_name' does not exist"
        return 1
    fi

    # Use indirect expansion to get array elements
    local hook_func
    local -a hook_array
    eval "hook_array=(\"\${${hooks_array_name}[@]}\")"

    for hook_func in "${hook_array[@]}"; do
        if [[ -n "$hook_func" ]] && type -t "$hook_func" | grep -q 'function'; then
            "$hook_func" "$app_name" "$details_json" ||
                loggers::log_message "WARN" "Hook function '$hook_func' failed for app '$app_name'."
        elif [[ -n "$hook_func" ]]; then
            loggers::log_message "WARN" "Registered hook '$hook_func' is not a callable function."
        fi
    done
}

# --- CACHING SETUP (Global scope for persistence across calls) ---
# This is a utility for faster re-checks, not the full caching recommendation.
PACKWATCH_CACHE_DIR="/tmp/packwatch_cache"
mkdir -p "$PACKWATCH_CACHE_DIR" 2>/dev/null || true # Ensure cache directory exists

# ------------------------------------------------------------------------------
# SECTION: Update Decision Helper (No change)
# ------------------------------------------------------------------------------

# Determine if an update is needed by comparing versions.
# Usage: updates::is_needed "current_version" "latest_version"
updates::is_needed() {
    local current_version="$1"
    local latest_version="$2"
    versions::is_newer "$latest_version" "$current_version"
}

# ------------------------------------------------------------------------------
# SECTION: DEB Package Helper Functions
# ------------------------------------------------------------------------------

# Extracted helper for DEB renaming
updates::_rename_deb_file() {
    local current_path="$1"
    local template="$2"
    local version="$3"
    local app_name="$4"

    local target_filename
    target_filename=$(printf "$template" "$version")
    target_filename=$(systems::sanitize_filename "$target_filename")
    local new_path="/tmp/$target_filename"

    if [[ "$current_path" != "$new_path" ]]; then
        if mv "$current_path" "$new_path"; then
            systems::unregister_temp_file "$current_path"
            TEMP_FILES+=("$new_path")
            echo "$new_path"
            return 0
        else
            loggers::log_message "WARN" "Failed to rename downloaded DEB to '$new_path'. Proceeding with original name."
            echo "$current_path"
            return 1
        fi
    fi
    echo "$current_path"
    return 0
}

# New generic helper to handle GPG verification flow if configured
updates::_handle_gpg_verification() {
    local -n app_config_ref=$1
    local deb_path="$2"
    local download_url="$3"
    local app_name="${app_config_ref[name]}"

    local key_id="${app_config_ref[gpg_key_id]:-}"
    local fingerprint="${app_config_ref[gpg_fingerprint]:-}"

    if [[ -z "$key_id" ]] || [[ -z "$fingerprint" ]]; then
        loggers::log_message "DEBUG" "No GPG configuration for '$app_name'. Skipping verification."
        return 0
    fi

    if ! gpg::prompt_import_and_verify "$key_id" "$fingerprint" "$app_name"; then
        return 1
    fi

    local sig_download_url="${download_url}.sig"
    if ! updates::_verify_gpg_signature "$sig_download_url" "$deb_path" "$app_name"; then
        return 1
    fi

    return 0
}

# Extracted helper for GPG signature verification
updates::_verify_gpg_signature() {
    local sig_url="$1"
    local deb_path="$2"
    local app_name="$3"

    local temp_sig_path
    if ! temp_sig_path=$(systems::create_temp_file "${app_name}_sig"); then return 1; fi
    temp_sig_path="${temp_sig_path}.sig"

    interfaces::print_ui_line "  " "→ " "Downloading signature for verification..."

    # Use dependency injection for download_file
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$sig_url" "$temp_sig_path" ""; then
        errors::handle_error "NETWORK_ERROR" "Failed to download signature for '$app_name'. Aborting." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download signature.\"}"
        return 1
    fi

    interfaces::print_ui_line "  " "→ " "Verifying signature..."
    # Ensure gpg.sh is sourced to use _get_gpg_fingerprint_as_user
    # shellcheck source=/dev/null
    source "$LIB_DIR/gpg.sh"

    local gpg_verify_output=""
    local gpg_verify_status=1 # Assume failure

    if [[ -z "$ORIGINAL_USER" ]]; then
        loggers::log_message "ERROR" "ORIGINAL_USER is not set. Cannot perform GPG signature verification as original user. Falling back to root."
        gpg_verify_output=$(gpg --verify "$temp_sig_path" "$deb_path" 2>&1)
    elif ! getent passwd "$ORIGINAL_USER" &>/dev/null; then
        loggers::log_message "ERROR" "ORIGINAL_USER '$ORIGINAL_USER' does not exist. Cannot perform GPG signature verification as original user. Falling back to root."
        gpg_verify_output=$(gpg --verify "$temp_sig_path" "$deb_path" 2>&1)
    elif [[ ! -d "$ORIGINAL_HOME" ]]; then
        loggers::log_message "ERROR" "ORIGINAL_HOME '$ORIGINAL_HOME' is not a valid directory. Cannot perform GPG signature verification as original user. Falling back to root."
        gpg_verify_output=$(gpg --verify "$temp_sig_path" "$deb_path" 2>&1)
    elif [[ ! -d "$ORIGINAL_HOME/.gnupg" ]]; then
        loggers::log_message "ERROR" "GPG home directory '$ORIGINAL_HOME/.gnupg' does not exist. Cannot perform GPG signature verification as original user. Falling back to root."
        gpg_verify_output=$(gpg --verify "$temp_sig_path" "$deb_path" 2>&1)
    else
        # Attempt as original user, capturing stderr
        gpg_verify_output=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
            gpg --verify "$temp_sig_path" "$deb_path" 2>&1)
    fi

    if echo "$gpg_verify_output" | grep -q "Good signature"; then
        gpg_verify_status=0 # Success
    else
        loggers::log_message "ERROR" "GPG signature verification failed for '$app_name' DEB. Output: $gpg_verify_output"
    fi

    if [[ "$gpg_verify_status" -eq 0 ]]; then
        loggers::log_message "INFO" "✓ Signature verification passed."
        interfaces::print_ui_line "  " "✓ " "Signature verification passed." "${COLOR_GREEN}"
        return 0
    else
        errors::handle_error "GPG_ERROR" "Signature verification FAILED for '$app_name' DEB. Aborting installation due to potential tampering." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"GPG_ERROR\", \"message\": \"Signature verification FAILED.\"}"
        return 1
    fi
}
# Centralized helper to perform checksum and GPG verification for a downloaded artifact.
# Usage: updates::verify_downloaded_artifact app_config_nameref downloaded_file_path download_url
# Returns 0 on success (all configured verifications pass or no verifications configured), 1 on failure.
updates::verify_downloaded_artifact() {
    local -n app_config_ref=$1
    local downloaded_file_path="$2"
    local download_url="$3" # Original download URL, used for .sig default

    local app_name="${app_config_ref[name]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}"

    loggers::log_message "DEBUG" "Verifying downloaded artifact for '$app_name': '$downloaded_file_path'"

    # 1. Checksum Verification
    local checksum_url="${app_config_ref[checksum_url]:-}"
    local checksum_algorithm="${app_config_ref[checksum_algorithm]:-sha256}"
    if [[ -n "$checksum_url" ]]; then
        interfaces::print_ui_line "  " "→ " "Downloading checksum for verification..."
        local csf; csf=$(networks::download_text_to_cache "$checksum_url" "$allow_http") || {
            errors::handle_error "NETWORK_ERROR" "Failed to download checksum file from '$checksum_url'" "$app_name"
            return 1
        }
        local expected_checksum; expected_checksum=$(validators::extract_checksum_from_file "$csf" "$(basename "$downloaded_file_path" | cut -d'?' -f1)")
        systems::unregister_temp_file "$csf" # Clean up checksum file

        if [[ -z "$expected_checksum" ]]; then
            errors::handle_error "VALIDATION_ERROR" "Could not extract checksum from '$checksum_url' for '$app_name'." "$app_name"
            return 1
        fi

        loggers::log_message "DEBUG" "Performing checksum verification for '$app_name'. Expected: '$expected_checksum', Algorithm: '$checksum_algorithm'"
        if ! validators::verify_checksum "$downloaded_file_path" "$expected_checksum" "$checksum_algorithm"; then
            errors::handle_error "VALIDATION_ERROR" "Checksum verification failed for '$app_name'." "$app_name"
            return 1
        fi
    else
        loggers::log_message "DEBUG" "No checksum_url configured for '$app_name'. Skipping checksum verification."
    fi

    # 2. GPG Signature Verification
    local gpg_key_id="${app_config_ref[gpg_key_id]:-}"
    local gpg_fingerprint="${app_config_ref[gpg_fingerprint]:-}"
    local sig_url_override="${app_config_ref[sig_url]:-}"

    if [[ -n "$gpg_key_id" ]] && [[ -n "$gpg_fingerprint" ]]; then
        local sig_download_url="${sig_url_override:-${download_url}.sig}"
        interfaces::print_ui_line "  " "→ " "Downloading signature for verification..."
        local sigf; sigf=$(networks::download_text_to_cache "$sig_download_url" "$allow_http") || {
            errors::handle_error "NETWORK_ERROR" "Failed to download signature file from '$sig_download_url'" "$app_name"
            return 1
        }

        loggers::log_message "DEBUG" "Performing GPG signature verification for '$app_name'. Key ID: '$gpg_key_id', Fingerprint: '$gpg_fingerprint'"
        if ! gpg::verify_detached "$downloaded_file_path" "$sigf" "$gpg_key_id" "$gpg_fingerprint" "user_keyring" ""; then
            errors::handle_error "GPG_ERROR" "GPG signature verification failed for '$app_name'." "$app_name"
            systems::unregister_temp_file "$sigf" # Clean up signature file
            return 1
        fi
        systems::unregister_temp_file "$sigf" # Clean up signature file
    else
        loggers::log_message "DEBUG" "No gpg_key_id or gpg_fingerprint configured for '$app_name'. Skipping GPG verification."
    fi

    return 0
}

# Extracted helper for checksum-based update detection for DEB files
updates::_compare_deb_checksums() {
    local temp_file="$1"
    local package_name="$2"
    local installed_version="$3"
    local downloaded_version="$4"
    local app_name="$5"
    local app_key="$6"

    local needs_update=0
    local final_downloaded_version="$downloaded_version"

    interfaces::print_ui_line "  " "→ " "Comparing package checksums for ${FORMAT_BOLD}$app_name${FORMAT_RESET}..."

    local current_deb_path="/var/cache/apt/archives/${package_name}_${installed_version}_amd64.deb"
    if [[ -f "$current_deb_path" ]]; then
        local current_checksum
        current_checksum=$(sha256sum "$current_deb_path" | cut -d' ' -f1)
        local downloaded_checksum
        downloaded_checksum=$(sha256sum "$temp_file" | cut -d' ' -f1)

        if [[ "$downloaded_checksum" != "$current_checksum" ]]; then
            interfaces::print_ui_line "  " "✓ " "New package detected (different checksum)." "${COLOR_GREEN}"
            needs_update=1
            final_downloaded_version="${downloaded_version}-new-checksum"
        else
            loggers::log_message "INFO" "✓ Up to date (checksums match)."
        fi
    else
        loggers::log_message "INFO" "No cached DEB file found for '$package_name' ('$current_deb_path') for checksum comparison. Cannot confirm if new version by checksum if versions are identical."
        if versions::compare_strings "$installed_version" "0.0.0" -eq 1; then
            interfaces::print_ui_line "  " "→ " "Assuming installation is needed (app not installed or cached DEB missing)."
            needs_update=1
        fi
    fi

    echo "$needs_update:$final_downloaded_version"
    return 0
}

# Download or prepare DEB file for installation
updates::_prepare_deb_file() {
    local app_name="$1"
    local download_url="$2"
    local deb_file_to_install="$3"
    local expected_checksum="$4"
    local checksum_algorithm="$5"
    local allow_http="${6:-0}" # New parameter

    local final_deb_path
    if [[ -n "$deb_file_to_install" && -f "$deb_file_to_install" ]]; then
        final_deb_path="$deb_file_to_install"
        loggers::log_message "DEBUG" "Using pre-downloaded DEB: '$final_deb_path'"
    else
        local temp_deb_file
        local base_filename
        base_filename="$(basename "${download_url}" | cut -d'?' -f1 | sed 's/\.deb$//')"
        base_filename=$(systems::sanitize_filename "$base_filename")

        # Capture only the last line which should be the file path
        local create_output
        if ! create_output=$(systems::create_temp_file "${base_filename}" 2>&1); then return 1; fi

        # Extract the file path (assuming it's the last line)
        temp_deb_file=$(echo "$create_output" | tail -n 1)
        temp_deb_file="${temp_deb_file}.deb"

        updates::on_download_start "$app_name" "unknown" # Initial download progress hook
        # Use dependency injection for download_file
        if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_deb_file" "$expected_checksum" "$checksum_algorithm"; then
            errors::handle_error "NETWORK_ERROR" "Failed to download DEB package" "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download DEB package.\"}"
            return 1
        fi
        updates::on_download_complete "$app_name" "$temp_deb_file" # Download complete hook
        final_deb_path="$temp_deb_file"
    fi

    echo "$final_deb_path"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: DEB Package Update Flow
# ------------------------------------------------------------------------------

updates::process_deb_package() {
    local -n app_config_ref=$1 # Now accepts app_config_ref directly
    local deb_filename_template="$2"
    local latest_version="$3"
    local download_url="$4"
    local deb_file_to_install="${5:-}"

    local app_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local expected_checksum="${app_config_ref[checksum_url]:-}" # Get from config
    local checksum_algorithm="${app_config_ref[checksum_algorithm]:-sha256}" # Get from config
    local allow_http="${app_config_ref[allow_insecure_http]:-0}" # Get from config

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for DEB update flow" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"deb_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Invalid parameters for DEB update flow.\"}"
        return 1
    fi

    # Prepare DEB file
    local final_deb_path
    if ! final_deb_path=$(updates::_prepare_deb_file "$app_name" "$download_url" "$deb_file_to_install" "$expected_checksum" "$checksum_algorithm" "$allow_http"); then return 1; fi # Pass allow_http

    # Perform centralized verification
    if ! updates::verify_downloaded_artifact app_config_ref "$final_deb_path" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded DEB package: '$app_name'." "$app_name"
        return 1
    fi

    # Handle file renaming
    if [[ -n "$deb_filename_template" ]]; then
        local renamed_path
        if ! renamed_path=$(updates::_rename_deb_file "$final_deb_path" "$deb_filename_template" "$latest_version" "$app_name"); then
            loggers::log_message "WARN" "Proceeding with original DEB file name."
        fi
        final_deb_path="$renamed_path"
    fi

    # Use the generic process_installation function
    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "packages::install_deb_package" \
        "$final_deb_path" \
        "$app_name" \
        "$latest_version" \
        "$app_key"
}

# ------------------------------------------------------------------------------
# SECTION: GitHub DEB Update Flow
# ------------------------------------------------------------------------------

# Updates module; checks for updates for a GitHub DEB application.
updates::check_github_deb() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local repo_owner="${app_config_ref[repo_owner]}"
    local repo_name="${app_config_ref[repo_name]}"
    local filename_pattern_template="${app_config_ref[filename_pattern_template]}"
    local source="GitHub Releases"

    interfaces::print_ui_line "  " "→ " "Checking GitHub releases for ${FORMAT_BOLD}$name${FORMAT_RESET}..."

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    # Use the new helper function
    local fetch_result
    fetch_result=$(updates::_fetch_github_version "$repo_owner" "$repo_name" "$name") || return 1
    local latest_version
    latest_version=$(echo "$fetch_result" | head -n1)
    local latest_release_json_path # This will be the path to the JSON file
    latest_release_json_path=$(echo "$fetch_result" | tail -n +2)

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        # Use the new helper functions
        local download_url
        if ! download_url=$(updates::_build_download_url "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name"); then
            return 1
        fi

        local expected_checksum
        expected_checksum=$(updates::_extract_release_checksum "$latest_release_json_path" "$filename_pattern_template" "$latest_version" "$name")

        updates::process_deb_package \
            app_config_ref \
            "$filename_pattern_template" \
            "$latest_version" \
            "$download_url" \
            "" # deb_file_to_install (empty for github_deb)
    else
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
    fi

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Direct DEB Update Flow
# ------------------------------------------------------------------------------

# Updates module; checks for updates for a direct DEB application.
updates::check_direct_deb() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local package_name="${app_config_ref[package_name]}"
    local download_url="${app_config_ref[download_url]}"
    local deb_filename_template="${app_config_ref[deb_filename_template]}"
    local source="Direct Download"

    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid download URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid download URL configured." "${COLOR_RED}"
        return 1
    fi

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    # Always show "Checking ..." at the start
    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    # Verbose log lines: Installed and Source first
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Installed: $installed_version"
        loggers::log_message "INFO" "Source:    $source"
    fi

    local temp_download_file
    local base_filename_from_url
    base_filename_from_url="$(basename "$download_url" | cut -d'?' -f1 | sed 's/\.deb$//')"
    base_filename_from_url=$(systems::sanitize_filename "$base_filename_from_url")
    if ! temp_download_file=$(systems::create_temp_file "${base_filename_from_url}"); then return 1; fi

    local allow_http="${app_config_ref[allow_insecure_http]:-0}"

    updates::on_download_start "$name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_download_file" "" "" "$allow_http"; then # DI applied, added allow_http
        errors::handle_error "NETWORK_ERROR" "Failed to download package for '$name'." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download package.\"}"
        return 1
    fi
    updates::on_download_complete "$name" "$temp_download_file" # Hook

    # Perform verification after download
    if ! updates::verify_downloaded_artifact app_config_ref "$temp_download_file" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded package: '$name'." "$name"
        return 1
    fi

    local downloaded_version
    downloaded_version=$(versions::normalize "$("$UPDATES_EXTRACT_DEB_VERSION_IMPL" "$temp_download_file")") # DI applied

    if [[ "$downloaded_version" == "0.0.0" ]]; then
        interfaces::print_ui_line "  " "! " "Failed to extract version from downloaded package for '$name'. Will try checksum." "${COLOR_YELLOW}"
    fi

    # Verbose log line: Latest after fetch
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Latest:    $downloaded_version"
        loggers::print_message ""
    fi

    # Standardized summary output
    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$downloaded_version"

    local needs_update=0
    if updates::is_needed "$installed_version" "$downloaded_version"; then
        needs_update=1
    elif versions::compare_strings "$downloaded_version" "$installed_version" -eq 1; then
        local checksum_result
        if ! checksum_result=$(updates::_compare_deb_checksums \
            "$temp_download_file" \
            "$package_name" \
            "$installed_version" \
            "$downloaded_version" \
            "$name" \
            "$app_key"); then return 1; fi

        needs_update=$(echo "$checksum_result" | cut -d':' -f1)
        downloaded_version=$(echo "$checksum_result" | cut -d':' -f2)
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $downloaded_version" "${COLOR_YELLOW}"
        updates::process_deb_package \
            app_config_ref \
            "$deb_filename_template" \
            "$downloaded_version" \
            "$download_url" \
            "$temp_download_file"
    else
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
        rm -f "$temp_download_file"
        systems::unregister_temp_file "$temp_download_file"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: AppImage Update Flow
# ------------------------------------------------------------------------------

updates::process_appimage_file() {
    local app_name="$1"
    local latest_version="$2"
    local download_url="$3"
    local install_target_full_path="$4"
    local app_key="$5" # Reordered app_key
    local expected_checksum="${6:-}" # Reordered expected_checksum
    local checksum_algorithm="${7:-sha256}" # Reordered checksum_algorithm
    local allow_http="${8:-0}" # New parameter

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url" || [[ -z "$install_target_full_path" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for AppImage update flow (version, URL, install path, or app_key missing)" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"appimage_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Invalid parameters for AppImage update flow.\"}"
        return 1
    fi

    local temp_appimage_path
    local base_filename_for_tmp
    base_filename_for_tmp="$(basename "$install_target_full_path" | sed 's/\.AppImage$//')"
    base_filename_for_tmp=$(systems::sanitize_filename "$base_filename_for_tmp")
    if ! temp_appimage_path=$(mktemp "/tmp/${base_filename_for_tmp}.XXXXXX.AppImage"); then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: '${base_filename_for_tmp}.XXXXXX.AppImage'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"appimage_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Failed to create temporary file.\"}"
        return 1
    fi
    TEMP_FILES+=("$temp_appimage_path")

    local allow_http="${app_config_ref[allow_insecure_http]:-0}" # Get from config

    updates::on_download_start "$app_name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_appimage_path" "$expected_checksum" "$checksum_algorithm" "$allow_http"; then # DI applied, added allow_http
        errors::handle_error "NETWORK_ERROR" "Failed to download AppImage" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download AppImage.\"}"
        return 1
    fi
    updates::on_download_complete "$app_name" "$temp_appimage_path" # Hook

    # Perform verification after download
    if ! updates::verify_downloaded_artifact app_config_ref "$temp_appimage_path" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded AppImage: '$app_name'." "$app_name"
        return 1
    fi

    if ! chmod +x "$temp_appimage_path"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to make AppImage executable: '$temp_appimage_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to make AppImage executable.\"}"
        return 1
    fi

    # Use the generic process_installation function
    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "updates::_install_appimage_file_command" \
        "$temp_appimage_path" \
        "$install_target_full_path" \
        "$app_name"
}

# Helper function to encapsulate the AppImage installation command
updates::_install_appimage_file_command() {
    local temp_appimage_path="$1"
    local install_target_full_path="$2"
    local app_name="$3" # Passed from process_installation, but not used here directly

    local target_dir
    target_dir="$(dirname "$install_target_full_path")"
    if ! mkdir -p "$target_dir"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to create installation directory: '$target_dir'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to create installation directory.\"}"
        return 1
    fi

    # Remove existing file if present
    if [[ -f "$install_target_full_path" ]]; then
        if ! rm -f "$install_target_full_path"; then
            errors::handle_error "PERMISSION_ERROR" "Failed to remove existing AppImage: '$install_target_full_path'" "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"PERMISSION_ERROR\", \"message\": \"Failed to remove existing AppImage.\"}"
            return 1
        fi
    fi

    loggers::log_message "DEBUG" "Moving from '$temp_appimage_path' to '$install_target_full_path'"
    if mv "$temp_appimage_path" "$install_target_full_path"; then
        systems::unregister_temp_file "$temp_appimage_path"
        chmod +x "$install_target_full_path" || loggers::log_message "WARN" "Failed to make final AppImage executable: '$install_target_full_path'."
        if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &>/dev/null; then
            chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$install_target_full_path" 2>/dev/null ||
                loggers::log_message "WARN" "Failed to change ownership of '$install_target_full_path' to '$ORIGINAL_USER'."
        fi
        return 0
    else
        errors::handle_error "INSTALLATION_ERROR" "Failed to move new AppImage from '$temp_appimage_path' to '$install_target_full_path'" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Failed to move new AppImage.\"}"
        return 1
    fi
}

# Updates module; checks for updates for an AppImage application.
updates::check_appimage() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local install_path="${app_config_ref[install_path]}"
    local github_repo_owner="${app_config_ref[repo_owner]:-}"
    local github_repo_name="${app_config_ref[repo_name]:-}"

    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid download URL configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid download URL configured." "${COLOR_RED}"
        return 1
    fi
    if ! validators::check_file_path "$install_path"; then
        errors::handle_error "CONFIG_ERROR" "Invalid install path in configuration" "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Invalid install path configured.\"}"
        interfaces::print_ui_line "  " "✗ " "Invalid install path configured." "${COLOR_RED}"
        return 1
    fi

    local resolved_install_base_dir="${install_path//\$HOME/$ORIGINAL_HOME}"
    resolved_install_base_dir="${resolved_install_base_dir/#\~/$ORIGINAL_HOME}"
    local appimage_file_path_current="${resolved_install_base_dir}/${name}.AppImage"

    local installed_version
    installed_version=$(versions::normalize "$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key")") # DI applied

    # Always show "Checking ..." at the start
    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$name${FORMAT_RESET} for latest version..."

    local latest_version=""
    local expected_checksum=""
    local checksum_algorithm="sha256"
    local source="Direct Download"

    # Verbose log lines: Installed and Source first
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Installed: $installed_version"
        loggers::log_message "INFO" "Source:    $source"
    fi

    if [[ -n "$github_repo_owner" ]] && [[ -n "$github_repo_name" ]]; then
        local api_response_file                                                                                        # This will now be a file path
        if api_response_file=$("$UPDATES_GET_LATEST_RELEASE_INFO_IMPL" "$github_repo_owner" "$github_repo_name"); then # DI applied
            local latest_release_json_path                                                                             # This will be the path to the JSON file
            if latest_release_json_path=$("$UPDATES_GET_JSON_VALUE_IMPL" "$api_response_file" '.[0]' "$name"); then    # DI applied
                if ! latest_version=$(repositories::parse_version_from_release "$latest_release_json_path" "$name"); then
                    loggers::log_message "WARN" "Failed to parse version from GitHub release for '$name'. Will try direct download URL."
                fi

                local download_filename_from_url
                download_filename_from_url="$(basename "$download_url" | cut -d'?' -f1)"
                if ! expected_checksum=$(repositories::find_asset_checksum "$latest_release_json_path" "$download_filename_from_url" "$name"); then loggers::log_message "WARN" "Failed to get GitHub checksum for '$name'."; fi
                source="GitHub Releases"
            fi
        else
            loggers::log_message "WARN" "Failed to fetch GitHub latest release for '$name'. Will try direct download URL."
        fi
    fi

    if [[ -z "$latest_version" ]]; then
        loggers::log_message "DEBUG" "Attempting to extract version from download URL filename: '$download_url'"
        local filename_from_url
        filename_from_url=$(basename "$download_url" | cut -d'?' -f1)
        if ! latest_version=$(versions::extract_from_regex "$filename_from_url" '^[0-9]+([.-][0-9a-zA-Z]+)*(-[0-9a-Z.-]+)?(\+[0-9a-zA-Z.-]+)?' "$name"); then
            loggers::log_message "WARN" "Could not extract version from AppImage download URL filename for '$name'. Will default to 0.0.0 for comparison."
            latest_version="0.0.0"
        fi
    fi

    # Verbose log line: Latest after fetch
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Latest:    $latest_version"
        loggers::print_message ""
    fi

    # Standardized summary output
    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_appimage_file \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$app_key" \
            "${app_config_ref[checksum_url]:-}" \
            "${app_config_ref[checksum_algorithm]:-sha256}" \
            "${app_config_ref[allow_insecure_http]:-0}"
    elif [[ "$installed_version" == "0.0.0" && "$latest_version" != "0.0.0" ]]; then
        interfaces::print_ui_line "  " "⬆ " "App not installed. Installing $latest_version." "${COLOR_YELLOW}"
        updates::process_appimage_file \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$app_key" \
            "${app_config_ref[checksum_url]:-}" \
            "${app_config_ref[checksum_algorithm]:-sha256}" \
            "${app_config_ref[allow_insecure_http]:-0}"
    else
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
    fi

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Flatpak Update Flow
# ------------------------------------------------------------------------------

# Updates module; installs/updates a Flatpak application.
updates::process_flatpak_app() {
    local app_name="$1"
    local app_key="$2"
    local latest_version="$3"
    local flatpak_app_id="$4"

    if [[ -z "$app_name" ]] || [[ -z "$app_key" ]] || [[ -z "$latest_version" ]] || [[ -z "$flatpak_app_id" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Missing required parameters for Flatpak installation" "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"flatpak_process\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Missing required parameters for Flatpak installation.\"}"
        return 1
    fi

    if ! command -v flatpak &>/dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "Flatpak is not installed. Cannot update $app_name." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"DEPENDENCY_ERROR\", \"message\": \"Flatpak is not installed.\"}"
        interfaces::print_ui_line "  " "✗ " "Flatpak not installed. Cannot update ${FORMAT_BOLD}$app_name${FORMAT_RESET}." "${COLOR_RED}"
        return 1
    fi
    if ! flatpak remotes | grep -q flathub; then
        interfaces::print_ui_line "  " "→ " "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || {
            errors::handle_error "INSTALLATION_ERROR" "Failed to add Flathub remote. Cannot update $app_name." "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Failed to add Flathub remote.\"}"
            interfaces::print_ui_line "  " "✗ " "Failed to add Flathub remote." "${COLOR_RED}"
            return 1
        }
    fi
    interfaces::print_ui_line "  " "→ " "Updating Flatpak appstream data..."
    flatpak update --appstream -y || {
        loggers::log_message "WARN" "Failed to update Flatpak appstream data for $app_name. Installation might proceed but information could be stale."
        interfaces::print_ui_line "  " "! " "Failed to update Flatpak appstream data. Continuing anyway." "${COLOR_YELLOW}"
    }

    # Use the generic process_installation function
    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "flatpak" \
        "install" \
        "--or-update" \
        "-y" \
        "flathub" \
        "$flatpak_app_id"
}

# ------------------------------------------------------------------------------
# SECTION: Flatpak Update Flow (Direct Check for consistency with UPDATE_HANDLERS)
# ------------------------------------------------------------------------------

# Updates module; checks for updates for a Flatpak application.
updates::check_flatpak() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local flatpak_app_id="${app_config_ref[flatpak_app_id]}"
    local source="Flathub"

    if ! command -v flatpak &>/dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "Flatpak is not installed. Cannot check $name." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"DEPENDENCY_ERROR\", \"message\": \"Flatpak is not installed.\"}"
        interfaces::print_ui_line "  " "✗ " "Flatpak not installed. Cannot check ${FORMAT_BOLD}$name${FORMAT_RESET}." "${COLOR_RED}"
        return 1
    fi

    interfaces::print_ui_line "  " "→ " "Checking Flatpak for ${FORMAT_BOLD}$name${FORMAT_RESET}..."

    local latest_version="0.0.0"
    local flatpak_search_output
    if flatpak_search_output=$("$UPDATES_FLATPAK_SEARCH_IMPL" --columns=application,version,summary "$flatpak_app_id" 2>/dev/null); then # DI applied
        if [[ "$flatpak_search_output" =~ "$flatpak_app_id"[[:space:]]+([0-9.]+[^[:space:]]*)[[:space:]]+.* ]]; then
            latest_version=$(versions::normalize "${BASH_REMATCH[1]}")
        else
            loggers::log_message "WARN" "Could not parse Flatpak version for '$name' from search output."
        fi
    else
        errors::handle_error "NETWORK_ERROR" "Failed to search Flatpak remote for '$name'." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to search Flatpak remote.\"}"
        interfaces::print_ui_line "  " "✗ " "Failed to search Flatpak remote for '$name'. Cannot determine latest version." "${COLOR_RED}"
        return 1
    fi

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_flatpak_app \
            "$name" \
            "$app_key" \
            "$latest_version" \
            "$flatpak_app_id"
    else
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
    fi

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Custom App Update Flow
# ------------------------------------------------------------------------------

# Updates helper; handles the logic for a 'custom' application type.
# This function now passes a JSON string of the app configuration to the custom checker.
updates::handle_custom_check() {
    local config_array_name="$1"
    local -n app_config_ref=$config_array_name
    local app_display_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}" # Ensure app_key is available
    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    local custom_checker_script="${app_config_ref[custom_checker_script]}"
    if [[ -z "$custom_checker_script" ]]; then
        errors::handle_error "CONFIG_ERROR" "Missing 'custom_checker_script' for custom app type" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Missing custom_checker_script.\"}"
        interfaces::print_ui_line "  " "✗ " "Configuration error: Missing custom checker script." "${COLOR_RED}"
        return 1
    fi

    local custom_checkers_dir="${CORE_DIR}/custom_checkers"
    local script_path="${custom_checkers_dir}/${custom_checker_script}"

    # Export functions and variables for custom checker subshell
    export -f loggers::log_message
    export -f interfaces::print_ui_line
    export -f systems::get_json_value
    export -f systems::require_json_value
    export -f systems::create_temp_file
    export -f systems::unregister_temp_file
    export -f systems::sanitize_filename
    export -f systems::reattempt_command
    export -f errors::handle_error # Original error handler for custom scripts to use

    # Export dependency injection variables - Custom checkers should be able to use these if they rely on base functions
    export UPDATES_DOWNLOAD_FILE_IMPL UPDATES_GET_JSON_VALUE_IMPL UPDATES_PROMPT_CONFIRM_IMPL UPDATES_GET_INSTALLED_VERSION_IMPL UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL UPDATES_GET_LATEST_RELEASE_INFO_IMPL UPDATES_EXTRACT_DEB_VERSION_IMPL UPDATES_FLATPAK_SEARCH_IMPL

    export -f validators::check_url_format
    export -f packages::get_installed_version
    export -f versions::is_newer
    export ORIGINAL_HOME ORIGINAL_USER VERBOSE DRY_RUN
    # Check if NETWORK_CONFIG is set before exporting, avoids errors if it's not
    declare -p NETWORK_CONFIG >/dev/null 2>&1 && export NETWORK_CONFIG
    # Explicitly export relevant updates functions that custom checkers might call or benefit from
    # Only export _public_ interfaces of other modules used by custom checkers
    while IFS= read -r func; do
        export -f "$func" 2>/dev/null || true
    done < <(declare -F | awk '{print $3}' | grep -E '^(networks|packages|versions|validators|systems|updates)::') # Added updates
    export -f updates::verify_downloaded_artifact # Explicitly export the new function

    # Always show "Checking ..." at the start
    interfaces::print_ui_line "  " "→ " "Checking ${FORMAT_BOLD}$app_display_name${FORMAT_RESET} for latest version..."

    local custom_checker_output=""
    local custom_checker_func="${app_config_ref[custom_checker_func]}"

    # Source the custom checker script
    source "$script_path" || {
        errors::handle_error "CONFIG_ERROR" "Failed to source custom checker script: '$script_path'" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Failed to source custom checker script.\"}"
        return 1
    }

    # Verify the custom checker function exists
    if [[ -z "$custom_checker_func" ]] || ! type -t "$custom_checker_func" | grep -q 'function'; then
        errors::handle_error "CONFIG_ERROR" "Custom checker function '$custom_checker_func' not found in script '$custom_checker_script'" "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"check\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Custom checker function not found.\"}"
        return 1
    fi

    # Convert the app_config_ref associative array to a JSON string
    local app_config_json="{}"
    local key
    for key in "${!app_config_ref[@]}"; do
        app_config_json=$(echo "$app_config_json" | jq --arg k "$key" --arg v "${app_config_ref[$key]}" '.[$k] = $v')
    done

    # Pass the JSON string as the first argument to the custom checker function
    custom_checker_output=$("$custom_checker_func" "$app_config_json")
    local status
    status=$(echo "$custom_checker_output" | jq -r '.status // "error"')
    local latest_version
    latest_version=$(versions::normalize "$(echo "$custom_checker_output" | jq -r '.latest_version // "0.0.0"')")
    local source
    source=$(echo "$custom_checker_output" | jq -r '.source // "Unknown"')
    local error_message
    error_message=$(echo "$custom_checker_output" | jq -r '.error_message // empty')
    local error_type_from_checker
    error_type_from_checker=$(echo "$custom_checker_output" | jq -r '.error_type // "CUSTOM_CHECKER_ERROR"')

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"

    if [[ "$status" == "success" ]] && updates::is_needed "$installed_version" "$latest_version"; then
        local install_type
        install_type=$(echo "$custom_checker_output" | jq -r '.install_type // "unknown"')

        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"

        case "$install_type" in
        "deb")
            local download_url_from_output
            download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
            local gpg_key_id_from_output
            gpg_key_id_from_output=$(echo "$custom_checker_output" | jq -r '.gpg_key_id // empty')
            local gpg_fingerprint_from_output
            gpg_fingerprint_from_output=$(echo "$custom_checker_output" | jq -r '.gpg_fingerprint')

            updates::process_deb_package \
                app_config_ref \
                "${app_config_ref[deb_filename_template]:-}" \
                "$latest_version" \
                "$download_url_from_output" \
                "" # deb_file_to_install (empty for custom deb)
            ;;
        "appimage")
            local download_url_from_output install_target_path_from_output
            download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
            install_target_path_from_output=$(echo "$custom_checker_output" | jq -r '.install_target_path')

            updates::process_appimage_file \
                "${app_config_ref[name]}" \
                "${latest_version}" \
                "${download_url_from_output}" \
                "${install_target_path_from_output}" \
                "${app_config_ref[app_key]}" \
                "${app_config_ref[checksum_url]:-}" \
                "${app_config_ref[checksum_algorithm]:-sha256}" \
                "${app_config_ref[allow_insecure_http]:-0}"
            ;;
        "flatpak")
            local flatpak_app_id_from_output
            flatpak_app_id_from_output=$(echo "$custom_checker_output" | jq -r '.flatpak_app_id')

            updates::process_flatpak_app \
                "${app_config_ref[name]}" \
                "${app_config_ref[app_key]}" \
                "$latest_version" \
                "$flatpak_app_id_from_output"
            ;;
        *)
            interfaces::print_ui_line "  " "✗ " "Unknown install type from custom checker: $install_type" "${COLOR_RED}"
            return 1
            ;;
        esac
    elif [[ "$status" == "no_update" || "$status" == "success" ]]; then
        interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
        counters::inc_up_to_date
    elif [[ "$status" == "error" ]]; then
        errors::handle_error "$error_type_from_checker" "$error_message" "$app_display_name"
        interfaces::print_ui_line "  " "✗ " "Error: $error_message" "${COLOR_RED}"
        return 1
    else
        interfaces::print_ui_line "  " "✗ " "Unknown status from checker." "${COLOR_RED}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Configuration Validation Helper (Recommendation 4)
# ------------------------------------------------------------------------------

# Validates the application configuration against predefined schemas.
# Usage: updates::_validate_app_config app_type_string app_config_nameref_string
# Returns 0 if valid, 1 if invalid. Logs errors internally.
updates::_validate_app_config() {
    local app_type="$1"
    local -n config_ref=$2 # Use nameref for the actual config array

    local app_name="${config_ref[name]:-unknown_app}"

    local required_fields_str="${APP_TYPE_VALIDATIONS[$app_type]}"
    if [[ -z "$required_fields_str" ]]; then
        errors::handle_error "CONFIG_ERROR" "No validation schema found for app type '$app_type'." "$app_name" "Please define it in APP_TYPE_VALIDATIONS."
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"config_validation\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"No validation schema found for app type.\"}"
        return 1
    fi

    local field
    IFS=',' read -ra fields <<<"$required_fields_str"
    for field in "${fields[@]}"; do
        # Check if the field is empty in the config
        if [[ -z "${config_ref[$field]:-}" ]]; then
            errors::handle_error "VALIDATION_ERROR" "Missing required field '$field' for app type '$app_type'." "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"config_validation\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Missing required field '$field'.\"}"
            return 1
        fi
    done

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Main Application Update Dispatcher (Individual App)
# ------------------------------------------------------------------------------

# Updates module; checks for updates for a single application defined in config.
updates::check_application() {
    local app_key="$1"
    local current_index="$2"
    local total_apps="$3"

    if [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Empty app key provided"
        updates::trigger_hooks ERROR_HOOKS "unknown" "{\"phase\": \"cli_parsing\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Empty app key provided.\"}"
        counters::inc_failed
        return 1
    fi

    declare -A _current_app_config
    if ! configs::get_app_config "$app_key" "_current_app_config"; then
        errors::handle_error "CONFIG_ERROR" "Failed to retrieve configuration for app: '$app_key'" "$app_key"
        updates::trigger_hooks ERROR_HOOKS "$app_key" "{\"phase\": \"config_retrieval\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Failed to retrieve configuration.\"}"
        return 1
    fi

    local app_display_name="${_current_app_config[name]:-$app_key}"
    interfaces::display_header "$app_display_name" "$current_index" "$total_apps"

    # Validate the current application's configuration (Recommendation 4)
    local app_type="${_current_app_config[type]:-}"
    if ! updates::_validate_app_config "$app_type" "_current_app_config"; then
        interfaces::print_ui_line "  " "✗ " "Configuration error: Missing required fields." "${COLOR_RED}"
        counters::inc_failed
        loggers::print_message "" # Blank line after each app block
        return 1
    fi

    if [[ -z "${_current_app_config[type]:-}" ]]; then
        errors::handle_error "CONFIG_ERROR" "Application '$app_key' missing 'type' field." "$app_display_name"
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"phase\": \"config_validation\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"Application missing 'type' field.\"}"
        interfaces::print_ui_line "  " "✗ " "Configuration error: Missing app type." "${COLOR_RED}"
        counters::inc_failed
        loggers::print_message ""
        return 1
    fi

    local app_check_status=0
    local handler_func="${UPDATE_HANDLERS[$app_type]}" # Recommendation 1: Plugin Architecture

    if [[ -n "$handler_func" ]]; then
        updates::trigger_hooks PRE_CHECK_HOOKS "$app_display_name" # Recommendation 10: Pre-check hook
        # Call the handler function directly, passing the nameref string
        # Original behavior: handler function executes, logs, and directly triggers process_* function
        "$handler_func" "_current_app_config" || app_check_status=1
        # No JSON capture/parsing here, as Recommendation 2 is NOT implemented.
        updates::trigger_hooks POST_CHECK_HOOKS "$app_display_name" # Recommendation 10: Post-check hook (no JSON details available)
    else
        errors::handle_error "CONFIG_ERROR" "Unknown update type '$app_type'" "$app_display_name"
        interfaces::print_ui_line "  " "✗ " "Configuration error: Unknown update type." "${COLOR_RED}"
        app_check_status=1
        updates::trigger_hooks ERROR_HOOKS "$app_display_name" "{\"error_type\": \"CONFIG_ERROR\", \"message\": \"Unknown app type: $app_type\"}" # Recommendation 10: Error hook
    fi

    if [[ "$app_check_status" -ne 0 ]]; then
        counters::inc_failed
    fi
    loggers::print_message "" # Blank line after each app block
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
        updates::check_application "$app_key" "$current_index" "$total_apps" || true
        ((current_index++))
    done
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
