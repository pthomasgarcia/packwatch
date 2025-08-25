#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/common.sh
# ==============================================================================
# Responsibilities:
#   - Generic functions used across multiple update types, primarily related to
#     the installation process and progress tracking.
# ==============================================================================

# shellcheck source=src/lib/progress.sh
: "${LIB_DIR:?LIB_DIR must be set before sourcing progress.sh}"
source "$LIB_DIR/progress.sh"
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
    prompt_msg="Do you want to install ${FORMAT_BOLD}$app_name${FORMAT_RESET} v${latest_version}?"
    if [[ "$current_installed_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update ${FORMAT_BOLD}$app_name${FORMAT_RESET} to v${latest_version}?"
    fi

    notifiers::send_notification "$app_name Update Available" "v$latest_version ready for install" "normal"

    if "$UPDATES_PROMPT_CONFIRM_IMPL" "$prompt_msg" "Y"; then # DI applied
        updates::trigger_hooks PRE_INSTALL_HOOKS "$app_name"  # Pre-install hook (deferred until user confirms)
        updates::on_install_start "$app_name"                 # Hook
        if ((${DRY_RUN:-0})); then
            loggers::log_message "DEBUG" "  [DRY RUN] Would execute installation command: '$install_command_func ${install_command_args[*]}'."
            # Do not mutate state during dry runs.
            interfaces::print_ui_line "  " "[DRY RUN] " "Installation simulated for ${FORMAT_BOLD}$app_name${FORMAT_RESET}." "${COLOR_YELLOW}"
            return 0
        fi

        # Check for active sudo session before a sudo command (match by basename to allow full paths/wrappers)
        local _install_cmd_basename="${install_command_func##*/}"
        if [[ "$_install_cmd_basename" == "sudo" ]] && systems::is_sudo_session_active; then
            interfaces::print_ui_line "  " "→ " "An active sudo session was found. Installing without a password prompt."
        fi

        if "$install_command_func" "${install_command_args[@]}"; then
            if ! "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"; then # DI applied
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but installation was successful."
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

# Placeholder functions for download/install progress.
updates::on_download_start() {
    local app_name="$1"
    local file_size="$2"                                                                            # Can be 'unknown' or actual size
    interfaces::print_ui_line "  " "→ " "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}..." >&2 # Redirect to stderr
    loggers::log_message "INFO" "Starting download for $app_name (Size: $file_size)."
}

updates::on_download_progress() {
    local app_name="$1"
    local downloaded="$2"
    local total="$3"
    # Call the new progress bar rendering function
    progress::render_bar "$app_name" "$downloaded" "$total"
}

updates::on_download_complete() {
    local app_name="$1"
    local file_path="$2"
    progress::clear_line                                                                                                     # Clear the progress line before printing completion message
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
    local latest_version="$2"
    interfaces::print_ui_line "  " "✓ " "${FORMAT_BOLD}$app_name${FORMAT_RESET} installed/updated successfully (v${latest_version})." "${COLOR_GREEN}" >&2
    loggers::log_message "INFO" "Installation complete for $app_name (version ${latest_version})."
    notifiers::send_notification "${app_name} Updated" "Installed v${latest_version}." "normal"
}

updates::on_install_skipped() {
    local app_name="$1"
    interfaces::print_ui_line "  " "🞨 " "Installation for ${FORMAT_BOLD}$app_name${FORMAT_RESET} skipped." "${COLOR_YELLOW}" >&2 # Redirect to stderr
    loggers::log_message "INFO" "Installation skipped for $app_name."
}

# Determine if an update is needed by comparing versions.
# Usage: updates::is_needed "current_version" "latest_version"
updates::is_needed() {
    local current_version="$1"
    local latest_version="$2"
    versions::is_newer "$latest_version" "$current_version"
}

# Handles the common "up to date" status display and counter increment.
updates::handle_up_to_date() {
    interfaces::print_ui_line "  " "✓ " "Up to date." "${COLOR_GREEN}"
    counters::inc_up_to_date
}
