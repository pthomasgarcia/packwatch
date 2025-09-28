#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/common.sh
# ==============================================================================
# Responsibilities:
#   - Generic functions used across multiple update types, primarily related to
#     the installation process and progress tracking.
# ==============================================================================

# Generic function to handle the common installation flow elements.
# This includes prompting the user, handling dry runs, and updating the installed version.
# Usage: updates::process_installation "app_name" "app_key" "latest_version" "install_command_func" "install_command_args..."
updates::process_installation() {
    local app_name="$1"
    local app_key="$2"
    local latest_version="$3"
    local install_command_func="$4"
    shift 4
    local -a install_command_args=("$@")

    local current_installed_version
    current_installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied
    # Normalize empty provider result to sentinel version
    if [[ -z "$current_installed_version" ]]; then
        current_installed_version="0.0.0"
    fi

    local prompt_msg
    prompt_msg="Do you want to install ${FORMAT_BOLD}${app_name}${FORMAT_RESET} v${latest_version}?"
    if [[ "$current_installed_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update ${FORMAT_BOLD}${app_name}${FORMAT_RESET} to v${latest_version}?"
    fi

    notifiers::send_notification "$app_name Update Available" "v$latest_version ready for install" "normal"

    if "$UPDATES_PROMPT_CONFIRM_IMPL" "$prompt_msg" "Y"; then # DI applied
        if ! updates::trigger_hooks PRE_INSTALL_HOOKS "$app_name"; then
            updates::on_install_skipped "$app_name" # Hook
            counters::inc_skipped
            return 0
        fi
        updates::on_install_start "$app_name"                 # Hook
        if ((${DRY_RUN:-0})); then
            loggers::debug "  [DRY RUN] Would execute installation command: '$install_command_func ${install_command_args[*]}'."
            # Do not mutate state during dry runs.
            interfaces::print_ui_line "  " "[DRY RUN] " "Installation simulated for ${FORMAT_BOLD}$app_name${FORMAT_RESET}." "${COLOR_YELLOW}"
            return 0
        fi

        if "$install_command_func" "${install_command_args[@]}"; then
            if ! "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"; then # DI applied
                loggers::warn "Failed to update installed version JSON for '$app_name', but installation was successful."
            fi
            updates::on_install_complete "$app_name" "$latest_version" # Hook (now includes version)
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
    local file_size="$2"                                                                            # Can be 'unknown' or actual size
    interfaces::print_ui_line "  " "→ " "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}..." >&2 # Redirect to stderr
    loggers::info "Starting download for $app_name (Size: $file_size)."
}

updates::on_download_progress() {
    local app_name="$1"
    local downloaded="$2"
    local total="$3"
    local percent=0
    local total_disp="unknown"
    local downloaded_disp="unknown"

    if [[ "$downloaded" =~ ^[0-9]+$ ]]; then
        downloaded_disp="$(_format_bytes "$downloaded")"
    fi
    if [[ "$total" =~ ^[0-9]+$ ]] && ((total > 0)); then
        total_disp="$(_format_bytes "$total")"
        if [[ "$downloaded" =~ ^[0-9]+$ ]]; then
            percent=$((downloaded * 100 / total))
            ((percent > 100)) && percent=100
        fi
    fi
    interfaces::print_ui_line "  " "⤓ " \
        "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}: ${percent}% (${downloaded_disp} / ${total_disp})" >&2
    # Note: Requires underlying networks::download_file to call this callback.
}
updates::on_download_complete() {
    local app_name="$1"
    local file_path="$2"
    interfaces::print_ui_line "  " "✓ " "Download for ${FORMAT_BOLD}$app_name${FORMAT_RESET} complete." "${COLOR_GREEN}" >&2 # Redirect to stderr
    loggers::info "Download complete for $app_name: $file_path"
}

updates::on_install_start() {
    local app_name="$1"
    interfaces::print_ui_line "  " "→ " "Preparing to install ${FORMAT_BOLD}$app_name${FORMAT_RESET}..." >&2 # Redirect to stderr
    loggers::info "Starting installation for $app_name."
}

updates::on_install_complete() {
    local app_name="$1"
    local latest_version="$2"
    interfaces::print_ui_line "  " "✓ " "${FORMAT_BOLD}$app_name${FORMAT_RESET} installed/updated successfully (v${latest_version})." "${COLOR_GREEN}" >&2
    loggers::info "Installation complete for $app_name (version ${latest_version})."
    notifiers::send_notification "${app_name} Updated" "Installed v${latest_version}." "normal"
}

updates::on_install_skipped() {
    local app_name="$1"
    interfaces::print_ui_line "  " "🞨 " "Installation for ${FORMAT_BOLD}$app_name${FORMAT_RESET} skipped." "${COLOR_YELLOW}" >&2 # Redirect to stderr
    loggers::info "Installation skipped for $app_name."
}

# Determine if an update is needed by comparing versions.
# Usage: updates::is_needed "current_version" "latest_version"
updates::is_needed() {
    local current_version="$1"
    local latest_version="$2"
    versions::is_newer "$latest_version" "$current_version"
}

# Handles the common "up to date" status display and counter increment.
# Prints standardized version information.
# Usage: updates::print_version_info "installed_version" "source" "latest_version"
updates::print_version_info() {
    local installed_version="$1"
    local source="$2"
    local latest_version="$3"

    interfaces::print_ui_line "  " "Installed: " "$installed_version"
    interfaces::print_ui_line "  " "Source:    " "$source"
    interfaces::print_ui_line "  " "Latest:    " "$latest_version"
}

updates::handle_up_to_date() {
    interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
    counters::inc_up_to_date
}




# Perform pre-installation checks for running processes.
# This function is intended to be used as a PRE_INSTALL_HOOK.
# It checks for running processes based on the 'binary_name' in the app's
# config and prompts the user to terminate them if found.
#
# Usage:
#   updates::pre_install_check_running_processes "app_name" "{}"
#
# Returns:
#   0 - If no processes are running, or if they were successfully terminated.
#   1 - If the user chooses not to terminate, or if termination fails. This
#       signals to the calling installer to skip the installation.
updates::pre_install_check_running_processes() {
    local app_name="$1"
    # The second argument (details_json) is ignored for this hook.

    declare -A app_config
    if ! configs::get_app_config "$app_name" "app_config"; then
        # If config fails to load, we can't check, so we must return success
        # to not block other installations. The config error is logged inside get_app_config.
        return 0
    fi

    local binary_name="${app_config[binary_name]:-}"
    local should_prompt="${app_config[prompt_to_kill_running_processes]:-false}"

    # If this feature is not enabled for the app, exit successfully.
    if [[ "$should_prompt" != "true" || -z "$binary_name" ]]; then
        return 0
    fi

    # Construct the likely full path of the binary. This is an assumption but
    # covers the most common installation scenario. A more robust solution
    # might involve storing the full path at install time.
    local binary_path="/usr/local/bin/${binary_name}"

    local pids
    if ! pids=$(systems::is_file_in_use "$binary_path"); then
        # No processes found, so we can proceed.
        return 0
    fi

    interfaces::print_ui_line "  " "!" "The application '$app_name' appears to be running." "${COLOR_YELLOW}"
    interfaces::print_ui_line "  " " " "Running processes must be closed to prevent a 'Text file busy' error."
    interfaces::print_ui_line "  " " " "Detected PIDs: $pids"

    if interfaces::confirm_prompt "Do you want to automatically terminate these processes?"; then
        if systems::kill_processes_by_file_path "$binary_path" "$app_name"; then
            interfaces::print_ui_line "  " "✓" "Processes terminated." "${COLOR_GREEN}"
            return 0 # Success, installation can continue.
        else
            errors::handle_error "SYSTEM_ERROR" "Failed to terminate all processes for '$app_name'. Please close them manually." "$app_name"
            return 1 # Failure, skip installation.
        fi
    else
        loggers::info "User chose not to terminate running processes for '$app_name'."
        return 1 # User declined, skip installation.
    fi
}
