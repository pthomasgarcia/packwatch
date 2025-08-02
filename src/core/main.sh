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
# SECTION: Constants and Configuration
# ==============================================================================
readonly APP_NAME="Packwatch"
readonly APP_DESCRIPTION="Application Update Checker"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1

# Required system dependencies
readonly -a REQUIRED_COMMANDS=(
  "wget" "curl" "gpg" "jq" "dpkg"
  "sha256sum" "lsb_release" "getent"
)

# Package installation command
readonly INSTALL_CMD="sudo apt update && sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release getent"

# ==============================================================================
# SECTION: Bootstrap Script Directory (required for sourcing)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ==============================================================================
# SECTION: Safe Module Sourcing
# ==============================================================================

source_safe() {
  local file="$1"
  
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Required file not found: $file" >&2
    exit "${EXIT_FAILURE}"
  fi
  
  if [[ ! -r "$file" ]]; then
    echo "ERROR: Cannot read file: $file" >&2
    exit "${EXIT_FAILURE}"
  fi
  
  # shellcheck source=/dev/null
  source "$file"
}

# ==============================================================================
# SECTION: Helper Functions for Error Handling and Display
# ==============================================================================

# Handles missing dependencies by logging and printing help
handle_missing_dependencies() {
  local -a missing_cmds=("$@")
  
  errors::handle_error_and_exit "DEPENDENCY_ERROR" \
    "Missing required core commands: ${missing_cmds[*]}. Please install them."
  
  # Note: interfaces::print_installation_help is called within handle_error_and_exit
}

# ------------------------------------------------------------------------------
# SECTION: System Dependency Check
# ------------------------------------------------------------------------------

# Check that all required system dependencies are available
check_system_dependencies() {
  loggers::log_message "INFO" "Performing dependency check..."
  local -a missing_cmds=()
  
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done

  if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    handle_missing_dependencies "${missing_cmds[@]}"
  fi
  
  loggers::log_message "INFO" "All core dependencies found."
}

# ------------------------------------------------------------------------------
# SECTION: Application Initialization
# ------------------------------------------------------------------------------

# Initialize the complete application
initialize_application() {
  # Setup signal handlers
  # Using bash's built-in 'trap' and assuming its success. If it fails, it's a shell issue.
  trap systems::perform_housekeeping EXIT
  trap systems::perform_housekeeping ERR
  
  # Perform post-sourcing validation and setup
  if [[ -n "${_home_determination_error:-}" ]]; then
    loggers::log_message "ERROR" "$_home_determination_error"
  fi

  # Validate base state early (directories, user context, etc.)
  if ! globals::validate_state; then
    errors::handle_module_error "globals" "validate_state" "VALIDATION_ERROR"
  fi

  # Optional: snapshot key state when verbose
  if [[ ${VERBOSE:-0} -ge 2 ]]; then
    loggers::log_message "DEBUG" "State snapshot:"
    loggers::log_message "DEBUG" "  SCRIPT_DIR=$SCRIPT_DIR"
    loggers::log_message "DEBUG" "  CONFIG_ROOT=$CONFIG_ROOT"
    loggers::log_message "DEBUG" "  CONFIG_DIR=$CONFIG_DIR"
    loggers::log_message "DEBUG" "  CACHE_DIR=$CACHE_DIR"
    loggers::log_message "DEBUG" "  ORIGINAL_USER=$ORIGINAL_USER"
    loggers::log_message "DEBUG" "  ORIGINAL_HOME=$ORIGINAL_HOME"
    loggers::log_message "DEBUG" "  DRY_RUN=$DRY_RUN VERBOSE=$VERBOSE"
  fi

  # Initialize application components
  counters::reset
  
  packages::initialize_installed_versions_file || errors::handle_module_error "packages" "initialize_installed_versions_file" "INITIALIZATION_ERROR"
  configs::load_modular_directory || errors::handle_module_error "configs" "load_modular_directory" "INITIALIZATION_ERROR"

  # Optionally freeze semantically-immutable values after config load
  globals::freeze || errors::handle_module_error "globals" "freeze" "CONFIG_ERROR"
}

# ------------------------------------------------------------------------------
# SECTION: Workflow Functions
# ------------------------------------------------------------------------------

validate_app_count() {
  local total_apps=$1
  
  if [[ $total_apps -eq 0 ]]; then
    loggers::print_message \
      "No applications configured to check in '$CONFIG_DIR' directory with '\"enabled\": true'. Exiting."
    exit "${EXIT_SUCCESS}"
  fi
}

notify_execution_mode() {
  if [[ $DRY_RUN -eq 1 ]]; then
    loggers::print_message ""
    loggers::print_message "$(_color_yellow "🚀 Running in DRY RUN mode - no installations or file modifications will be performed.")"
  fi
}

perform_update_checks() {
  local -a apps_to_check=("$@")
  local total_apps=${#apps_to_check[@]}
  local current_index=1
  
  for app_key in "${apps_to_check[@]}"; do
    updates::check_application "$app_key" "$current_index" "$total_apps" || true
    ((current_index++))
  done
}

validate_and_filter_cli_apps() {
  local -n apps_ref=$1
  local -a cli_apps=("${@:2}")
  
  # Create associative array of enabled apps for fast lookup
  declare -A enabled_apps_assoc
  for key in "${CUSTOM_APP_KEYS[@]}"; do
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
      "No valid application keys specified on command line found in enabled configurations. Exiting."
  fi
}

determine_apps_to_check() {
  local -n apps_ref=$1
  local -a input_apps=("${@:2}")
  
  # Default to all enabled apps
  apps_ref=("${CUSTOM_APP_KEYS[@]}")
  
  # Override with CLI apps if provided
  if [[ ${#input_apps[@]} -gt 0 ]]; then
    validate_and_filter_cli_apps apps_ref "${input_apps[@]}"
  fi
}

perform_application_workflow() {
  local -a apps_to_check=("$@")
  
  local total_apps=${#apps_to_check[@]}
  validate_app_count "$total_apps"
  notify_execution_mode
  perform_update_checks "${apps_to_check[@]}"
  interfaces::print_summary
}

# ==============================================================================
# SECTION: Source Global Variables
# ==============================================================================
# Note: globals.sh assumes SCRIPT_DIR is already defined.
source "$SCRIPT_DIR/globals.sh"

# ==============================================================================
# SECTION: Source All Modules
# ==============================================================================
# The order is important due to dependencies between modules.

# Foundational modules (moved to src/lib)
source "$SCRIPT_DIR/../lib/loggers.sh"
source "$SCRIPT_DIR/../lib/counters.sh"
source "$SCRIPT_DIR/../lib/notifiers.sh"
source "$SCRIPT_DIR/../lib/errors.sh"
source "$SCRIPT_DIR/../lib/systems.sh"
source "$SCRIPT_DIR/../lib/validators.sh"
source "$SCRIPT_DIR/../lib/versions.sh"

# Core logic modules
source "$SCRIPT_DIR/networks.sh"
source "$SCRIPT_DIR/repositories.sh"
source "$SCRIPT_DIR/packages.sh"
source "$SCRIPT_DIR/configs.sh"
source "$SCRIPT_DIR/interfaces.sh"
source "$SCRIPT_DIR/updates.sh"
source "$SCRIPT_DIR/cli.sh"

# External libraries
# shellcheck source=/dev/null
source "$(dirname "$SCRIPT_DIR")/lib/gpg.sh"

# ==============================================================================
# SECTION: Main Function
# ==============================================================================

main() {
  : <<'DOC'
  Orchestrates the entire application update check process.

  This function serves as the primary controller. It initializes necessary files
  and configurations, determines the list of applications to check (either all
  enabled apps or a subset from the command line), iterates through them calling
  the update checker, and finally prints a summary of the results.

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
  # Parse CLI arguments first
  cli::parse_arguments "$@"
  
  # Initialize complete application
  initialize_application
  
  # Display application header
  interfaces::print_application_header

  # --- Application Keys from CLI ---
  # Populated by cli::parse_arguments
  declare -a input_app_keys_from_cli=()

  # --- Determine Apps to Check ---
  local -a apps_to_check
  determine_apps_to_check apps_to_check "${input_app_keys_from_cli[@]}"

  # --- Execute the main workflow ---
  perform_application_workflow "${apps_to_check[@]}"

  if [[ $(counters::get_failed) -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ==============================================================================
# SECTION: Script Entry Point
# ==============================================================================

# --- Dependency Check ---
check_system_dependencies

# --- Run Main ---
main "$@"
exit_code=$?
exit $exit_code
