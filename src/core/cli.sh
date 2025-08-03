#!/usr/bin/env bash
# ==============================================================================
# MODULE: cli.sh
# ==============================================================================
# Responsibilities:
#   - CLI argument parsing and usage/help output
#   - Validation and filtering of CLI-provided application keys
#   - Determination of applications to check based on CLI input
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/cli.sh"
#
#   Then use:
#     cli::parse_arguments "$@"
#     cli::show_usage
#     cli::determine_apps_to_check apps_array_ref "${input_app_keys[@]}"
# ==============================================================================

# Private module state - CLI arguments
declare -g -a _CLI_APP_KEYS=()

# Public accessor function
cli::get_app_keys() {
	printf '%s\n' "${_CLI_APP_KEYS[@]}"
}

cli::has_app_keys() {
	[[ ${#_CLI_APP_KEYS[@]} -gt 0 ]]
}

# ------------------------------------------------------------------------------
# SECTION: Available App Keys for Display
# ------------------------------------------------------------------------------

# Get available app keys from config files for display.
# Usage: cli::get_available_app_keys_for_display
cli::get_available_app_keys_for_display() {
	if [[ ! -d "$CONFIG_DIR" ]]; then
		return
	fi

	local config_files=()
	while IFS= read -r -d '' file; do
		config_files+=("$file")
	done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.json" -not -name ".*" -not -name "_*" -type f -print0)

	if [[ ${#config_files[@]} -eq 0 ]]; then
		return
	fi

	for file_path in "${config_files[@]}"; do
		# Use jq to safely extract app_key and name. Fallback to filename if needed.
		local app_info
		app_info=$(jq -r '{key: .app_key, name: .application.name} | "\(.key)---_---\(.name)"' "$file_path" 2>/dev/null)
		if [[ -n "$app_info" ]]; then
			local key="${app_info%%---_---*}"
			local name="${app_info#*---_---}"
			if [[ "$name" == "null" || -z "$name" ]]; then name="$key"; fi
			echo "$key ($name)"
		fi
	done | sort
}

# ------------------------------------------------------------------------------
# SECTION: Usage/Help Output
# ------------------------------------------------------------------------------

# Display script usage information.
# Usage: cli::show_usage
cli::show_usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [APP_KEYS...]

Check for updates to various applications and optionally install them.

Options:
    -h, --help          Show this help message and exit
    -v, --verbose       Enable verbose output and debug information
    -n, --dry-run       Check for updates but don't download or install
    --cache-duration N  Cache duration in seconds (default: 300)
    --create-config     Create default modular configuration files and exit
    --version           Show script version and exit

Examples:
    $SCRIPT_NAME                    # Check all default configured apps
    $SCRIPT_NAME Ghostty Tabby      # Check specific apps only (using their KEYs)
    $SCRIPT_NAME -v -n              # Verbose dry-run mode

Supported Application Keys (defined in your JSON config files in '$CONFIG_DIR'):
EOF

	while read -r line; do
		loggers::print_message "    $line"
	done < <(cli::get_available_app_keys_for_display)

	cat <<EOF

Configuration directory: '$CONFIG_DIR'
This script is an engine. All application definitions are loaded from the
JSON configuration files in the above directory. Use the --create-config
option to generate default files.

Cache directory: '$CACHE_DIR'
Dependencies: sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release getent
For VeraCrypt: Manually verify and import its GPG key.
For Flatpak apps: Install Flatpak - refer to https://flatpak.org/setup/.
EOF
}

# ------------------------------------------------------------------------------
# SECTION: CLI Argument Parsing
# ------------------------------------------------------------------------------

# Parse command-line arguments and populate global input_app_keys_from_cli.
# Usage: cli::parse_arguments "$@"
cli::parse_arguments() {
	local apps_specified_on_cmdline=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			cli::show_usage
			exit 0
			;;
		-v | --verbose)
			VERBOSE=1
			shift
			;;
		-n | --dry-run)
			DRY_RUN=1
			shift
			;;
		--cache-duration)
			if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
				errors::handle_error_and_exit "CLI_ERROR" "Option --cache-duration requires a positive integer." "cli"
			fi
			CACHE_DURATION="$2"
			shift 2
			;;
		--create-config)
			configs::create_default_files
			loggers::print_message "Default configuration created/updated in: '$CONFIG_DIR'"
			exit 0
			;;
		--version)
			echo "$SCRIPT_VERSION"
			exit 0
			;;
		-*)
			errors::handle_error_and_exit "CLI_ERROR" "Unknown option: '$1'" "cli"
			;;
		*)
			_CLI_APP_KEYS+=("$1") # Direct assignment to module state
			apps_specified_on_cmdline=1
			shift
			;;
		esac
	done
}

# ------------------------------------------------------------------------------
# SECTION: Application Key Filtering & Determination
# ------------------------------------------------------------------------------

# Validate and filter CLI apps against enabled configurations.
# Usage: cli::validate_and_filter_apps apps_ref "${cli_apps[@]}"
#   apps_ref  - Nameref to the array that will store the valid filtered apps
#   cli_apps  - Array of app keys specified on the command line
cli::validate_and_filter_apps() {
	local -n apps_ref=$1
	local -a cli_apps=("${@:2}")

	# Create associative array of enabled apps for fast lookup
	declare -A enabled_apps_assoc
	for key in "${CUSTOM_APP_KEYS[@]}"; do # CUSTOM_APP_KEYS is populated by configs::load_modular_directory
		enabled_apps_assoc["$key"]=1
	done

	# Filter CLI apps to only include enabled ones
	local -a valid_cli_apps=()
	for cli_app in "${cli_apps[@]}"; do
		if [[ -n "${enabled_apps_assoc[$cli_app]:-}" ]]; then
			valid_cli_apps+=("$cli_app")
		else
			loggers::log_message "WARN" \
				"Application '$cli_app' specified on command line not found or not enabled in configurations. Skipping."
		fi
	done

	# Update apps array or exit if no valid apps
	if [[ ${#valid_cli_apps[@]} -gt 0 ]]; then
		apps_ref=("${valid_cli_apps[@]}")
	else
		errors::handle_error_and_exit "CLI_ERROR" \
			"No valid application keys specified on command line found in enabled configurations. Exiting." "cli"
	fi
}

# Determine the final list of applications to check.
# This defaults to all enabled apps unless specific keys are provided via CLI.
# Usage: cli::determine_apps_to_check apps_ref "${input_app_keys_from_cli[@]}"
#   apps_ref                 - Nameref to the array that will store the final list of apps
#   input_app_keys_from_cli  - Array of app keys parsed from the command line
cli::determine_apps_to_check() {
	local -n apps_ref=$1

	# Default to all enabled apps
	apps_ref=("${CUSTOM_APP_KEYS[@]}")

	# Override with CLI apps if provided
	if cli::has_app_keys; then
		local -a cli_apps
		readarray -t cli_apps < <(cli::get_app_keys)
		cli::validate_and_filter_apps apps_ref "${cli_apps[@]}"
	fi
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
