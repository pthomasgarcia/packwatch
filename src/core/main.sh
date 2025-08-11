#!/usr/bin/env bash
# shellcheck disable=SC1091

# ==============================================================================
# Packwatch: App Update Checker - Main Entry Point
# ==============================================================================
# This script is the main entry point for the application. It orchestrates
# the staged loading of modules, performs initialization steps, parses CLI
# arguments, and manages the overall update check workflow.
#
# Dependencies: (Implicitly loaded via the init phase modules)
#   - src/core/init/bootloader.sh
#   - src/core/init/interface.sh
#   - src/core/init/scaffolding.sh
#   - src/core/init/runtime.sh
#   - src/core/init/business.sh
#   - src/core/init/extensions.sh
# ==============================================================================
set -euo pipefail

# ==============================================================================
# SECTION: Setup
# ==============================================================================

# Determine the absolute path to the core directory (required for sourcing init modules)
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define the base path for the init phase modules
INIT_DIR="$CORE_DIR/init"
readonly CORE_DIR INIT_DIR
# main.sh (or your loader)

# ------------------------------------------------------------------------------
# Phase 0: Bootloader (Essential foundation for logging and error handling)
# Modules: globals.sh, systems.sh, loggers.sh, errors.sh
# ------------------------------------------------------------------------------
source "$INIT_DIR/bootloader.sh"

# ------------------------------------------------------------------------------
# Phase 1: Interface (CLI parsing, early user output)
# Modules: validators.sh, interfaces.sh, cli.sh
# ------------------------------------------------------------------------------
source "$INIT_DIR/interface.sh"

# ==============================================================================
# SECTION: Initialization
# ==============================================================================

# Setup environment variables and signal handlers
main::setup_environment() {
    : <<'DOC'
  Sets up the environment variables and signal handlers for the application.
  
  This function hardens environment variables and sets up signal handlers
  to ensure proper cleanup on exit.
  
  Globals:
    - PATH: Sets a secure PATH environment variable
    - LC_ALL: Sets locale to C for consistency
  
  Outputs:
    - None
  
  Returns:
    - None
DOC
    # Harden environment variables
    export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
    export LC_ALL=C
    
    # Setup signal handlers
    trap 'systems::perform_housekeeping; exit $?' EXIT
}

# Validate initial application state
main::validate_initial_state() {
    : <<'DOC'
  Validates the initial state of the application after module loading.
  
  This function checks for any errors during home directory determination,
  validates the global state, and handles any validation failures appropriately.
  
  Globals:
    - HOME_ERROR: Error message if home directory determination failed
  
  Outputs:
    - Error messages to stderr if validation fails
  
  Returns:
    - None (exits with error code if validation fails)
DOC
    # Perform post-sourcing validation
    if [[ -n "${HOME_ERROR:-}" ]]; then
        loggers::log_message "ERROR" "$HOME_ERROR"
        interfaces::print_home_determination_error "$HOME_ERROR"
    fi

    # Validate base state
    if ! globals::validate_state; then
        errors::handle_error "VALIDATION_ERROR" "Failed to validate global state" "core"
        local exit_code=$?
        exit "$exit_code"
    fi
}

# Initialize application components
main::init_components() {
    : <<'DOC'
  Initializes core application components and required files.
  
  This function resets counters, initializes the installed versions file,
  creates the cache directory, loads modular configuration, and freezes
  the global configuration.
  
  Globals:
    - CACHE_DIR: Path to the cache directory
  
  Outputs:
    - Error messages to stderr if initialization fails
  
  Returns:
    - None (exits with error code if initialization fails)
DOC
    # Reset counters for clean state
    counters::reset

    # Initialize installed versions file
    if ! packages::initialize_installed_versions_file; then
        errors::handle_error "INITIALIZATION_ERROR" "Failed to initialize installed versions file" "packages"
        local exit_code=$?
        exit "$exit_code"
    fi

    # Ensure cache directory exists
    if [[ -n "${CACHE_DIR:-}" ]]; then
        mkdir -p -- "$CACHE_DIR" || {
            errors::handle_error "PERMISSION_ERROR" \
                "Failed to create cache directory: '$CACHE_DIR'" "core"
            local exit_code=$?
            exit "$exit_code"
        }
    fi

    # Load modular configuration
    if ! configs::load_modular_directory; then
        errors::handle_error "INITIALIZATION_ERROR" "Failed to load modular directory" "configs"
        local exit_code=$?
        exit "$exit_code"
    fi

    # Freeze global configuration
    if ! globals::freeze; then
        errors::handle_error "CONFIG_ERROR" "Failed to freeze global configuration" "core"
        local exit_code=$?
        exit "$exit_code"
    fi
}

# Initialize the complete application environment and components
main::init() {
    : <<'DOC'
  Orchestrates the complete initialization of the application.
  
  This function sets up the environment, validates the initial state,
  optionally prints a debug state snapshot, and initializes all components.
  
  Globals:
    - VERBOSE: Verbosity level for debug output
  
  Outputs:
    - Debug state snapshot if VERBOSE >= 2
    - Error messages to stderr if initialization fails
  
  Returns:
    - None (exits with error code if initialization fails)
DOC
    main::setup_environment
    main::validate_initial_state

    # Optional: snapshot key state when verbose debug mode is enabled
    if [[ ${VERBOSE:-0} -ge 2 ]]; then
        loggers::log_message "DEBUG" "State snapshot requested"
        interfaces::print_debug_state_snapshot
    fi

    main::init_components
}

# ==============================================================================
# SECTION: Workflow
# ==============================================================================

# Perform the main application workflow for checking and processing updates
main::run() {
    : <<'DOC'
  Executes the main application workflow for checking and processing updates.
  
  This function validates the loaded app count, notifies the execution mode,
  performs update checks for all specified applications, and prints a summary.
  
  Arguments:
    - $@: Array of application keys to check
  
  Globals:
    - None directly
  
  Outputs:
    - Status messages and summary to stdout
    - Error messages to stderr if checks fail
  
  Returns:
    - None
DOC
    local -a apps_to_check=("$@")

    local total_apps=${#apps_to_check[@]}
    configs::validate_loaded_app_count "$total_apps"
    interfaces::notify_execution_mode
    updates::perform_all_checks "${apps_to_check[@]}"
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
    - INPUT_APP_KEYS_FROM_CLI: Array of app keys passed via command line.
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
    # Parse CLI arguments
    cli::parse_arguments "$@"

    # Handle quick-exit paths early
    if [[ ${SHOW_HELP:-0} -eq 1 ]]; then
        cli::show_usage
        return 0
    fi

    if [[ ${SHOW_VERSION:-0} -eq 1 ]]; then
        echo "$SCRIPT_VERSION"
        return 0
    fi

    if [[ ${CREATE_CONFIG:-0} -eq 1 ]]; then
        configs::create_default_files
        loggers::print_message "Default configuration created/updated in: '$CONFIG_DIR'"
        return 0
    fi

    # Handle dry run mode early
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        interfaces::print_application_header
        interfaces::notify_execution_mode
        echo "[DRY RUN] Exiting without checking apps."
        return 0
    fi

	# ------------------------------------------------------------------------------
	# Phase 2: Scaffolding (Config management, counters, notifiers, checker_utils)
	# Modules: configs.sh, counters.sh, notifiers.sh, util/checker_utils.sh
	# ------------------------------------------------------------------------------
	source "$INIT_DIR/scaffolding.sh"

	# ------------------------------------------------------------------------------
	# Phase 3a: Runtime (Core application mechanisms: versions, networks, repos, packages)
	# ------------------------------------------------------------------------------
	source "$INIT_DIR/runtime.sh"

	# ------------------------------------------------------------------------------
	# Phase 3b: Business (The core update logic: updates.sh)
	# ------------------------------------------------------------------------------
	source "$INIT_DIR/business.sh"

	# ------------------------------------------------------------------------------
	# Phase 4: Extensions (Conditional loading of gpg.sh and custom_checkers)
	# ------------------------------------------------------------------------------
	source "$INIT_DIR/extensions.sh"

    # Initialize all core application components and environment
    main::init

    # Display the main application header
    interfaces::print_application_header

    # Optional Extension Init: Probe for specific extension readiness
    if declare -F gpg::is_ready >/dev/null 2>&1; then
        if ! gpg::is_ready; then
            loggers::log_message "WARN" \
                "GPG might prompt or fail due to uninitialized keyring for the original user." \
                "core"
        fi
    fi

    # Determine the final list of applications to check
    local -a apps_to_check
    cli::determine_apps_to_check apps_to_check

    # Execute the main update workflow
    main::run "${apps_to_check[@]}"

    # Return an exit code indicating overall success or failure
    if (( $(counters::get_failed) > 0 )); then
        return 1
    else
        return 0
    fi
}

# ==============================================================================
# SECTION: Script Entry Point
# ==============================================================================

# Perform system dependency check early
if ! systems::check_dependencies; then
    exit 1
fi

# Run the main application logic
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
