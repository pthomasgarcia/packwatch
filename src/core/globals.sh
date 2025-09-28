#!/usr/bin/env bash
# shellcheck disable=SC2034

# --- Include Guard ---
# Ensures this script is sourced only once, preventing unintended side effects.
if [[ -n "${PACKWATCH_GLOBALS_SOURCED:-}" ]]; then
    return 0
fi
declare -g PACKWATCH_GLOBALS_SOURCED=1

# --- Critical Prerequisite Check ---
# Fail fast if CORE_DIR is not set by the caller to prevent downstream errors.
if [[ -z "${CORE_DIR:-}" ]]; then
    echo "FATAL: CORE_DIR must be set before sourcing globals.sh" >&2
    return 1
fi

# ==============================================================================
# Packwatch: Global Variables and Configuration
# ==============================================================================
# This file centralizes all application-wide global variables, constants,
# and configuration settings for the Packwatch application.
#
# Dependencies:
#   Assumes CORE_DIR is defined by the caller before sourcing this file.
# ==============================================================================

# --- 1. Application Metadata ---
# Basic information about the application.
readonly APP_NAME="Packwatch"
readonly APP_DESCRIPTION="Application Update Checker"
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="packwatch"

# --- 2. ANSI Formatting Constants ---
# Constants for colored and formatted terminal output.
# Disabled if stdout is not a TTY, if NO_COLOR is set, or if TERM=dumb.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    readonly COLOR_RED=$'\033[0;31m'
    readonly COLOR_GREEN=$'\033[0;32m'
    readonly COLOR_YELLOW=$'\033[0;33m'
    readonly COLOR_BLUE=$'\033[0;34m'
    readonly COLOR_CYAN=$'\033[0;36m'
    readonly FORMAT_BOLD=$'\033[1m'
    readonly FORMAT_RESET=$'\033[0m'
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_CYAN=""
    readonly FORMAT_BOLD=""
    readonly FORMAT_RESET=""
fi

# --- 3. Core Paths & Directories ---
# Essential paths for configuration, caching, and core utilities.
CONFIG_ROOT="$(dirname "$(dirname "$CORE_DIR")")/config"
readonly CONFIG_ROOT
readonly CONFIG_DIR="$CONFIG_ROOT/conf.d"
readonly HASH_UTILS_PATH="$CORE_DIR/../util/hashes.sh" # Path to hash utility functions

# Cache directory for downloaded artifacts and temporary files.
# Exported for subprocesses that may need to access or clean the cache.
CACHE_DIR="${HOME}/.cache/packwatch/cache"
export CACHE_DIR

# --- 4. System Dependencies & Installation ---
# Commands required for Packwatch to function, and the default installation command.
readonly REQUIRED_COMMANDS=(
    "wget" "curl" "gpg" "jq" "dpkg" "ajv" "lsof"
    "sha256sum" "lsb_release" "getent"
)
readonly INSTALL_CMD="sudo apt install -y" # Default command for package installation

# --- 5. User Context ---
# Variables related to the original user (before potential sudo elevation).
readonly ORIGINAL_USER="${SUDO_USER:-$USER}" # The user who invoked the script
HOME_ERROR=""                                # Stores error message if SUDO_USER's home can't be determined
if [[ -n "${SUDO_USER:-}" ]]; then
    DETERMINED_HOME=""
    # First, try the most reliable method: getent
    if command -v getent > /dev/null 2>&1; then
        DETERMINED_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
    fi
    # If getent fails or is not available, try a shell expansion fallback
    if [[ -z "${DETERMINED_HOME:-}" ]]; then
        # shellcheck disable=SC2086
        DETERMINED_HOME=$(eval echo ~${SUDO_USER} 2> /dev/null || true)
    fi

    if [[ -n "${DETERMINED_HOME:-}" && -d "${DETERMINED_HOME}" ]]; then
        readonly ORIGINAL_HOME="$DETERMINED_HOME" # Home directory of the original user
    else
        HOME_ERROR="Could not determine home directory for SUDO_USER: '$SUDO_USER'. Falling back to current HOME."
        readonly ORIGINAL_HOME="$HOME"
    fi
else
    readonly ORIGINAL_HOME="$HOME" # Home directory of the current user
fi
export ORIGINAL_HOME

# --- 6. Runtime Options (Command Line Arguments) ---
# Global flags and settings that can be modified via command-line arguments.
# Exported if subprocesses rely on them (e.g., for consistent behavior).
declare -gi VERBOSE=0          # Verbose output flag (0=off, 1=on)
declare -gi DRY_RUN=0          # Dry run mode flag (0=off, 1=on)
declare -gi CACHE_DURATION=300 # Duration in seconds for which fetched data is cached
export CACHE_DURATION

# --- 7. CLI Arguments ---
# Stores application keys provided directly via the command line.
declare -g -a _CLI_APP_KEYS=()

# --- 8. Network Configuration & State ---
# Settings for network operations, including rate limiting and timeouts.
# LAST_API_CALL tracks the timestamp of the last API request for rate limiting.
declare -gi LAST_API_CALL=0    # Timestamp of the last network API call (Unix epoch)
readonly PW_CONNECT_TIMEOUT=1  # Seconds to wait for connection to establish
readonly PW_MAX_TIME=3         # Max seconds for a network operation (fast HEAD/GET)
readonly PW_RESOLVE_MAX_TIME=4 # Max seconds for URL resolution (redirects)

# Associative array for detailed network settings.
# This variable is modified by configs.sh, so it cannot be readonly.
declare -A NETWORK_CONFIG=(
    ["MAX_RETRIES"]=3                            # Maximum number of retries for failed network requests
    ["TIMEOUT"]=30                               # Default timeout in seconds for network operations
    ["USER_AGENT"]="Packwatch/${SCRIPT_VERSION}" # User-Agent string for HTTP requests
    ["RATE_LIMIT"]=1                             # Minimum seconds between API calls to prevent rate limiting
    ["RETRY_DELAY"]=2                            # Initial delay in seconds before retrying a failed request (exponential backoff)
)

# --- 9. Exit Codes & Error Codes ---
# Standardized exit codes for the application and detailed error type codes.
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_VALIDATION_ERROR=2
readonly EXIT_INITIALIZATION_ERROR=3
readonly EXIT_CONFIG_ERROR=4

# Associative array mapping error types to specific exit codes.
readonly -A ERROR_CODES=(
    ["NETWORK_ERROR"]=10
    ["CONFIG_ERROR"]=11
    ["PERMISSION_ERROR"]=12
    ["VALIDATION_ERROR"]=13
    ["DEPENDENCY_ERROR"]=14
    ["GPG_ERROR"]=15
    ["CUSTOM_CHECKER_ERROR"]=16
    ["INSTALLATION_ERROR"]=17
    ["INITIALIZATION_ERROR"]=18
    ["CLI_ERROR"]=19
    ["CACHE_ERROR"]=20
)

# --- 10. Application Types Configuration ---
# Defines required fields for different application types based on their update mechanism.
readonly -A APP_TYPE_VALIDATIONS=(
    ["github_release"]="repo_owner,repo_name,filename_pattern_template"
    ["direct_download"]="name,download_url"
    ["appimage"]="name,install_path,download_url"
    ["script"]="name,download_url,version_url,version_regex"
    ["flatpak"]="name,flatpak_app_id"
    ["custom"]="name,custom_checker_script,custom_checker_func"
    ["github_deb"]="repo_owner,repo_name,filename_pattern_template"
    ["custom_checker"]="name,custom_checker_script,custom_checker_func" # Alias for 'custom'
)

# --- 11. Dependency Injection Variables ---
# These variables hold function names that can be overridden, primarily for testing.
readonly UPDATES_DOWNLOAD_FILE_IMPL="${UPDATES_DOWNLOAD_FILE_IMPL:-networks::download_file}"
readonly UPDATES_GET_JSON_VALUE_IMPL="${UPDATES_GET_JSON_VALUE_IMPL:-systems::fetch_json}"
readonly UPDATES_PROMPT_CONFIRM_IMPL="${UPDATES_PROMPT_CONFIRM_IMPL:-interfaces::confirm_prompt}"
readonly UPDATES_GET_INSTALLED_VERSION_IMPL="${UPDATES_GET_INSTALLED_VERSION_IMPL:-packages::fetch_version}"
readonly UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL="${UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL:-packages::update_installed_version_json}"
readonly UPDATES_GET_LATEST_RELEASE_INFO_IMPL="${UPDATES_GET_LATEST_RELEASE_INFO_IMPL:-repositories::get_latest_release_info}"
readonly UPDATES_EXTRACT_DEB_VERSION_IMPL="${UPDATES_EXTRACT_DEB_VERSION_IMPL:-packages::extract_deb_version}"
readonly UPDATES_FLATPAK_SEARCH_IMPL="${UPDATES_FLATPAK_SEARCH_IMPL:-flatpak search}" # Direct binary call
readonly UPDATER_UTILS_CHECK_AND_GET_VERSION_FROM_DOWNLOAD_IMPL="${UPDATER_UTILS_CHECK_AND_GET_VERSION_FROM_DOWNLOAD_IMPL:-download_strategy::check_and_get_version_from_download}"

# --- 12. Extension Flags ---
# Flags and lists related to dynamically loaded extensions or features.
declare -gi _PACKWATCH_NEED_GPG=0                  # Flag: Set to 1 if any app requires GPG verification
declare -g -a _PACKWATCH_NEEDED_CUSTOM_CHECKERS=() # List of paths to custom checker scripts to be sourced

# --- 13. Application Counters ---
# Global counters for tracking application update statistics.
declare -Ag COUNTERS=(
    ["updated"]=0    # Number of applications successfully updated
    ["up_to_date"]=0 # Number of applications already up-to-date
    ["failed"]=0     # Number of applications that failed to update
    ["skipped"]=0    # Number of applications skipped (e.g., by user choice)
)

# --- 14. Systems State Variables ---
# Variables used by the systems module for managing temporary files, processes, and caching.
declare -a TEMP_FILES=()      # Tracks temporary files for cleanup on exit
declare -a BACKGROUND_PIDS=() # Tracks background process IDs for termination on exit
declare -gA _jq_cache=()      # Global cache for parsed JSON data (used by systems::fetch_json)
LOCK_FILE=""                  # Path to a lock file, if used, for process synchronization.
# Should be set by the main script, e.g., during initialization.

# --- 15. Verifiers Variables and Constants ---
# Variables and constants used by the verifiers module for artifact integrity checks.
declare -gi VERIFIERS_SIG_DOWNLOAD_USED_FALLBACK=0 # Flag: Set to 1 if signature download used a fallback URL (.asc instead of .sig)
VERIFIERS_SIG_DOWNLOAD_URL=""                      # Stores the final URL from which the signature was downloaded
readonly VERIFIER_TYPE_CHECKSUM="checksum"         # Constant: Type identifier for checksum verification
readonly VERIFIER_TYPE_SIGNATURE="signature"       # Constant: Type identifier for signature verification
readonly VERIFIER_ALGO_SHA256="sha256"             # Constant: Algorithm identifier for SHA256
readonly VERIFIER_ALGO_SHA512="sha512"             # Constant: Algorithm identifier for SHA512
readonly VERIFIER_ALGO_PGP="pgp"                   # Constant: Algorithm identifier for PGP (GPG)
readonly VERIFIER_HOOK_PHASE="verify"              # Constant: Hook phase name for verification events

# ==============================================================================
# Helpers
# ==============================================================================

# globals::validate_state
# Validates that critical global variables are set and directories exist.
# This function is typically called early in the main script's initialization.
# Returns 0 on success, 1 on validation failure.
globals::validate_state() {
    # CORE_DIR must be set by caller
    if [[ -z "${CORE_DIR:-}" ]]; then
        echo "CORE_DIR is not set" >&2
        return 1
    fi
    # Config directories
    if [[ ! -d "$CONFIG_ROOT" ]]; then
        echo "CONFIG_ROOT does not exist: $CONFIG_ROOT" >&2
        return 1
    fi
    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "CONFIG_DIR does not exist: $CONFIG_DIR" >&2
        return 1
    fi
    # Cache directory can be created lazily by systems::perform_housekeeping,
    # but ensure its path variable is valid.
    if [[ -z "${CACHE_DIR:-}" ]]; then
        echo "CACHE_DIR is empty" >&2
        return 1
    fi
    # User context
    if [[ -z "${ORIGINAL_USER:-}" ]]; then
        echo "ORIGINAL_USER is empty" >&2
        return 1
    fi
    return 0
}

# globals::freeze
# Optionally marks certain global variables as readonly after configuration
# has been fully loaded and processed. This helps prevent accidental modification
# of critical values during runtime.
# Safe to call multiple times; readonly on already-readonly variables is harmless in Bash.
globals::freeze() {
    # Example placeholder:
    # readonly SOME_CONFIG_VALUE
    return 0
}
