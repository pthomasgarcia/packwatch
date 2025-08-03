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

declare -A CONFIG_SCHEMA
declare -A ALL_APP_CONFIGS
declare -a CUSTOM_APP_KEYS

# ------------------------------------------------------------------------------
# SECTION: Config Schema Loader
# ------------------------------------------------------------------------------

# Load the configuration schema from schema.json.
# Usage: configs::load_schema "$CONFIG_ROOT/schema.json"
configs::load_schema() {
	local schema_file="$1"

	if [[ ! -f "$schema_file" ]]; then
		errors::handle_error "CONFIG_ERROR" "Configuration schema file not found: '$schema_file'."
		return 1
	fi

	local schema_content
	schema_content=$(<"$schema_file")
	if ! jq -e . "$schema_file" >/dev/null 2>&1; then
		errors::handle_error "CONFIG_ERROR" "Invalid JSON syntax in schema file: '$schema_file'"
		return 1
	fi

	local app_type_key field_list
	while IFS= read -r app_type_key; do
		field_list=$(systems::get_json_value "$schema_content" ".\"$app_type_key\"" "Schema for '$app_type_key'")
		if [[ $? -eq 0 && -n "$field_list" ]]; then
			CONFIG_SCHEMA["$app_type_key"]="$field_list"
		fi
	done < <(echo "$schema_content" | jq -r 'keys[]')

	loggers::log_message "DEBUG" "Loaded CONFIG_SCHEMA from '$schema_file'"
	return 0
}

# ------------------------------------------------------------------------------
# SECTION: Config File Validation
# ------------------------------------------------------------------------------

# Validate a single modular application configuration.
# Usage: configs::validate_single_config_file "/path/to/app.json"
configs::validate_single_config_file() {
	local config_file_path="$1"
	local filename
	filename="$(basename "$config_file_path")"
	local file_content
	file_content=$(<"$config_file_path")

	if ! jq -e . "$config_file_path" >/dev/null 2>&1; then
		errors::handle_error "CONFIG_ERROR" "Invalid JSON syntax in: '$filename'"
		return 1
	fi

	local app_key enabled_status_str app_data_str
	app_key=$(systems::require_json_value "$file_content" '.app_key' 'app_key' "$filename") || return 1
	enabled_status_str=$(systems::require_json_value "$file_content" '.enabled' 'enabled status' "$filename") || return 1
	app_data_str=$(systems::require_json_value "$file_content" '.application' 'application block' "$filename") || return 1

	if [[ "$enabled_status_str" != "true" && "$enabled_status_str" != "false" ]]; then
		errors::handle_error "CONFIG_ERROR" "Field 'enabled' in '$filename' must be a boolean (true/false)."
		return 1
	fi

	local expected_filename
	expected_filename="$(echo "$app_key" | tr '[:upper:]' '[:lower:]').json"
	if [[ "$filename" != "$expected_filename" ]]; then
		errors::handle_error "CONFIG_ERROR" "Config filename '$filename' does not match expected '$expected_filename' for app_key '$app_key'"
		return 1
	fi

	local app_name_in_config
	app_name_in_config=$(systems::require_json_value "$app_data_str" '.name' 'name' "$app_key") || return 1

	local app_type
	app_type=$(systems::require_json_value "$app_data_str" '.type' 'type' "$app_name_in_config") || return 1

	local required_fields="${CONFIG_SCHEMA[$app_type]:-}"
	if [[ -z "$required_fields" ]]; then
		errors::handle_error "CONFIG_ERROR" "Unknown app type '$app_type' defined in: '$filename'" "$app_name_in_config"
		return 1
	fi

	IFS=',' read -ra fields <<<"$required_fields"
	for field in "${fields[@]}"; do
		if ! systems::require_json_value "$app_data_str" ".\"$field\"" "$field" "$app_name_in_config" >/dev/null; then
			return 1
		fi
	done

	case "$app_type" in
	"github_deb" | "direct_deb")
		local download_url_val
		download_url_val=$(systems::get_json_value "$app_data_str" '.download_url' "$app_name_in_config") || return 1
		if [[ -n "$download_url_val" ]] && ! validators::check_url_format "$download_url_val"; then
			errors::handle_error "CONFIG_ERROR" "Invalid download URL format in: '$filename'" "$app_name_in_config"
			return 1
		fi
		;;
	"appimage")
		local download_url_val install_path_val
		download_url_val=$(systems::get_json_value "$app_data_str" '.download_url' "$app_name_in_config") || return 1
		install_path_val=$(systems::get_json_value "$app_data_str" '.install_path' "$app_name_in_config") || return 1

		if ! validators::check_url_format "$download_url_val"; then
			errors::handle_error "CONFIG_ERROR" "Invalid download URL format in: '$filename'" "$app_name_in_config"
			return 1
		fi
		if ! validators::check_file_path "$install_path_val"; then
			errors::handle_error "CONFIG_ERROR" "Invalid install path format in: '$filename'" "$app_name_in_config"
			return 1
		fi
		;;
	esac

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
			file_content=$(<"$file")
			local enabled_status_check
			enabled_status_check=$(systems::get_json_value "$file_content" '.enabled' "$(basename "$file")")
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

# Populate the global config variables from a merged JSON array.
# Usage: configs::populate_globals_from_json "$merged_json_array"
configs::populate_globals_from_json() {
	local merged_json_array="$1"

	local apps_to_check_json="[]"
	local applications_json="{}"

	local extracted_data
	extracted_data=$(echo "$merged_json_array" | jq -c '
		reduce .[] as $item ({
			apps_to_check: [],
			applications: {}
		};
		.apps_to_check += [$item.app_key] |
		.applications += {($item.app_key): $item.application}
		)
	')

	mapfile -t CUSTOM_APP_KEYS < <(echo "$extracted_data" | jq -r '.apps_to_check[]')
	applications_json=$(echo "$extracted_data" | jq -c '.applications')

	local app_key prop_key prop_value
	while IFS=$'\t' read -r app_key prop_key prop_value; do
		[[ -z "$app_key" || -z "$prop_key" || "$prop_key" == "_comment"* ]] && continue
		ALL_APP_CONFIGS["${app_key}_${prop_key}"]="$prop_value"
	done < <(echo "$applications_json" | jq -r '
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
# SECTION: Modular Config Loader
# ------------------------------------------------------------------------------

# Orchestrate loading configuration from the modular directory.
# Usage: configs::load_modular_directory
configs::load_modular_directory() {
	if ! configs::load_schema "$CONFIG_ROOT/schema.json"; then
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
		cat <<'EOF'
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
			"custom_checker_func": "check_cursor"
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
			echo "$default_app_configs" | jq --arg key "$app_key" '.[$key]' >"$target_file"
			if configs::validate_single_config_file "$file"; then
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
if [[ -z "$app_config_nameref" ]]; then
	loggers::log_message "ERROR" "configs::get_app_config: Second argument (nameref) is missing for app_key '$app_key'"
	return 1
fi
if ! declare -p "$app_config_nameref" 2>/dev/null | grep -q 'declare -A'; then
	loggers::log_message "ERROR" "configs::get_app_config: Second argument '$app_config_nameref' is not an associative array for app_key '$app_key'"
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
