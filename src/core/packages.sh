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
#     packages::fetch_version "AppKey"
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
        loggers::debug "Installed versions file not found: '$versions_file'. \
Assuming app not installed."
        echo "0.0.0"
        return 0
    fi

    local version
    version=$(systems::fetch_json "$(cat "$versions_file")" ".\"$app_key\"" "$app_key")

    if [[ -z "$version" ]]; then
        loggers::debug "No installed version found for app: '$app_key'"
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

    loggers::debug "Updating installed version for '$app_key' to '$new_version' in '$versions_file'"

    mkdir -p "$(dirname "$versions_file")" || {
        errors::handle_error "PERMISSION_ERROR" \
            "Failed to create directory for versions file: \
'$(dirname "$versions_file")'"
        return 1
    }

    if [[ ! -f "$versions_file" ]]; then
        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to initialize versions file: '$versions_file'"
            return 1
        }
    fi

    local temp_versions_file
    if ! temp_versions_file=$(systems::create_temp_file "versions_update"); then
        return 1
    fi

    if jq --arg key "$app_key" --arg version "$new_version" '.[$key] = $version' "$versions_file" > "$temp_versions_file"; then
        if mv "$temp_versions_file" "$versions_file"; then
            systems::unregister_temp_file "$temp_versions_file"
            if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &> /dev/null; then
                sudo chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$versions_file" 2> /dev/null ||
                    loggers::warn "Failed to change ownership of '$versions_file' \
to '$ORIGINAL_USER'."
            fi
            return 0
        else
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to move updated versions file from \
'$temp_versions_file' to '$versions_file'"
            return 1
        fi
    else
        errors::handle_error "VALIDATION_ERROR" \
            "Failed to update JSON for app '$app_key' with version \
'$new_version'"
        return 1
    fi
}

# Initialize the installed versions JSON file if it doesn't exist.
# Usage: packages::initialize_installed_versions_file
packages::initialize_installed_versions_file() {
    local versions_file="$CONFIG_ROOT/installed_versions.json"

    if [[ ! -f "$versions_file" ]]; then
        loggers::info "Initializing installed versions file: '$versions_file'"
        mkdir -p "$(dirname "$versions_file")" || {
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to create directory for versions file"
            return 1
        }

        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to create versions file: '$versions_file'"
            return 1
        }
    fi
    return 0
}

# Get the installed version of an application from centralized JSON.
# Usage: packages::fetch_version "AppKey"
packages::fetch_version() {
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
    # Cache basename to avoid repeated subshell invocations
    local deb_basename
    deb_basename="$(basename "$deb_file")"

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" \
            "DEB file not found: '$deb_file'"
        return 1
    fi

    version=$(dpkg-deb -f "$deb_file" Version 2> /dev/null)

    # Fallback: attempt to parse version from filename using canonical sentinel pattern
    if [[ -z "$version" ]]; then
        # versions::extract_from_regex expects (text_data, pattern-key/sentinel, app_name)
        # Passing literal "FILENAME_REGEX" triggers substitution with
        # $VERSION_FILENAME_REGEX internally.
        version=$(versions::extract_from_regex "$deb_basename" "FILENAME_REGEX" "$deb_basename")
    fi

    echo "${version:-0.0.0}"
}

# --------------------------------------------------------------------
# Public: perform basic sanity check on a Debian package file.
# Usage: packages::verify_deb_sanity "/tmp/file.deb" "AppName"
# Returns 0 on success, 1 on failure.
# --------------------------------------------------------------------
packages::verify_deb_sanity() {
    local deb_file="$1"
    local app_name="$2"

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" \
            "DEB file not found for sanity check: '$deb_file'" "$app_name"
        return 1
    fi

    if ! dpkg-deb --info "$deb_file" &> /dev/null; then
        errors::handle_error "VALIDATION_ERROR" \
            "Downloaded file is not a valid Debian package: '$deb_file'" \
            "$app_name"
        return 1
    fi

    loggers::info \
        "Sanity check passed: $deb_file is a valid .deb"
    return 0
}

# Install a Debian package.
# Usage: packages::install_deb_package "/tmp/file.deb" "AppName" "1.2.3" "AppKey"
packages::install_deb_package() {
    local deb_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"

    if [[ -z "$deb_file" ]] || [[ -z "$app_name" ]] || [[ -z "$version" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" \
            "Missing required parameters for DEB installation"
        return 1
    fi

    # The file existence check is now handled by packages::verify_deb_sanity
    # if [[ ! -f "$deb_file" ]]; then
    #     errors::handle_error "VALIDATION_ERROR" "DEB file not found: '$deb_file'" "$app_name"
    #     return 1
    # fi

    interfaces::print_ui_line "  " "→ " \
        "Attempting to install ${FORMAT_BOLD}$app_name${FORMAT_RESET} v$version..." \
        >&2

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        interfaces::print_ui_line "    " "[DRY RUN] " \
            "Would install v$version from: '$deb_file'" "${COLOR_YELLOW}" >&2
        packages::update_installed_version_json "$app_key" "$version"
        return 0
    fi

    if ! systems::ensure_sudo_privileges "$app_name"; then
        return 1
    fi

    local install_output
    if ! install_output=$(sudo apt install -y "$deb_file" 2>&1); then
        errors::handle_error "INSTALLATION_ERROR" "Package installation failed for '$app_name'."

        if [[ "$app_name" == "VeraCrypt" ]] &&
            echo "$install_output" | grep -q \
                "VeraCrypt volumes must be dismounted"; then
            errors::handle_error "PERMISSION_ERROR" \
                "VeraCrypt volumes must be dismounted to perform this update" \
                "$app_name"
        else
            loggers::info "See apt output below for details:"
            echo "$install_output" >&2
        fi

        return 1
    fi

    return 0
}
# Install a TGZ archive.
# Usage: packages::install_tgz_package "/path/to/file.tgz" "AppName" "1.2.3" "AppKey" "binary_name" "install_strategy"
packages::install_tgz_package() {
    local tgz_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"
    local binary_name="$5"
    local install_strategy="$6" # New parameter for installation strategy

    interfaces::print_ui_line "  " "→ " \
        "Attempting to install ${FORMAT_BOLD}$app_name${FORMAT_RESET} v$version..." \
        >&2

    local install_dir="/usr/local" # Base install directory
    local temp_extract_dir=""      # Initialize to empty string
    if ! temp_extract_dir=$(mktemp -d -p "${HOME}/.cache/packwatch/tmp"); then
        errors::handle_error "SYSTEM_ERROR" "Failed to create temporary directory for '$app_name'." "$app_name"
        return 1
    fi

    if ! tar -xzf "$tgz_file" -C "$temp_extract_dir"; then
        errors::handle_error "INSTALLATION_ERROR" \
            "Failed to extract TGZ archive for '$app_name'." "$app_name"
        return 1
    fi

    if ! systems::ensure_sudo_privileges "$app_name"; then
        return 1
    fi

    case "$install_strategy" in
        "move_binary")
            local binary_path
            # Find only the first matching file to avoid mv ambiguity
            local binary_path=""
            while IFS= read -r -d '' file; do
                binary_path="$file"
                break
            done < <(find "$temp_extract_dir" -type f -name "$binary_name" -print0)
            if [[ -z "$binary_path" ]]; then
                errors::handle_error "INSTALLATION_ERROR" \
                    "Could not find executable '$binary_name' in extracted archive \
for '$app_name'." "$app_name"
                return 1
            fi

            if ! sudo mv "$binary_path" "${install_dir}/bin/${binary_name}"; then
                errors::handle_error "INSTALLATION_ERROR" \
                    "Failed to move binary for '$app_name'." "$app_name"
                return 1
            fi

            if ! sudo chmod +x "${install_dir}/bin/${binary_name}"; then
                errors::handle_error "PERMISSION_ERROR" \
                    "Failed to make binary executable for '$app_name'." "$app_name"
                return 1
            fi
            ;;
        "copy_root_contents")
            local extracted_root_dir
            # Find the top-level directory created by tar (e.g., nvim-linux-x86_64)
            local extracted_root_dir=""
            while IFS= read -r -d '' dir; do
                extracted_root_dir="$dir"
                break
            done < <(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type d -print0)
            if [[ -z "$extracted_root_dir" ]]; then
                errors::handle_error "INSTALLATION_ERROR" \
                    "Could not find extracted root directory in '$temp_extract_dir' for '$app_name'." "$app_name"
                return 1
            fi

            # Copy the contents of the extracted directory to /usr/local/
            if ! sudo cp -r "${extracted_root_dir}/"* "${install_dir}/"; then
                errors::handle_error "INSTALLATION_ERROR" \
                    "Failed to copy extracted files to '${install_dir}' for '$app_name'." "$app_name"
                return 1
            fi

            # Ensure the main binary is executable (assuming it's in /usr/local/bin)
            if [[ -n "$binary_name" ]] && [[ -f "${install_dir}/bin/${binary_name}" ]]; then
                if ! sudo chmod +x "${install_dir}/bin/${binary_name}"; then
                    errors::handle_error "PERMISSION_ERROR" \
                        "Failed to make binary executable for '$app_name'." "$app_name"
                    return 1
                fi
            fi
            ;;
        *)
            errors::handle_error "INSTALLATION_ERROR" \
                "Unknown installation strategy '$install_strategy' for '$app_name'." "$app_name"
            return 1
            ;;
    esac

    # Explicit cleanup (trap also serves as safeguard)
    [[ -d "$temp_extract_dir" ]] && rm -rf "$temp_extract_dir"
    # The generic process_installation function handles the version update
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Package Processing
# ------------------------------------------------------------------------------

packages::process_deb_package() {
    local config_ref_name="$1"
    # local deb_filename_template="$2" # This variable is unused
    local latest_version="$3"
    local download_url="$4"
    local expected_checksum="${5:-}"
    local app_name="$6"
    local -n app_config_ref=$config_ref_name
    local app_key="${app_config_ref[app_key]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}"

    local version
    version=$(echo "$download_url" | grep -oP '\d+\.\d+\.\d+' | head -n1)
    local artifact_cache_dir="${HOME}/.cache/packwatch/artifacts/${app_name}/v${version}"
    mkdir -p "$artifact_cache_dir"
    local base_filename
    base_filename=$(basename "$download_url" | cut -d'?' -f1)
    local final_deb_path="${artifact_cache_dir}/${base_filename}"

    if [[ ! -f "$final_deb_path" ]]; then
        loggers::info "Artifact not found in cache. Downloading..."
        updates::on_download_start "$app_name" "unknown"
        if ! networks::download_file "$download_url" "$final_deb_path" "" \
            "" "$allow_http"; then
            errors::handle_error "NETWORK_ERROR" \
                "Failed to download DEB package" "$app_name"
            updates::trigger_hooks ERROR_HOOKS "$app_name" \
                "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \
\"message\": \"Failed to download DEB package.\"}"
            return 1
        fi
        updates::on_download_complete "$app_name" "$final_deb_path"
    else
        loggers::info "Using cached artifact: $final_deb_path"
    fi

    # Perform deb sanity check before full verification
    if ! packages::verify_deb_sanity "$final_deb_path" "$app_name"; then
        return 1
    fi

    if ! verifiers::verify_artifact "$config_ref_name" "$final_deb_path" \
        "$download_url" "$expected_checksum"; then
        errors::handle_error "VALIDATION_ERROR" \
            "Verification failed for downloaded DEB package: '$app_name'." \
            "$app_name"
        return 1
    fi

    packages::install_deb_package "$final_deb_path" "$app_name" "$latest_version" "$app_key"
}

packages::process_tgz_package() {
    local config_ref_name="$1"
    local filename_template="$2"
    local latest_version="$3"
    local download_url="$4"
    local expected_checksum="$5"
    local app_name="$6"
    local app_key="$7"
    local binary_name="$8"

    local -n app_config_ref=$config_ref_name
    local allow_http="${app_config_ref[allow_insecure_http]:-0}"
    local install_strategy="${app_config_ref[install_strategy]:-move_binary}" # Get strategy from config

    local artifact_cache_dir="${HOME}/.cache/packwatch/artifacts/${app_name}/v${latest_version}"
    mkdir -p "$artifact_cache_dir"
    local base_filename
    # shellcheck disable=SC2059 # The template is a trusted config value.
    base_filename=$(printf "$filename_template" "$latest_version")
    local cached_artifact_path="${artifact_cache_dir}/${base_filename}"

    if [[ ! -f "$cached_artifact_path" ]]; then
        loggers::info "Artifact not found in cache. Downloading..."
        if ! networks::download_file "$download_url" "$cached_artifact_path" \
            "" "" "$allow_http" 600; then
            errors::handle_error "NETWORK_ERROR" \
                "Failed to download TGZ archive for '$app_name'." "$app_name"
            return 1
        fi
    else
        loggers::info "Using cached artifact: $cached_artifact_path"
    fi

    if ! verifiers::verify_artifact "$config_ref_name" "$cached_artifact_path" \
        "$download_url" "$expected_checksum"; then
        errors::handle_error "VALIDATION_ERROR" \
            "Checksum verification failed for '$app_name'." "$app_name"
        return 1
    fi

    packages::install_tgz_package "$cached_artifact_path" "$app_name" "$latest_version" "$app_key" "$binary_name" "$install_strategy"
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
