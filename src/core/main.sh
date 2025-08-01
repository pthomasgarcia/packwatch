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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

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

# --- Post-Sourcing Checks ---
# Now that loggers are available, log any deferred messages.
if [[ -n "${_home_determination_error:-}" ]]; then
  loggers::log_message "ERROR" "$_home_determination_error"
fi

# Validate base state early (directories, user context, etc.)
globals::validate_state || {
  errors::handle_error "VALIDATION_ERROR" "Global state validation failed."
  exit 1
}

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

# ==============================================================================
# SECTION: Housekeeping / Cleanup Trap
# ==============================================================================
trap systems::perform_housekeeping EXIT
trap systems::perform_housekeeping ERR

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
  counters::reset # Ensure a clean state for each run
  packages::initialize_installed_versions_file || exit 1
  configs::load_modular_directory || exit 1

  # Optionally freeze semantically-immutable values after config load
  globals::freeze || true

  loggers::print_message ""
  loggers::print_message "$(_bold "🔄 Packwatch: Application Update Checker")"
  loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # --- Application Keys from CLI ---
  # Populated by cli::parse_arguments
  declare -a input_app_keys_from_cli=()

  # --- Determine Apps to Check ---
  local apps_to_check=("${CUSTOM_APP_KEYS[@]}")
  if [[ ${#input_app_keys_from_cli[@]} -gt 0 ]]; then
    declare -A enabled_apps_assoc
    for key in "${CUSTOM_APP_KEYS[@]}"; do
      enabled_apps_assoc["$key"]=1
    done

    local valid_cli_apps=()
    for cli_app in "${input_app_keys_from_cli[@]}"; do
      if [[ -n "${enabled_apps_assoc[$cli_app]:-}" ]]; then
        valid_cli_apps+=("$cli_app")
      else
        loggers::log_message "WARN" \
          "Application '$cli_app' specified on command line not found or not enabled in configurations. Skipping."
      fi
    done

    if [[ ${#valid_cli_apps[@]} -gt 0 ]]; then
      apps_to_check=("${valid_cli_apps[@]}")
    else
      errors::handle_error "VALIDATION_ERROR" \
        "No valid application keys specified on command line found in enabled configurations. Exiting."
      exit 1
    fi
  fi

  local total_apps=${#apps_to_check[@]}
  if [[ $total_apps -eq 0 ]]; then
    loggers::print_message \
      "No applications configured to check in '$CONFIG_DIR' directory with '\"enabled\": true'. Exiting."
    exit 0
  fi

  # --- Execution Mode Notification ---
  if [[ $DRY_RUN -eq 1 ]]; then
    loggers::print_message ""
    loggers::print_message "$(_color_yellow "🚀 Running in DRY RUN mode - no installations or file modifications will be performed.")"
  fi

  # --- Perform Update Checks ---
  local current_index=1
  for app_key in "${apps_to_check[@]}"; do
    updates::check_application "$app_key" "$current_index" "$total_apps" || true
    ((current_index++))
  done

  # --- Print Summary ---
  loggers::print_message ""
  loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
  loggers::print_message "$(_bold "Update Summary:")"
  loggers::print_message "  $(_color_green "✓ Up to date:")    $(counters::get_up_to_date)"
  loggers::print_message "  $(_color_yellow "⬆ Updated:")       $(counters::get_updated)"
  loggers::print_message "  $(_color_red "✗ Failed:")        $(counters::get_failed)"
  if [[ $(counters::get_skipped) -gt 0 ]]; then
    loggers::print_message "  $(_color_cyan "🞨 Skipped/Disabled:") $(counters::get_skipped)"
  fi
  loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"

  if [[ $(counters::get_failed) -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ==============================================================================
# SECTION: Script Entry Point
# ==============================================================================

# --- Dependency Check ---
loggers::log_message "INFO" "Performing dependency check..."
declare -a missing_cmds=()
for cmd in wget curl gpg jq dpkg sha256sum lsb_release getent; do
  if ! command -v "$cmd" &>/dev/null; then
    missing_cmds+=("$cmd")
  fi
done

if [[ ${#missing_cmds[@]} -gt 0 ]]; then
  errors::handle_error "DEPENDENCY_ERROR" \
    "Missing required core commands: ${missing_cmds[*]}. Please install them."
  loggers::print_message ""
  loggers::print_message "$(_bold "To install core dependencies:")"
  loggers::print_message \
    "  $(_color_cyan "sudo apt update && sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release getent")"
  loggers::print_message ""
  loggers::print_message "If 'notify-send' is missing, install 'libnotify-bin'."
  loggers::print_message "If 'flatpak' is missing, refer to https://flatpak.org/setup/."
  exit "${ERROR_CODES[DEPENDENCY_ERROR]}"
fi
loggers::log_message "INFO" "All core dependencies found."

# --- Parse Arguments and Run Main ---
cli::parse_arguments "$@"
main
exit_code=$?
exit $exit_code
