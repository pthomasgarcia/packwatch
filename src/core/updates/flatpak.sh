#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/flatpak.sh
# ==============================================================================
# Responsibilities:
#   - Deals with Flatpak application checks and updates.
# ==============================================================================

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

    if ! command -v flatpak &> /dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "Flatpak is not installed. Cannot update $app_name." "$app_name"
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"DEPENDENCY_ERROR\", \"message\": \"Flatpak is not installed.\"}"
        interfaces::print_ui_line "  " "✗ " "Flatpak not installed. Cannot update ${FORMAT_BOLD}$app_name${FORMAT_RESET}." "${COLOR_RED}"
        return 1
    fi

    # Use the generic process_installation function, passing the new helper for installation
    updates::process_installation \
        "$app_name" \
        "$app_key" \
        "$latest_version" \
        "updates::_perform_flatpak_installation" \
        "$app_name" \
        "$flatpak_app_id"
}

# Helper function to perform the actual Flatpak installation, including sudo setup.
# Usage: updates::_perform_flatpak_installation "app_name" "flatpak_app_id"
# shellcheck disable=SC2317
updates::_perform_flatpak_installation() {
    local app_name="$1"
    local flatpak_app_id="$2"

    if ! systems::ensure_sudo_privileges "$app_name"; then
        return 1
    fi

    # Ensure Flathub remote exists
    if ! flatpak remotes --columns=name | grep -qx flathub; then
        interfaces::print_ui_line "  " "→ " "Adding Flathub remote..."
        sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || {
            errors::handle_error "INSTALLATION_ERROR" "Failed to add Flathub remote. Cannot update $app_name." "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Failed to add Flathub remote.\"}"
            interfaces::print_ui_line "  " "✗ " "Failed to add Flathub remote." "${COLOR_RED}"
            return 1
        }
    fi

    # Update appstream data
    # Update appstream data (quietly)
    interfaces::print_ui_line "  " "→ " "Updating Flatpak appstream data..."
    if ! sudo flatpak update --appstream -y > /dev/null 2>&1; then
        interfaces::log_warn "Failed to update Flatpak appstream data. Installation might proceed but information could be stale."
    fi

    # Perform installation or update in a single sudo session
    # Redirect output to void unless in verbose mode to prevent noise
    local install_cmd="flatpak install --or-update -y flathub '$flatpak_app_id'"

    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        if ! sudo bash -c "$install_cmd"; then
            handle_flatpak_error "$app_name"
            return 1
        fi
    else
        if ! sudo bash -c "$install_cmd" > /dev/null 2>&1; then
            handle_flatpak_error "$app_name"
            return 1
        fi
    fi
}

handle_flatpak_error() {
    local app_name="$1"
    errors::handle_error "INSTALLATION_ERROR" "Failed to install Flatpak app $app_name." "$app_name"
    updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\", \"message\": \"Failed to install Flatpak app.\"}"
    interfaces::print_ui_line "  " "✗ " "Failed to install Flatpak app." "${COLOR_RED}"
}

# Updates module; checks for updates for a Flatpak application.
updates::check_flatpak() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local flatpak_app_id="${app_config_ref[flatpak_app_id]}"
    local source="Flathub"

    if ! command -v flatpak &> /dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "Flatpak is not installed. Cannot check $name." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"DEPENDENCY_ERROR\", \"message\": \"Flatpak is not installed.\"}"
        interfaces::print_ui_line "  " "✗ " "Flatpak not installed. Cannot check ${FORMAT_BOLD}$name${FORMAT_RESET}." "${COLOR_RED}"
        return 1
    fi

    interfaces::print_ui_line "  " "→ " "Checking Flatpak for ${FORMAT_BOLD}$name${FORMAT_RESET}..."

    local latest_version="0.0.0"
    local flatpak_search_output
    if flatpak_search_output=$("$UPDATES_FLATPAK_SEARCH_IMPL" --columns=application,version,summary "$flatpak_app_id" 2> /dev/null); then # DI applied
        if [[ "$flatpak_search_output" =~ "$flatpak_app_id"[[:space:]]+([^[:space:]]+) ]]; then
            latest_version=$(versions::normalize "${BASH_REMATCH[1]}")
        else
            loggers::warn "Could not parse Flatpak version for '$name' from search output."
        fi
    else
        errors::handle_error "NETWORK_ERROR" "Failed to search Flatpak remote for '$name'." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"check\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to search Flatpak remote.\"}"
        interfaces::print_ui_line "  " "✗ " "Failed to search Flatpak remote for '$name'. Cannot determine latest version." "${COLOR_RED}"
        return 1
    fi

    local installed_version
    installed_version=$("$UPDATES_GET_INSTALLED_VERSION_IMPL" "$app_key") # DI applied

    updates::print_version_info "$installed_version" "$source" "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        interfaces::print_ui_line "  " "⬆ " "New version available: $latest_version" "${COLOR_YELLOW}"
        updates::process_flatpak_app \
            "$name" \
            "$app_key" \
            "$latest_version" \
            "$flatpak_app_id"
    else
        updates::handle_up_to_date
    fi

    return 0
}
