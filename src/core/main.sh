#!/usr/bin/env bash
# shellcheck disable=SC1091

# ==============================================================================
# Packwatch: App Update Checker - Main Entry Point
# ==============================================================================
# This script is the main entry point for the application. It sets up the
# environment, sources all necessary modules, and orchestrates the update check.
# ==============================================================================
set -euo pipefail

# ==============================================================================
# SECTION: Bootstrap Script Directory (required for sourcing)
# ==============================================================================
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_DIR

# ==============================================================================
# SECTION: Source Global Variables
# ==============================================================================
# Note: globals.sh assumes CORE_DIR is already defined.
source "$CORE_DIR/globals.sh"

# ==============================================================================
# SECTION: Source All Modules
# ==============================================================================
# The order is important due to dependencies between modules.

# Foundational modules
source "$CORE_DIR/../lib/loggers.sh"
source "$CORE_DIR/../lib/counters.sh"
source "$CORE_DIR/../lib/notifiers.sh"
source "$CORE_DIR/../lib/errors.sh"
source "$CORE_DIR/../lib/systems.sh"
source "$CORE_DIR/../lib/validators.sh"
source "$CORE_DIR/../lib/versions.sh"

source "$CORE_DIR/../lib/checker_utils.sh"

# Core logic modules
source "$CORE_DIR/networks.sh"
source "$CORE_DIR/repositories.sh"
source "$CORE_DIR/packages.sh"
source "$CORE_DIR/configs.sh"
source "$CORE_DIR/interfaces.sh"
source "$CORE_DIR/updates.sh"
source "$CORE_DIR/cli.sh"

# External libraries
# shellcheck source=/dev/null
source "$CORE_DIR/../lib/gpg.sh"

# ==============================================================================
# SECTION: Application Initialization and Orchestration
# ==============================================================================

# Initialize the complete application environment and components.
# This includes setting up signal handlers, validating global state,
# resetting counters, and loading configurations.
# Initialize the complete application environment and components.
# This includes setting up signal handlers, validating global state,
# resetting counters, and loading configurations.
main::initialize_application() {
	# Setup signal handlers
	trap 'systems::perform_housekeeping; exit $?' EXIT

	# Perform post-sourcing validation (e.g., initial HOME/USER determination errors)
	if [[ -n "${_home_determination_error:-}" ]]; then
		loggers::log_message "ERROR" "$_home_determination_error"
		interfaces::print_home_determination_error "$_home_determination_error"
	fi

	# Validate base state (directories, user context, etc.)
	if ! globals::validate_state; then
		errors::handle_error "VALIDATION_ERROR" "Failed to validate global state" "core"
		local exit_code=$?
		exit "$exit_code"
	fi

	# Optional: snapshot key state when verbose debug mode is enabled
	if [[ ${VERBOSE:-0} -ge 2 ]]; then
		loggers::log_message "DEBUG" "State snapshot requested"
		interfaces::print_debug_state_snapshot
	fi

	# Initialize application components
	counters::reset # Ensure a clean state for each run

	if ! packages::initialize_installed_versions_file; then
		errors::handle_error "INITIALIZATION_ERROR" "Failed to initialize installed versions file" "packages"
		local exit_code=$?
		exit "$exit_code"
	fi

	if ! configs::load_modular_directory; then
		errors::handle_error "INITIALIZATION_ERROR" "Failed to load modular directory" "configs"
		local exit_code=$?
		exit "$exit_code"
	fi

	# Optionally freeze semantically-immutable values after config load
	if ! globals::freeze; then
		errors::handle_error "CONFIG_ERROR" "Failed to freeze global configuration" "core"
		local exit_code=$?
		exit "$exit_code"
	fi
}

# Perform the main application workflow for checking and processing updates.
# This function orchestrates the steps after initialization is complete.
main::perform_application_workflow() {
	local -a apps_to_check=("$@")

	local total_apps=${#apps_to_check[@]}
	configs::validate_loaded_app_count "$total_apps"  # Delegates to configs module
	interfaces::notify_execution_mode                 # Delegates to interfaces module
	updates::perform_all_checks "${apps_to_check[@]}" # Delegates to updates module
	interfaces::print_summary
}

# ==============================================================================
# SECTION: Main Function
# ==============================================================================

main() {
	: <<'DOC'
  Orchestrates the entire application update check process.

  This function serves as the primary controller. It parses command-line
  arguments, initializes necessary files and configurations, determines the list
  of applications to check (either all enabled apps or a subset from the
  command line), iterates through them calling the update checker, and finally
  prints a summary of the results.

  Globals (Read):
    - CUSTOM_APP_KEYS: Array of enabled application keys from config files.
    - input_app_keys_from_cli: Array of app keys passed via command line.
    - DRY_RUN: Flag to indicate if a dry run should be performed.
    - CONFIG_DIR: Path to the application configuration directory.

  Globals (Write):
    - None directly. State counters are managed via the `counters` module.

  Outputs:
    - Prints status messages and a final summary to standard output.
    - Logs detailed messages via the `loggers` module.

  Returns:
    - 0 if all checks were successful or skipped.
    - 1 if any application check failed.
DOC
	# Parse CLI arguments (now self-contained in cli module)
	cli::parse_arguments "$@"

	# Initialize all core application components and environment
	main::initialize_application

	# Display the main application header
	interfaces::print_application_header

	# Determine the final list of applications to check
	local -a apps_to_check
	cli::determine_apps_to_check apps_to_check # No parameters needed!

	# Execute the main update workflow
	main::perform_application_workflow "${apps_to_check[@]}"

	# Return an exit code indicating overall success or failure
	return $(($(counters::get_failed) > 0 ? 1 : 0))
}

# ==============================================================================
# SECTION: Script Entry Point
# ==============================================================================

# Perform system dependency check early. This is a crucial pre-initialization step.
if ! systems::check_dependencies; then
	exit 1
fi

# Run the main application logic.
main "$@"
exit $?
