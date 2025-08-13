#!/usr/bin/env bash
# ==============================================================================
# MODULE: updater_utils.sh
# ==============================================================================
# Responsibilities:
#   - Provide shared helper functions for the update process, particularly for
#     scenarios that require downloading a file to determine its version.
#
# Dependencies:
#   - systems.sh
#   - networks.sh
#   - verifiers.sh
#   - versions.sh
#   - errors.sh
#   - updates.sh (for hooks)
# ==============================================================================

# --- DI IMPORTS (from updates.sh) ---
# Ensure these are set in the calling environment (updates.sh)
: "${UPDATES_DOWNLOAD_FILE_IMPL:?UPDATES_DOWNLOAD_FILE_IMPL is not set.}"

# ==============================================================================
# FUNCTION: updater_utils::check_and_get_version_from_download
# ==============================================================================
# Description:
#   A generic helper to encapsulate the "download-first-then-compare" logic.
#   It downloads a file, verifies it, and extracts a version number from it.
#
# Parameters:
#   $1 (nameref) - A reference to the application's configuration array.
#   $2 (string)  - The name of the function to call to extract the version
#                  from the downloaded file (e.g., 'packages::extract_deb_version').
#   $3 (nameref) - A reference to a variable in the calling scope where the
#                  extracted version number will be stored.
#   $4 (nameref) - A reference to a variable in the calling scope where the
#                  path to the downloaded temporary file will be stored.
#
# Returns:
#   0 on success, non-zero on failure.
#   Populates the output variables referenced by $3 and $4.
# ==============================================================================
updater_utils::check_and_get_version_from_download() {
    local -n app_config_ref=$1
    local version_extractor_func="$2"
    local -n out_version_var=$3
    local -n out_temp_file_var=$4

    local name="${app_config_ref[name]}"
    local download_url="${app_config_ref[download_url]}"
    local allow_http="${app_config_ref[allow_insecure_http]:-0}"

    # 1. Create Temporary File
    local temp_download_file
    local base_filename
    base_filename="$(basename "$download_url" | cut -d'?' -f1)"
    base_filename=$(systems::sanitize_filename "$base_filename")
    if ! temp_download_file=$(systems::create_temp_file "${base_filename}"); then
        errors::handle_error "SYSTEM_ERROR" "Failed to create temp file for '$name'." "$name"
        return 1
    fi

    # 2. Download
    updates::on_download_start "$name" "unknown"
    if ! "$UPDATES_DOWNLOAD_FILE_IMPL" "$download_url" "$temp_download_file" "" "" "$allow_http"; then
        errors::handle_error "NETWORK_ERROR" "Failed to download package for '$name'." "$name"
        updates::trigger_hooks ERROR_HOOKS "$name" "{\"phase\": \"download\", \"error_type\": \"NETWORK_ERROR\", \"message\": \"Failed to download package.\"}"
        return 1
    fi
    updates::on_download_complete "$name" "$temp_download_file"

    # 3. Verification
    if ! verifiers::verify_artifact app_config_ref "$temp_download_file" "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Verification failed for downloaded package: '$name'." "$name"
        return 1
    fi

    # 4. Version Extraction
    local extracted_version
    if ! extracted_version=$("$version_extractor_func" "$temp_download_file"); then
        errors::handle_error "PARSING_ERROR" "Failed to extract version from downloaded file for '$name'." "$name"
        return 1
    fi

    local normalized_version
    normalized_version=$(versions::normalize "$extracted_version")

    if [[ "$normalized_version" == "0.0.0" ]]; then
        interfaces::print_ui_line "  " "! " "Failed to extract a valid version from the downloaded package for '$name'." "${COLOR_YELLOW}"
    fi

    # 5. Output
    out_version_var="$normalized_version"
    out_temp_file_var="$temp_download_file"

    return 0
}
