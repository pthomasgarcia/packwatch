#!/usr/bin/env bash
# ==============================================================================
# Packwatch: Global Variables
# ==============================================================================
# This file contains global variables and simple state helpers.
# Assumes SCRIPT_DIR is defined by the caller before sourcing.
# ==============================================================================

# --- Script and Path Configuration ---
SCRIPT_NAME="$(basename "$0")"
export SCRIPT_NAME
readonly SCRIPT_NAME

CONFIG_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")/config"
readonly CONFIG_ROOT

CONFIG_DIR="$CONFIG_ROOT/conf.d"
readonly CONFIG_DIR

# Export only variables that subprocesses may need to see
export CACHE_DIR="/tmp/app-updater-cache"
readonly CACHE_DIR

SCRIPT_VERSION="2.0.0"
readonly SCRIPT_VERSION

# --- User Context ---
readonly ORIGINAL_USER="${SUDO_USER:-$USER}"

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

# --- UI/Reporting Counters ---
# This state is now managed by the counters.sh module.
# The old declarations have been removed from this file.

# ==============================================================================
# Helpers
# ==============================================================================

globals::validate_state() {
  # SCRIPT_DIR must be set by caller
  if [[ -z "${SCRIPT_DIR:-}" ]]; then
    echo "SCRIPT_DIR is not set" >&2
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
  # Cache directory can be created lazily by systems::perform_housekeeping, but ensure it’s a valid path
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
