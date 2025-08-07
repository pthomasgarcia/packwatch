#!/usr/bin/env bash
# shellcheck disable=SC2034
# ==============================================================================
# Packwatch: Global Variables
# ==============================================================================
# This file contains global variables and simple state helpers.
# Assumes CORE_DIR is defined by the caller before sourcing.
#
# Dependencies:
#   - errors.sh
#   - interfaces.sh
#   - loggers.sh
# ==============================================================================

# --- Application Metadata ---
readonly APP_NAME="Packwatch"
readonly APP_DESCRIPTION="Application Update Checker"

SCRIPT_VERSION="2.0.0"
readonly SCRIPT_VERSION

SCRIPT_NAME="$(basename "$0")"
export SCRIPT_NAME
readonly SCRIPT_NAME

# --- ANSI Formatting Constants ---
readonly COLOR_RED=$'\033[0;31m'
readonly COLOR_GREEN=$'\033[0;32m'
readonly COLOR_YELLOW=$'\033[0;33m'
readonly COLOR_BLUE=$'\033[0;34m'
readonly COLOR_CYAN=$'\033[0;36m'
readonly FORMAT_BOLD=$'\033[1m'
readonly FORMAT_RESET=$'\033[0m'

# --- Path Configuration ---
CONFIG_ROOT="$(dirname "$(dirname "$CORE_DIR")")/config"
readonly CONFIG_ROOT

CONFIG_DIR="$CONFIG_ROOT/conf.d"
readonly CONFIG_DIR
 
 # Cache directory - exported for subprocesses that may need it
 export CACHE_DIR="/tmp/app-updater-cache"

# --- Required System Dependencies ---
readonly -a REQUIRED_COMMANDS=(
	"wget" "curl" "gpg" "jq" "dpkg"
	"sha256sum" "lsb_release" "getent"
)

# --- User Context ---
ORIGINAL_USER="${SUDO_USER:-$USER}"
readonly ORIGINAL_USER

# Initialize deferred error message variable (not exported)
_home_determination_error=""
if [[ -n "${SUDO_USER:-}" ]]; then
	determined_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
	if [[ -n "$determined_home" ]]; then
		readonly ORIGINAL_HOME="$determined_home"
	else
		_home_determination_error="Could not determine home directory for SUDO_USER: '$SUDO_USER'. Falling back to current HOME."
		readonly ORIGINAL_HOME="$HOME"
	fi
else
	readonly ORIGINAL_HOME="$HOME"
fi
export ORIGINAL_HOME

# --- Runtime Options (set by command line args) ---
# Keep in shell; export only if subprocesses rely on them.
VERBOSE=0
DRY_RUN=0
CACHE_DURATION=300 # seconds
export CACHE_DURATION

# --- Rate Limiting ---
LAST_API_CALL=0
API_RATE_LIMIT=1 # seconds

# --- Network Configuration ---
declare -A NETWORK_CONFIG=(
	["MAX_RETRIES"]=3
	["TIMEOUT"]=30
	["USER_AGENT"]="Packwatch/${SCRIPT_VERSION}"
	["RATE_LIMIT"]=1
	["RETRY_DELAY"]=2
)

# --- Exit Codes ---
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_VALIDATION_ERROR=2
readonly EXIT_INITIALIZATION_ERROR=3
readonly EXIT_CONFIG_ERROR=4

# ==============================================================================
# Helpers
# ==============================================================================

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
	# Cache directory can be created lazily by systems::perform_housekeeping, but ensure it's a valid path
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

# Optionally mark certain values readonly after configuration is loaded.
# Safe to call multiple times; readonly on already-readonly vars is harmless in Bash.
globals::freeze() {
	# If you have values overridden by configs, lock them here if desired.
	# Example placeholders:
	# readonly SOME_CONFIG_VALUE
	return 0
}
