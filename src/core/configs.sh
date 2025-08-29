#!/usr/bin/env bash
# ==============================================================================
# MODULE: configs.sh
# ==============================================================================
# Responsibilities:
#   - Config schema loading, validation, and merging
#   - Validation of loaded application count
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/configs.sh"
#
#   Then use:
#     configs::load_modular_directory
#     configs::create_default_files
#     configs::validate_loaded_app_count
#
# Dependencies:
#   - errors.sh
#   - loggers.sh
#   - systems.sh
#   - validators.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Globals for Config Management
# ------------------------------------------------------------------------------

# These should be set in your main script or config:
#   CONFIG_ROOT="/path/to/config"
#   CONFIG_DIR="$CONFIG_ROOT/conf.d"
#   declare -A CONFIG_SCHEMA
#   declare -A ALL_APP_CONFIGS
#   declare -a CUSTOM_APP_KEYS

# This is no longer used with the new JSON Schema validation
# declare -A CONFIG_SCHEMA
declare -A ALL_APP_CONFIGS
declare -a CUSTOM_APP_KEYS

# Global network configuration settings
declare -g CACHE_DIR
declare -g CACHE_DURATION
declare -A -g NETWORK_CONFIG # -g makes it global, -A makes it associative

# Helper to set default network settings
configs::_set_default_network_settings() {
    CACHE_DIR="${HOME}/.cache/packwatch/cache"
    CACHE_DURATION=300
    NETWORK_CONFIG["MAX_RETRIES"]=3
    NETWORK_CONFIG["TIMEOUT"]=30
    NETWORK_CONFIG["USER_AGENT"]="Packwatch/1.0"
    NETWORK_CONFIG["RATE_LIMIT"]=1
    NETWORK_CONFIG["RETRY_DELAY"]=2
}

# Apply environment variable overrides (if present)
# ENV → JSON → defaults
configs::_apply_env_overrides() {
    # Scalars
    [[ -n "${PACKWATCH_CACHE_DIR:-}" ]] && CACHE_DIR="$PACKWATCH_CACHE_DIR"
    [[ -n "${PACKWATCH_CACHE_DURATION:-}" ]] && CACHE_DURATION="$PACKWATCH_CACHE_DURATION"

    # Map entries
    [[ -n "${PACKWATCH_MAX_RETRIES:-}" ]] && NETWORK_CONFIG["MAX_RETRIES"]="$PACKWATCH_MAX_RETRIES"
    [[ -n "${PACKWATCH_TIMEOUT:-}" ]] && NETWORK_CONFIG["TIMEOUT"]="$PACKWATCH_TIMEOUT"
    [[ -n "${PACKWATCH_USER_AGENT:-}" ]] && NETWORK_CONFIG["USER_AGENT"]="$PACKWATCH_USER_AGENT"
    [[ -n "${PACKWATCH_RATE_LIMIT:-}" ]] && NETWORK_CONFIG["RATE_LIMIT"]="$PACKWATCH_RATE_LIMIT"
    [[ -n "${PACKWATCH_RETRY_DELAY:-}" ]] && NETWORK_CONFIG["RETRY_DELAY"]="$PACKWATCH_RETRY_DELAY"
}

# Load global network settings from a dedicated JSON file.
# Usage: configs::load_network_settings "$CONFIG_ROOT/network_settings.json"
configs::load_network_settings() {
    local network_settings_file="$1"

    # Start with hardcoded fallbacks
    configs::_set_default_network_settings

    # Overlay JSON if present and valid
    if [[ -f "$network_settings_file" ]]; then
        local settings_content
        settings_content=$(< "$network_settings_file")

        if ! jq -e . "$network_settings_file" > /dev/null 2>&1; then
            errors::handle_error "CONFIG_ERROR" "Invalid JSON syntax in network settings file: '$network_settings_file'"
            # Even on error, keep defaults, then apply ENV overrides below
        else
            local v

            v=$(systems::fetch_json "$settings_content" '.cache_dir' "Network Cache Directory") && {
                [[ -n "$v" && "$v" != "null" ]] && CACHE_DIR="$v"
            }

            v=$(systems::fetch_json "$settings_content" '.cache_duration' "Network Cache Duration") && {
                [[ -n "$v" && "$v" != "null" ]] && CACHE_DURATION="$v"
            }

            local network_config_json
            network_config_json=$(systems::fetch_json "$settings_content" '.network_config' "Network Configuration Block") || {
                loggers::log_message "WARN" "Missing 'network_config' block in network settings. Using defaults for NETWORK_CONFIG."
                network_config_json=
            }

            if [[ -n "$network_config_json" && "$network_config_json" != "null" ]]; then
                # Normalize keys to uppercase to match defaults (e.g., max_retries -> MAX_RETRIES)
                while IFS= read -r entry_json; do
                    local key value key_upper
                    key=$(echo "$entry_json" | jq -r '.key')
                    value=$(echo "$entry_json" | jq -r '.value')
                    key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
                    [[ -n "$key_upper" && "$key_upper" != "NULL" ]] && NETWORK_CONFIG["$key_upper"]="$value"
                done < <(echo "$network_config_json" | jq -c 'to_entries[]')
            fi

            loggers::log_message "DEBUG" "Loaded network settings from '$network_settings_file'"
        fi
    else
        loggers::log_message "WARN" "Network settings file not found: '$network_settings_file'. Using defaults."
    fi

    # Finally, overlay ENV overrides
    configs::_apply_env_overrides

    loggers::log_message "DEBUG" "Effective network settings: CACHE_DIR='$CACHE_DIR', CACHE_DURATION='$CACHE_DURATION', MAX_RETRIES='${NETWORK_CONFIG["MAX_RETRIES"]}', TIMEOUT='${NETWORK_CONFIG["TIMEOUT"]}', USER_AGENT='${NETWORK_CONFIG["USER_AGENT"]}', RATE_LIMIT='${NETWORK_CONFIG["RATE_LIMIT"]}', RETRY_DELAY='${NETWORK_CONFIG["RETRY_DELAY"]}'"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Config Schema Loader
# ------------------------------------------------------------------------------

# Load the configuration schema from schema.json.
# Usage: configs::load_schema "$CONFIG_ROOT/schema.json"
# configs::load_schema is no longer needed with ajv-cli validation.

# ------------------------------------------------------------------------------
# SECTION: Config File Validation
# ------------------------------------------------------------------------------

# Validate a single modular application configuration.
# Usage: configs::validate_single_config_file "/path/to/app.json"
configs::validate_single_config_file() {
    local config_file_path="$1"
    local filename
    filename="$(basename "$config_file_path")"
    local schema_file="$CONFIG_ROOT/schema.json"

    if ! command -v ajv &> /dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "ajv-cli is not installed. Please run 'npm install -g ajv-cli'." "$filename"
        return 1
    fi

    if [[ ! -f "$schema_file" ]]; then
        errors::handle_error "CONFIG_ERROR" "JSON Schema file not found: '$schema_file'" "$filename"
        return 1
    fi

    local validation_output
    if ! validation_output=$(ajv validate -s "$schema_file" "$config_file_path" 2>&1); then
        errors::handle_error "CONFIG_ERROR" "Configuration file '$filename' failed validation: $validation_output" "$filename"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Config File Discovery and Merging
# ------------------------------------------------------------------------------

# Find, validate, and merge all enabled config files into a JSON array.
# Usage: configs::get_validated_apps_json "$CONFIG_DIR"
configs::get_validated_apps_json() {
    local conf_dir="$1"

    if [[ ! -d "$conf_dir" ]]; then
        errors::handle_error "CONFIG_ERROR" "Modular configuration directory not found: '$conf_dir'."
        return 1
    fi

    local config_files=()
    while IFS= read -r -d '' file; do
        config_files+=("$file")
    done < <(find "$conf_dir" -maxdepth 1 -name "*.json" -not -name ".*" -not -name "_*" -type f -print0 | sort -z)

    if [[ ${#config_files[@]} -eq 0 ]]; then
        errors::handle_error "CONFIG_ERROR" "No config files found in: '$conf_dir'."
        return 1
    fi

    local merged_json_array="[]"
    local validated_and_enabled_files=0

    for file in "${config_files[@]}"; do
        if configs::validate_single_config_file "$file"; then
            local file_content
            file_content=$(< "$file")
            local enabled_status_check
            enabled_status_check=$(systems::fetch_json "$file_content" '.enabled' "$(basename "$file")")
            if [[ "$enabled_status_check" == "true" ]]; then
                merged_json_array=$(echo "$merged_json_array" | jq --argjson item "$file_content" '. + [$item]')
                ((validated_and_enabled_files++))
            else
                loggers::log_message "INFO" "Skipping disabled config file: '$(basename "$file")'"
                counters::inc_skipped
            fi
        else
            loggers::log_message "WARN" "Skipping invalid config file: '$(basename "$file")' (error logged above)"
            counters::inc_failed
        fi
    done

    if [[ "$validated_and_enabled_files" -eq 0 ]]; then
        errors::handle_error "CONFIG_ERROR" "No valid and enabled application configurations found."
        return 1
    fi

    echo "$merged_json_array"
}

# ------------------------------------------------------------------------------
# SECTION: Populate Globals from Merged JSON
# ------------------------------------------------------------------------------

# Replace current jq processing with batch processing
configs::populate_globals_from_json() {
    local merged_json_array="$1"

    # Process all at once
    local extracted_data
    extracted_data=$(echo "$merged_json_array" | jq -c '
        reduce .[] as $item ({
            apps_to_check: [],
            applications: {},
            all_fields: {}  # New field to store all key-value pairs
        };
        .apps_to_check += [$item.app_key] |
        .applications += {($item.app_key): $item.application} |
        .all_fields += {($item.app_key): ($item.application | to_entries | map({key: .key, value: .value}) | from_entries)}
        )
    ')

    # Populate CUSTOM_APP_KEYS
    mapfile -t CUSTOM_APP_KEYS < <(echo "$extracted_data" | jq -r '.apps_to_check[]')

    # Populate ALL_APP_CONFIGS in one go
    while IFS=$'\t' read -r app_key prop_key prop_value; do
        [[ -z "$app_key" || -z "$prop_key" || "$prop_key" == "_comment"* ]] && continue
        ALL_APP_CONFIGS["${app_key}_${prop_key}"]="$prop_value"
    done < <(echo "$extracted_data" | jq -r '
        .all_fields | 
        to_entries[] |
        .key as $app_key |
        .value |
        to_entries[] |
        select(.key | startswith("_comment") | not) |
        [$app_key, .key, .value] | @tsv
    ')
}

# ------------------------------------------------------------------------------
# SECTION: Config State Validation
# ------------------------------------------------------------------------------

# Validate that a sufficient number of applications were found in configurations.
# Exits with EXIT_SUCCESS if no applications are found, as this is a valid
# operational state (nothing to check).
# Usage: configs::validate_loaded_app_count "$total_apps"
configs::validate_loaded_app_count() {
    local total_apps=$1

    if [[ $total_apps -eq 0 ]]; then
        loggers::print_message \
            "No applications configured to check in '$CONFIG_DIR' directory with '\"enabled\": true'. Exiting."
        exit "${EXIT_SUCCESS}"
    fi
}

# ------------------------------------------------------------------------------
# SECTION: Unified Config Loader
# ------------------------------------------------------------------------------

# Orchestrate loading all configurations, including network and modular apps.
# This function serves as the single entry point for configuration loading.
# Usage: configs::load_all
configs::load_all() {
    if ! configs::load_network_settings "$CONFIG_ROOT/network_settings.json"; then
        return 1
    fi

    local merged_json
    if ! merged_json=$(configs::get_validated_apps_json "$CONFIG_DIR"); then
        return 1
    fi

    configs::populate_globals_from_json "$merged_json"

    loggers::log_message "INFO" "Successfully loaded ${#CUSTOM_APP_KEYS[@]} enabled modular configurations from: '$CONFIG_DIR'"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Default Config File Creation
# ------------------------------------------------------------------------------

# Create the default configuration directory and files.
# Usage: configs::create_default_files
configs::create_default_files() {
    local target_conf_dir="${CONFIG_DIR}"

    mkdir -p "$target_conf_dir" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create config directory: '$target_conf_dir'"
        return 1
    }

    loggers::print_message "Creating default modular configuration files in: '$target_conf_dir'"

    local default_app_configs
    default_app_configs=$(
        cat << 'EOF'
{
       "VeraCrypt": {
           "app_key": "VeraCrypt",
        "enabled": true,
        "application": {
            "name": "VeraCrypt",
            "type": "custom",
            "package_name": "veracrypt",
            "gpg_key_id": "5069A233D55A0EEB174A5FC3821ACD02680D16DE",
            "gpg_fingerprint": "5069A233D55A0EEB174A5FC3821ACD02680D16DE",
            "custom_checker_script": "veracrypt.sh",
            "custom_checker_func": "check_veracrypt"
        }
    },
    "Ghostty": {
        "app_key": "Ghostty",
        "enabled": true,
        "application": {
            "name": "Ghostty",
            "type": "github_deb",
            "package_name": "ghostty",
            "repo_owner": "mkasberg",
            "repo_name": "ghostty-ubuntu",
            "filename_pattern_template": "ghostty_%s.ppa2_amd64_25.04.deb"
        }
    },
    "Tabby": {
        "app_key": "Tabby",
        "enabled": true,
        "application": {
            "name": "Tabby",
            "type": "github_deb",
            "package_name": "tabby-terminal",
            "repo_owner": "Eugeny",
            "repo_name": "tabby",
            "filename_pattern_template": "tabby-%s-linux-x64.deb"
        }
    },
    "Warp": {
        "app_key": "Warp",
        "enabled": true,
        "application": {
            "name": "Warp",
            "type": "custom",
            "package_name": "warp-terminal",
            "custom_checker_script": "warp.sh",
            "custom_checker_func": "check_warp"
        }
    },
    "WaveTerm": {
        "app_key": "WaveTerm",
        "enabled": true,
        "application": {
            "name": "WaveTerm",
            "type": "github_deb",
            "package_name": "waveterm",
            "repo_owner": "wavetermdev",
            "repo_name": "waveterm",
            "filename_pattern_template": "waveterm-linux-amd64-%s.deb"
        }
    },
    "Cursor": {
        "app_key": "Cursor",
        "enabled": true,
        "application": {
            "name": "Cursor",
            "type": "custom",
            "install_path": "$HOME/Applications/cursor",
            "custom_checker_script": "cursor.sh",
            "custom_checker_func": "cursor::check"
        }
    },
    "Zed": {
        "app_key": "Zed",
        "enabled": true,
        "application": {
            "name": "Zed",
            "type": "custom",
            "flatpak_app_id": "dev.zed.Zed",
            "custom_checker_script": "zed.sh",
            "custom_checker_func": "check_zed"
        }
    }
}
EOF
    )

    local app_key
    while IFS= read -r app_key; do
        local filename
        filename="$(echo "$app_key" | tr '[:upper:]' '[:lower:]').json"
        local target_file="${target_conf_dir}/$filename"

        if [[ ! -f "$target_file" ]]; then
            echo "$default_app_configs" | jq --arg key "$app_key" '.[$key]' > "$target_file"
            if configs::validate_single_config_file "$target_file"; then
                loggers::log_message "INFO" "Created default config file: '$target_file'"
            else
                errors::handle_error "CONFIG_ERROR" "Failed to create default config file: '$target_file'"
            fi
        else
            loggers::log_message "INFO" "Default config file already exists: '$target_file' (skipped creation)"
        fi
    done < <(echo "$default_app_configs" | jq -r 'keys[]')

    loggers::print_message "Default modular configuration setup complete."
    return 0
}

# Get the full configuration for a specific application key.
# Usage: configs::get_app_config "AppKey" app_config_nameref
#   app_key           - The application key to retrieve.
#   app_config_nameref - The name of the associative array in the caller's scope
#                        to populate with the application's configuration.
# Returns 0 on success, 1 if app_key not found.
configs::get_app_config() {
    local app_key="$1"
    local app_config_nameref="$2"
    if [[ -z "$app_config_nameref" ]] || ! declare -p "$app_config_nameref" 2> /dev/null | grep -q 'declare -A'; then
        loggers::log_message "ERROR" "configs::get_app_config: Second argument '$app_config_nameref' is missing or not an associative array for app_key '$app_key'"
        return 1
    fi
    local -n app_config_ref=$app_config_nameref # Nameref to the array in the caller's scope

    # Clear the array to ensure a clean state
    for key in "${!app_config_ref[@]}"; do
        unset "app_config_ref[$key]"
    done

    local found=0
    local field_name
    for field_name in "${!ALL_APP_CONFIGS[@]}"; do
        if [[ "$field_name" == "${app_key}_"* ]]; then
            app_config_ref["${field_name#"${app_key}_"}"]="${ALL_APP_CONFIGS[$field_name]}"
            found=1
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        loggers::log_message "ERROR" "Application configuration not found for key: '$app_key'"
        return 1
    fi

    # Add the app_key itself to the config for convenience
    app_config_ref["app_key"]="$app_key"
    return 0
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
