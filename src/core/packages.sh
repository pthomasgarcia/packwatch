#!/usr/bin/env bash
# ==============================================================================
# MODULE: packages.sh
# ==============================================================================
# Responsibilities:
#   - Installed version tracking and package installation
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/packages.sh"
#
#   Then use:
#     packages::get_installed_version "AppKey"
#     packages::update_installed_version_json "AppKey" "1.2.3"
#     packages::install_deb_package "/tmp/file.deb" "AppName" "1.2.3" "AppKey"
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - notifiers.sh
#   - systems.sh
#   - interfaces.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Installed Versions File Path
# ------------------------------------------------------------------------------

# Set this in your main script or config:
#   CONFIG_ROOT="/path/to/config"
#   versions_file="$CONFIG_ROOT/installed_versions.json"

# ------------------------------------------------------------------------------
# SECTION: Installed Version Management
# ------------------------------------------------------------------------------

# Get the installed version from the centralized JSON file.
# Usage: packages::get_installed_version_from_json "AppKey"
packages::get_installed_version_from_json() {
    local app_key="$1"
    local versions_file="$CONFIG_ROOT/installed_versions.json"

    if [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "App key is empty"
        return 1
    fi

    if [[ ! -f "$versions_file" ]]; then
        loggers::log_message "DEBUG" "Installed versions file not found: '$versions_file'. Assuming app not installed."
        echo "0.0.0"
        return 0
    fi

    local version
    version=$(systems::get_json_value "$(cat "$versions_file")" ".\"$app_key\"" "$app_key")

    if [[ -z "$version" ]]; then
        loggers::log_message "DEBUG" "Failed to parse installed versions JSON file for app: '$app_key'"
        echo "0.0.0"
        return 0
    fi

    if [[ -z "$version" ]]; then
        loggers::log_message "DEBUG" "No installed version found for app: '$app_key'"
        echo "0.0.0"
        return 0
    fi

    echo "$version"
    return 0
}

# Update the installed version in the centralized JSON file.
# Usage: packages::update_installed_version_json "AppKey" "1.2.3"
packages::update_installed_version_json() {
    local app_key="$1"
    local new_version="$2"
    local versions_file="$CONFIG_ROOT/installed_versions.json"

    if [[ -z "$app_key" ]] || [[ -z "$new_version" ]]; then
        errors::handle_error "VALIDATION_ERROR" "App key or version is empty for JSON update"
        return 1
    fi

    loggers::log_message "DEBUG" "Updating installed version for '$app_key' to '$new_version' in '$versions_file'"

    mkdir -p "$(dirname "$versions_file")" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create directory for versions file: '$(dirname "$versions_file")'"
        return 1
    }

    if [[ ! -f "$versions_file" ]]; then
        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to initialize versions file: '$versions_file'"
            return 1
        }
    fi

    local temp_versions_file
    temp_versions_file=$(systems::create_temp_file "versions_update")
    if ! temp_versions_file=$(systems::create_temp_file "versions_update"); then return 1; fi

    if jq --arg key "$app_key" --arg version "$new_version" '.[$key] = $version' "$versions_file" > "$temp_versions_file"; then
        if mv "$temp_versions_file" "$versions_file"; then
            systems::unregister_temp_file "$temp_versions_file"
            if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &> /dev/null; then
                sudo chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$versions_file" 2> /dev/null ||
                    loggers::log_message "WARN" "Failed to change ownership of '$versions_file' to '$ORIGINAL_USER'."
            fi
            return 0
        else
            errors::handle_error "PERMISSION_ERROR" "Failed to move updated versions file from '$temp_versions_file' to '$versions_file'"
            return 1
        fi
    else
        errors::handle_error "VALIDATION_ERROR" "Failed to update JSON for app '$app_key' with version '$new_version'"
        return 1
    fi
}

# Initialize the installed versions JSON file if it doesn't exist.
# Usage: packages::initialize_installed_versions_file
packages::initialize_installed_versions_file() {
    local versions_file="$CONFIG_ROOT/installed_versions.json"

    if [[ ! -f "$versions_file" ]]; then
        loggers::log_message "INFO" "Initializing installed versions file: '$versions_file'"
        mkdir -p "$(dirname "$versions_file")" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to create directory for versions file"
            return 1
        }

        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to create versions file: '$versions_file'"
            return 1
        }
    fi
    return 0
}

# Get the installed version of an application from centralized JSON.
# Usage: packages::get_installed_version "AppKey"
packages::get_installed_version() {
    local app_key="$1"
    packages::get_installed_version_from_json "$app_key"
}

# ------------------------------------------------------------------------------
# SECTION: DEB Package Helpers
# ------------------------------------------------------------------------------

# Extract the version from a Debian package file.
# Usage: packages::extract_deb_version "/tmp/file.deb"
packages::extract_deb_version() {
    local deb_file="$1"
    local version=""

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "DEB file not found: '$deb_file'"
        return 1
    fi

    version=$(dpkg-deb -f "$deb_file" Version 2> /dev/null)

    if [[ -z "$version" ]]; then
        version=$(versions::extract_from_regex "$(basename "$deb_file")" '^[0-9]+([.-][0-9a-zA-Z]+)*(-[0-9a-zA-Z.-]+)?(\+[0-9a-zA-Z.-]+)?' "$(basename "$deb_file")")
    fi

    echo "${version:-0.0.0}"
}

# Install a Debian package.
# Usage: packages::install_deb_package "/tmp/file.deb" "AppName" "1.2.3" "AppKey"
packages::install_deb_package() {
    local deb_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"

    if [[ -z "$deb_file" ]] || [[ -z "$app_name" ]] || [[ -z "$version" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Missing required parameters for DEB installation"
        return 1
    fi

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "DEB file not found: '$deb_file'" "$app_name"
        return 1
    fi

    interfaces::print_ui_line "  " "→ " "Attempting to install ${FORMAT_BOLD}$app_name${FORMAT_RESET} v$version..." >&2

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        interfaces::print_ui_line "    " "[DRY RUN] " "Would install v$version from: '$deb_file'" "${COLOR_YELLOW}" >&2
        packages::update_installed_version_json "$app_key" "$version"
        return 0
    fi

    if ! command -v sudo &> /dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "sudo command not found. Installation requires sudo privileges." "$app_name"
        return 1
    fi

    local install_output
    if ! install_output=$(sudo apt install -y "$deb_file" 2>&1); then
        errors::handle_error "INSTALLATION_ERROR" "Package installation failed for '$app_name'."

        if [[ "$app_name" == "VeraCrypt" ]] && echo "$install_output" | grep -q "VeraCrypt volumes must be dismounted"; then
            errors::handle_error "PERMISSION_ERROR" "VeraCrypt volumes must be dismounted to perform this update" "$app_name"
        else
            loggers::log_message "INFO" "See apt output below for details:"
            echo "$install_output" >&2
        fi

        return 1
    fi

    if ! packages::update_installed_version_json "$app_key" "$version"; then
        loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but installation was successful."
    fi

    interfaces::print_ui_line "  " "✓ " "Successfully installed ${FORMAT_BOLD}$app_name${FORMAT_RESET} v$version" "${COLOR_GREEN}" >&2
    notifiers::send_notification "$app_name Updated" "Successfully installed v$version" "normal"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
