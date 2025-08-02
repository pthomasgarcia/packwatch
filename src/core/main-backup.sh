#!/usr/bin/env bash
set -eo pipefail

# Source external modules
# CORE_DIR is /home/p/Documents/write/code/bash/packwatch/src/core
# Custom checkers are in /home/p/Documents/write/code/bash/packwatch/src/custom_checkers
# Lib scripts are in /home/p/Documents/write/code/bash/packwatch/src/lib
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gpg.sh"

# ==============================================================================
# SECTION: Global Variables for UI/Reporting
# ==============================================================================
declare -g UPDATED_APPS_COUNT=0
declare -g UP_TO_DATE_APPS_COUNT=0
declare -g FAILED_APPS_COUNT=0
declare -g SKIPPED_APPS_COUNT=0 # For disabled apps

# ==============================================================================
# SECTION: UI Colors and Formatting Helpers
# ==============================================================================

_color_red()    { printf '\033[31m%b\033[0m' "$1"; }
_color_green()  { printf '\033[32m%b\033[0m' "$1"; }
_color_yellow() { printf '\033[33m%b\033[0m' "$1"; }
_color_blue()   { printf '\033[34m%b\033[0m' "$1"; }
_color_cyan()   { printf '\033[36m%b\033[0m' "$1"; }
_bold()         { printf '\033[1m%b\033[0m' "$1"; }

# ==============================================================================
# SECTION: Loggers Module
# ==============================================================================

# Logger module; records log messages to STDERR.
# Used for internal debugging and error reporting, not user-facing progress.
loggers::log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$

    case "$level" in
    ERROR | CRITICAL)
        echo "[$timestamp] [PID:$pid] [$( _color_red "$level" )] $message" >&2
        ;;
    WARN)
        echo "[$timestamp] [PID:$pid] [$( _color_yellow "$level" )] $message" >&2
        ;;
    INFO)
        echo "[$timestamp] [PID:$pid] [INFO] $message" >&2
        ;;
    DEBUG)
        [[ $VERBOSE -eq 1 ]] && echo "[$timestamp] [PID:$pid] [DEBUG] $message" >&2
        ;;
    *)
        echo "[$timestamp] [PID:$pid] [INFO] $message" >&2
        ;;
    esac
}

# Logger module; prints standardized user-facing output to STDOUT.
# All user-facing progress/status messages should go through this function.
loggers::print_ui_line() {
    local indent="$1" # e.g., "  " or "    "
    local prefix="$2" # e.g., "→ ", "✓ ", "✗ "
    local message="$3"
    local color_func="${4:-printf}" # e.g., _color_green, _color_red

    # Use printf for consistent formatting and to avoid newlines if not desired
    printf "%s%s%b\n" "$indent" "$prefix" "$(${color_func} "$message")"
}

# Legacy function for simple messages. Prefer loggers::print_ui_line for structured output.
loggers::print_message() {
    printf "%b\n" "$*"
}


# ==============================================================================
# Packwatch: App Update Checker - Production Version (Refactored)
# ==============================================================================
# REQUIREMENTS:
# To install core dependencies:
# sudo apt update && sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release
#
# For Flatpak (if used, e.g., for Zed):
# Follow setup instructions: https://flatpak.org/setup/
#
# For VeraCrypt:
# Manually import VeraCrypt's GPG public key and verify its fingerprint:
# gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 5069A233D55A0EEB174A5FC3821ACD02680D16DE
# gpg --fingerprint 5069A233D55A0EEB174A5FC3821ACD02680D16DE
# Verify the fingerprint against the official VeraCrypt website.
# ==============================================================================

# Store the original user's name if sudo is used
# This allows commands to be run as the original user, e.g., for GPG or notifications.
if [[ -n "$SUDO_USER" ]]; then
    readonly ORIGINAL_USER="$SUDO_USER"
    # Use getent and check for empty result for robustness
    determined_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$determined_home" ]]; then
        readonly ORIGINAL_HOME="$determined_home"
    else
        loggers::log_message "ERROR" "Could not determine home directory for SUDO_USER: '$SUDO_USER'. Falling back to current HOME."
        readonly ORIGINAL_HOME="$HOME"
    fi
else
    readonly ORIGINAL_USER="$USER"
    readonly ORIGINAL_HOME="$HOME"
fi
# Final check: if ORIGINAL_USER is still empty or somehow problematic (shouldn't be if `id -u` passed basic check in entry point)
if [[ -z "$ORIGINAL_USER" ]]; then
    loggers::log_message "CRITICAL" "ORIGINAL_USER variable is empty. Some operations requiring user context may fail."
fi


# ==============================================================================
# SECTION: Global Variables and Configuration
# ==============================================================================

# Script configuration
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_DIR
# Updated CONFIG_DIR based on new path structure
# CORE_DIR is /home/p/Documents/write/code/bash/packwatch/src/core
# CONFIG_DIR should be /home/p/Documents/write/code/bash/packwatch/config
readonly CONFIG_ROOT="$(dirname "$(dirname "$CORE_DIR")")/config"
readonly CONFIG_DIR="$CONFIG_ROOT/conf.d"
readonly CACHE_DIR="/tmp/app-updater-cache"
# DEFAULT_CONFIG_FILE is removed as monolithic config is deprecated.
readonly SCRIPT_VERSION="1.1.1" # Incremented version for fixes

# Runtime options (set by command line args)
VERBOSE=0
DRY_RUN=0
# CONFIG_FILE variable is no longer needed as we always read from CONFIG_DIR/conf.d
CACHE_DURATION=300 # 5 minutes

# Rate limiting
LAST_API_CALL=0
API_RATE_LIMIT=1 # Seconds between API calls

# Cleanup tracking
declare -a TEMP_FILES=()
declare -a BACKGROUND_PIDS=()

declare -A ERROR_CODES=(
    ["NETWORK_ERROR"]=10
    ["CONFIG_ERROR"]=11
    ["PERMISSION_ERROR"]=12
    ["VALIDATION_ERROR"]=13
    ["DEPENDENCY_ERROR"]=14
    ["GPG_ERROR"]=15
    ["CUSTOM_CHECKER_ERROR"]=16 # Added new error type
    ["INSTALLATION_ERROR"]=17 # Added for explicit installation failures
)

declare -A NETWORK_CONFIG=(
    ["MAX_RETRIES"]=3
    ["TIMEOUT"]=30
    ["USER_AGENT"]="AppUpdater/1.0"
    ["RATE_LIMIT"]=1
    ["RETRY_DELAY"]=2
)

declare -A CONFIG_SCHEMA # This will be populated from schema.json

# ==============================================================================
# SECTION: Notifiers Module
# ==============================================================================

# Notifier module; sends desktop notifications.
notifiers::send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    if command -v notify-send &>/dev/null; then
        if [[ -n "$SUDO_USER" ]]; then
            local original_user_id
            original_user_id=$(getent passwd "$ORIGINAL_USER" | cut -d: -f3 2>/dev/null)
            if [[ -n "$original_user_id" ]]; then
                sudo -u "$ORIGINAL_USER" env \
                    DISPLAY=:0 \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${original_user_id}/bus" \
                    notify-send --urgency="$urgency" "$title" "$message" 2>/dev/null || true
            else
                loggers::log_message "WARN" "Could not determine user ID for '$ORIGINAL_USER'. Cannot send desktop notification."
            fi
        else
            notify-send --urgency="$urgency" "$title" "$message" 2>/dev/null || true
        fi
    fi
}

# ==============================================================================
# SECTION: Errors Module
# ==============================================================================

# Error module; handles and reports errors.
errors::handle_error() {
    local error_type="$1"
    local error_message="$2"
    local app_name="${3:-unknown}"

    local exit_code="${ERROR_CODES[$error_type]:-1}"

    loggers::log_message "ERROR" "[$error_type] $error_message (app: $app_name)"

    case "$error_type" in
    "NETWORK_ERROR")
        notifiers::send_notification "Network Error" "$error_message" "critical"
        ;;
    "PERMISSION_ERROR")
        notifiers::send_notification "Permission Error" "$error_message" "critical"
        ;;
    "GPG_ERROR")
        notifiers::send_notification "GPG Error" "$error_message" "critical"
        ;;
    "INSTALLATION_ERROR")
        notifiers::send_notification "Installation Error" "$error_message" "critical"
        ;;
    esac

    return "$exit_code"
}

# ==============================================================================
# SECTION: Systems Module (Uses Core Module Functions)
# ==============================================================================

# Systems module; re-attempts a given command multiple times.
systems::reattempt_command() {
    local max_attempts="${1:-${NETWORK_CONFIG[MAX_RETRIES]:-3}}"
    local delay_secs="${2:-${NETWORK_CONFIG[RETRY_DELAY]:-2}}"

    shift 2
    local cmd=("$@")

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        loggers::log_message "DEBUG" "Attempt $attempt/$max_attempts: ${cmd[*]}"
        if "${cmd[@]}"; then
            return 0
        fi
        loggers::log_message "WARN" "Command failed (attempt $attempt): ${cmd[*]}"
        if ((attempt < max_attempts)); then
            sleep "$delay_secs"
            delay_secs=$((delay_secs * 2)) # Exponential backoff
        fi
    done
    return 1 # Command failed after all attempts
}

# Core module; sanitizes a filename for safe usage.
systems::sanitize_filename() {
    local filename="$1"
    # shellcheck disable=SC2001
    echo "$filename" | sed 's/[^a-zA-Z0-9._-]/-/g'
}

# Systems module; creates a securely named temporary file.
systems::create_temp_file() {
    local template="$1"
    local temp_file

    template=$(systems::sanitize_filename "$template")

    temp_file=$(mktemp "/tmp/${template}.XXXXXX")
    if [[ -z "$temp_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: $template"
        return 1
    fi
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
    return 0
}

# Systems module; deletes all tracked temporary files.
systems::delete_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            loggers::log_message "DEBUG" "Removing temporary file: $f"
            rm -f "$f"
        fi
    done
}

# Systems module; unregisters a specific temporary file from cleanup tracking.
systems::unregister_temp_file() {
    local file_to_remove="$1"
    local i
    for i in "${!TEMP_FILES[@]}"; do
        if [[ "${TEMP_FILES[$i]}" == "$file_to_remove" ]]; then
            unset "TEMP_FILES[$i]"
            break
        fi
    done
}

# Systems module; Extracts a value from a JSON string using jq.
# Converts 'null' to an empty string. Reports jq errors.
systems::get_json_value() {
    local json_data="$1"
    local jq_expression="$2"
    local app_name="${3:-unknown}"
    local result=""

    result=$(echo "$json_data" | jq -r "$jq_expression // empty" 2>/dev/null)
    local jq_exit_code=$?

    if [[ "$jq_exit_code" -ne 0 ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to parse JSON for '$app_name' with expression: $jq_expression" "$app_name"
        return 1
    fi

    echo "$result"
    return 0
}

# Systems module; Extracts and validates a required value from a JSON string using jq.
# Fails if the JSON is malformed, or if the extracted value is empty/null.
systems::require_json_value() {
    local json_data="$1"
    local jq_expression="$2"
    local field_name="$3"
    local app_name="${4:-unknown}"
    local value=""

    value=$(systems::get_json_value "$json_data" "$jq_expression" "$app_name")
    local get_json_status=$?

    if [[ "$get_json_status" -ne 0 ]]; then
        return 1
    fi

    if [[ -z "$value" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Required field '$field_name' is missing or empty in JSON for '$app_name'. JQ expression: $jq_expression" "$app_name"
        return 1
    fi

    echo "$value"
    return 0
}

# Extracted helper: Kills background processes
systems::_clean_background_processes() {
    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

# Extracted helper: Cleans up cache files
systems::_clean_cache_files() {
    [[ -d "$CACHE_DIR" ]] && find "$CACHE_DIR" -type f -mmin +60 -delete 2>/dev/null
}

# Refactored main function
systems::perform_housekeeping() {
    local LAST_COMMAND_EXIT_CODE=$?
    [[ $VERBOSE -eq 1 ]] && loggers::log_message "DEBUG" "Cleanup triggered. Last command's exit code: $LAST_COMMAND_EXIT_CODE"

    systems::_clean_background_processes
    systems::delete_temp_files
    systems::_clean_cache_files
}

# Trap the cleanup function for both normal exit and errors.
trap systems::perform_housekeeping EXIT
trap systems::perform_housekeeping ERR

# ==============================================================================
# SECTION: Interfaces Module
# ==============================================================================

# Interfaces module; displays a standardized application header.
interfaces::display_header() {
    local app_name="$1"
    local current="$2"
    local total="$3"

    loggers::print_message ""
    loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    loggers::print_message "$(_bold "$(_color_cyan "[$current/$total] $app_name")")"
    loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Interfaces module; prompts the user for a yes/no confirmation.
# Interfaces module; prompts the user for a yes/no confirmation.
interfaces::confirm_prompt() {
    local message="$1"
    local default_resp_char="${2:-N}" # 'Y' or 'N'
    local prompt_suffix=""
    local response

    if [[ "$default_resp_char" == "Y" ]]; then
        prompt_suffix=" (Y/n): "
    else
        prompt_suffix=" (y/N): "
    fi

    # The critical fix is `< /dev/tty`, which forces read to use the
    # keyboard/terminal directly, bypassing any stdin issues caused by sudo.
    # The `|| true` remains as a safeguard against Ctrl+D.
    read -rp "$(_bold "$message")$prompt_suffix" response < /dev/tty || true

    local lower_response
    lower_response="${response,,}"

    case "$lower_response" in
    "y" | "yes") return 0 ;;
    "n" | "no") return 1 ;;
    "") [[ "$default_resp_char" == "Y" ]] && return 0 || return 1 ;;
    *) return 1 ;;
    esac
}

# ==============================================================================
# SECTION: Validators Module
# ==============================================================================

# Validators module; checks if a URL format is valid.
validators::check_url_format() {
    local url="$1"
    [[ -n "$url" ]] && [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]
}

# Validators module; checks if a file path is safe (prevents directory traversal).
validators::check_file_path() {
    local path="$1"
    [[ -n "$path" ]] && \
    [[ ! "$path" =~ \.\. ]] && \
    [[ "$path" =~ ^(~|\/)([a-zA-Z0-9.\/_-]*)$ ]]
}

# Validators module; checks if a file is executable.
validators::check_executable_file() {
    local file_path="$1"
    [[ -f "$file_path" ]] && [[ -x "$file_path" ]] && validators::check_file_path "$file_path"
}

# Validators module; verifies a file's checksum against an expected value.
validators::verify_checksum() {
    local file_path="$1"
    local expected_checksum="$2"
    local algorithm="${3:-sha256}" # Default to sha256 if not provided

    if [[ ! -f "$file_path" ]]; then
        errors::handle_error "VALIDATION_ERROR" "File not found for checksum verification: '$file_path'"
        return 1
    fi

    local actual_checksum
    case "$algorithm" in
    sha256) actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1) ;;
    sha1) actual_checksum=$(sha1sum "$file_path" | cut -d' ' -f1) ;;
    md5) actual_checksum=$(md5sum "$file_path" | cut -d' ' -f1) ;;
    *)
        errors::handle_error "VALIDATION_ERROR" "Unsupported checksum algorithm: '$algorithm'"
        return 1
        ;;
    esac

    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Checksum mismatch for '$file_path': expected '$expected_checksum', got '$actual_checksum'"
        return 1
    fi

    loggers::log_message "DEBUG" "Checksum verified for '$file_path'"
    loggers::print_ui_line "  " "✓ " "Checksum verified." _color_green
    return 0
}

# Validators module; verifies a GPG key's fingerprint against an expected value.
validators::verify_gpg_key() {
    local key_id="$1"
    local expected_fingerprint="$2"
    local app_name="${3:-unknown}" # Added app_name for better error context

    if [[ -z "$key_id" ]] || [[ -z "$expected_fingerprint" ]]; then
        errors::handle_error "GPG_ERROR" "Missing GPG key ID or fingerprint for GPG verification" "$app_name"
        return 1
    fi

    local actual_fingerprint
    local original_user_id_for_sudo=""
    if [[ -n "$ORIGINAL_USER" ]]; then
        original_user_id_for_sudo=$(getent passwd "$ORIGINAL_USER" | cut -d: -f3 2>/dev/null)
    fi

    if [[ -z "$original_user_id_for_sudo" ]]; then
        loggers::log_message "WARN" "ORIGINAL_USER is invalid or empty ('$ORIGINAL_USER'). Cannot perform GPG verification as original user. Attempting as current user (root)."
        actual_fingerprint=$(gpg --fingerprint --with-colons "$key_id" 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | head -n1)
    else
        actual_fingerprint=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
            gpg --fingerprint --with-colons "$key_id" 2>/dev/null | \
            awk -F: '/^fpr:/ {print $10}' | head -n1)
    fi

    if [[ -z "$actual_fingerprint" ]]; then
        errors::handle_error "GPG_ERROR" "GPG key not found in keyring for user '$ORIGINAL_USER': '$key_id'" "$app_name"
        loggers::log_message "INFO" "Please import the VeraCrypt GPG key manually and verify its fingerprint:"
        loggers::log_message "INFO" "  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys '$key_id'"
        loggers::log_message "INFO" "  gpg --fingerprint '$key_id'"
        loggers::log_message "INFO" "Compare the fingerprint carefully with the official VeraCrypt website."
        return 1
    fi

    local normalized_expected
    normalized_expected="${expected_fingerprint//[[:space:]]/}"
    local normalized_actual
    normalized_actual="${actual_fingerprint//[[:space:]]/}"

    if [[ "$normalized_actual" != "$normalized_expected" ]]; then
        errors::handle_error "GPG_ERROR" "GPG key fingerprint mismatch. Expected: '$expected_fingerprint', Got: '$actual_fingerprint'" "$app_name"
        return 1
    fi

    loggers::log_message "DEBUG" "GPG key verification successful for: '$key_id'"
    loggers::print_ui_line "  " "✓ " "GPG key verified: $key_id" _color_green
    return 0
}

# ==============================================================================
# SECTION: Networks Module
# ==============================================================================

# Networks module; decodes HTML-encoded characters in a URL.
networks::decode_url() {
    local encoded_url="$1"
    echo "$encoded_url" | sed -e 's/&#43;/+/g' -e 's/%2B/+/g'
}

# Networks module; applies a rate limit to API calls.
networks::apply_rate_limit() {
    local current_time
    current_time=$(date +%s)
    local time_diff=$((current_time - LAST_API_CALL))

    if ((time_diff < API_RATE_LIMIT)); then
        local sleep_duration=$((API_RATE_LIMIT - time_diff))
        loggers::log_message "DEBUG" "Rate limiting: sleeping for ${sleep_duration}s"
        sleep "$sleep_duration"
    fi

    LAST_API_CALL=$(date +%s)
}

# Networks module; builds standard curl arguments.
networks::build_curl_args() {
    local output_file="$1"
    local timeout_multiplier="${2:-4}"
    local timeout_val="${NETWORK_CONFIG[TIMEOUT]:-10}"

    local args=(
        "-L" "--fail" "--output" "$output_file"
        "--connect-timeout" "$timeout_val"
        "--max-time" "$((timeout_val * timeout_multiplier))"
        "-A" "${NETWORK_CONFIG[USER_AGENT]:-AppUpdater/1.0}"
        "-s"
    )

    printf '%s\n' "${args[@]}"
}

# Networks module; fetches data from a URL, using cache if available.
networks::fetch_cached_data() {
    local url="$1"
    local expected_type="$2" # "json", "html", "raw"
    local cache_key
    cache_key=$(echo -n "$url" | sha256sum | cut -d' ' -f1) # Using -n for portability
    local cache_file="$CACHE_DIR/$cache_key"
    local temp_download_file

    mkdir -p "$CACHE_DIR" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create cache directory: '$CACHE_DIR'"
        return 1
    }

    # Check cache first
    if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt $CACHE_DURATION ]]; then
        loggers::log_message "DEBUG" "Using cached response for: '$url' (file: '$cache_file')"
        cat "$cache_file"
        return 0
    else
        # loggers::log_message "DEBUG" "Fetching fresh response for: '$url'"
        networks::apply_rate_limit

        temp_download_file=$(systems::create_temp_file "fetch_response")
        if [[ $? -ne 0 ]]; then return 1; fi # Error already logged in systems::create_temp_file

        local -a curl_args=($(networks::build_curl_args "$temp_download_file" 4))

        if ! systems::reattempt_command 3 5 curl "${curl_args[@]}" "$url"; then
            errors::handle_error "NETWORK_ERROR" "Failed to download '$url' after multiple attempts."
            return 1
        fi

        case "$expected_type" in
        "json")
            if ! jq . "$temp_download_file" >/dev/null 2>&1; then
                errors::handle_error "VALIDATION_ERROR" "Fetched content for '$url' is not valid JSON."
                return 1
            fi
            ;;
        "html")
            if ! grep -q '<html' "$temp_download_file" >/dev/null 2>&1 && ! grep -q '<!DOCTYPE html>' "$temp_download_file" >/dev/null 2>&1; then
                loggers::log_message "WARN" "Fetched content for '$url' might not be valid HTML, but continuing."
            fi
            ;;
        esac

        mv "$temp_download_file" "$cache_file" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to move temporary file '$temp_download_file' to cache '$cache_file' for '$url'"
            return 1
        }

        cat "$cache_file"
        return 0
    fi
}

# Networks module; downloads a file from a given URL.
networks::download_file() {
    local url="$1"
    local dest_path="$2"
    local expected_checksum="$3"
    local checksum_algorithm="${4:-sha256}"

    loggers::print_ui_line "  " "→ " "Downloading $(basename "$dest_path")..."

    if [[ $DRY_RUN -eq 1 ]]; then
        loggers::print_ui_line "    " "[DRY RUN] " "Would download: '$url'" _color_yellow
        return 0
    fi

    if [[ -z "$url" ]]; then
        errors::handle_error "NETWORK_ERROR" "Download URL is empty for destination: '$dest_path'."
        return 1
    fi

    local -a curl_args=($(networks::build_curl_args "$dest_path" 10))

    if ! systems::reattempt_command 3 5 curl "${curl_args[@]}" "$url"; then
        errors::handle_error "NETWORK_ERROR" "Failed to download '$url' after multiple attempts."
        return 1
    fi

    if [[ -n "$expected_checksum" ]]; then
        loggers::log_message "DEBUG" "Attempting checksum verification for '$dest_path' with expected: '$expected_checksum', algorithm: '$checksum_algorithm'"
        if ! validators::verify_checksum "$dest_path" "$expected_checksum" "$checksum_algorithm"; then
            errors::handle_error "VALIDATION_ERROR" "Checksum verification failed for downloaded file: '$dest_path'"
            return 1
        fi
    else
        loggers::log_message "DEBUG" "No expected checksum provided for '$dest_path'. Skipping verification."
    fi

    return 0
}

# ==============================================================================
# SECTION: GitHub Module (Refactored)
# ==============================================================================

# GitHub module; fetches the latest release JSON from the GitHub API.
github::get_latest_release_info() {
    local repo_owner="$1"
    local repo_name="$2"
    local api_url="https://api.github.com/repos/${repo_owner}/${repo_name}/releases"
    
    networks::fetch_cached_data "$api_url" "json"
}

# GitHub module; parses the version from a release JSON object.
github::parse_version_from_release() {
    local release_json="$1"
    local app_name="$2"
    
    local raw_tag_name
    raw_tag_name=$(systems::get_json_value "$release_json" '.tag_name' "$app_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    local latest_version
    latest_version=$(versions::normalize "$raw_tag_name" | grep -oE '^[0-9]+(\.[0-9]+)*(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?' | head -n1)
    
    if [[ -z "$latest_version" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to detect latest version for '$app_name' from tag '$raw_tag_name'." "$app_name"
        return 1
    fi
    
    echo "$latest_version"
}

# GitHub module; finds a specific asset's download URL from a release JSON.
github::find_asset_url() {
    local release_json="$1"
    local filename_pattern="$2"
    local app_name="$3"
    
    systems::get_json_value "$release_json" ".assets[] | select(.name | test(\"\\Q${filename_pattern}\\E\")) | .browser_download_url" "$app_name"
}

# GitHub module; finds and extracts a checksum for a given asset from a release.
github::find_asset_checksum() {
    local release_json="$1"
    local target_filename="$2"

    local checksum_file_url
    checksum_file_url=$(systems::get_json_value "$release_json" '.assets[] | select(.name | (endswith("sha256sum.txt") or endswith("checksums.txt"))) | .browser_download_url' "GitHub Release Checksum URL")
    if [[ $? -ne 0 || -z "$checksum_file_url" ]]; then
        return 0 # Not an error if checksum file doesn't exist
    fi

    local temp_checksum_file
    temp_checksum_file=$(systems::create_temp_file "checksum_file")
    if [[ $? -ne 0 ]]; then return 1; fi

    local extracted_checksum=""
    if networks::download_file "$checksum_file_url" "$temp_checksum_file" ""; then
        local checksum_file_content
        checksum_file_content=$(cat "$temp_checksum_file")
        extracted_checksum=$(echo "$checksum_file_content" | grep -oP "^\s*[0-9a-fA-F]+\s+[\*]?${target_filename}\s*$" | awk '{print $1}' | head -n1)
    else
        loggers::log_message "WARN" "Failed to download checksum file from '$checksum_file_url'"
    fi

    rm -f "$temp_checksum_file"
    systems::unregister_temp_file "$temp_checksum_file"
    echo "$extracted_checksum"
    return 0
}

# ==============================================================================
# SECTION: Versions Module
# ==============================================================================

# Versions module; compares two semantic version strings.
versions::compare_strings() {
    if [[ $# -ne 2 ]]; then
        errors::handle_error "VALIDATION_ERROR" "versions::compare_strings requires two arguments."
        return 3
    fi

    local v1="$1"
    local v2="$2"

    v1=$(echo "$v1" | grep -oE '^[0-9]+(\.[0-9]+)*')
    v2=$(echo "$v2" | grep -oE '^[0-9]+(\.[0-9]+)*')

    if [[ -z "$v1" ]]; then v1="0"; fi
    if [[ -z "$v2" ]]; then v2="0"; fi

    if dpkg --compare-versions "$v1" gt "$v2" 2>/dev/null; then
        return 0
    elif dpkg --compare-versions "$v1" lt "$v2" 2>/dev/null; then
        return 2
    else
        return 1
    fi
}

# Versions module; checks if a version string is newer than another.
versions::is_newer() {
    versions::compare_strings "$1" "$2"
    local result=$?
    if [[ "$result" -eq 0 ]]; then # $1 (latest) > $2 (current)
        return 0
    fi
    return 1 # Not newer
}

versions::normalize() {
    local version="$1"
    echo "$version" | sed -E 's/^[vV]//' | xargs
}

# ==============================================================================
# SECTION: Packages Module
# ==============================================================================

# Packages module; gets the installed version from the centralized JSON file.
packages::get_installed_version_from_json() {
    local app_key="$1"
    local versions_file="$CONFIG_ROOT/installed_versions.json"
    
    if [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "App key is empty"
        return 1
    fi
    
    if [[ ! -f "$versions_file" ]]; then
        loggers::log_message "DEBUG" "Installed versions file not found: '$versions_file'. Assuming app not installed."
        echo "0.0.0"
        return 0
    fi
    
    local version
    version=$(systems::get_json_value "$(cat "$versions_file")" ".\"$app_key\"" "$app_key")
    
    if [[ $? -ne 0 ]]; then
        loggers::log_message "DEBUG" "Failed to parse installed versions JSON file for app: '$app_key'"
        echo "0.0.0"
        return 0
    fi
    
    if [[ -z "$version" ]]; then
        loggers::log_message "DEBUG" "No installed version found for app: '$app_key'"
        echo "0.0.0"
        return 0
    fi
    
    echo "$version"
    return 0
}

# Packages module; updates the installed version in the centralized JSON file.
packages::update_installed_version_json() {
    local app_key="$1"
    local new_version="$2"
    local versions_file="$CONFIG_ROOT/installed_versions.json"
    
    if [[ -z "$app_key" ]] || [[ -z "$new_version" ]]; then
        errors::handle_error "VALIDATION_ERROR" "App key or version is empty for JSON update"
        return 1
    fi
    
    loggers::log_message "DEBUG" "Updating installed version for '$app_key' to '$new_version' in '$versions_file'"
    
    # Ensure the directory exists
    mkdir -p "$(dirname "$versions_file")" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create directory for versions file: '$(dirname "$versions_file")'"
        return 1
    }
    
    # Initialize file if it doesn't exist
    if [[ ! -f "$versions_file" ]]; then
        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to initialize versions file: '$versions_file'"
            return 1
        }
    fi
    
    # Create a temporary file for the update
    local temp_versions_file
    temp_versions_file=$(systems::create_temp_file "versions_update")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    # Update the JSON file
    if jq --arg key "$app_key" --arg version "$new_version" '.[$key] = $version' "$versions_file" > "$temp_versions_file"; then
        if mv "$temp_versions_file" "$versions_file"; then
            systems::unregister_temp_file "$temp_versions_file"
            loggers::log_message "DEBUG" "Successfully updated installed version for '$app_key'"
            # Ownership fix: ensure file is owned by the original user
            if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &>/dev/null; then
                chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$versions_file" 2>/dev/null || \
                loggers::log_message "WARN" "Failed to change ownership of '$versions_file' to '$ORIGINAL_USER'."
            fi
            return 0
        else
            errors::handle_error "PERMISSION_ERROR" "Failed to move updated versions file from '$temp_versions_file' to '$versions_file'"
            return 1
        fi
    else
        errors::handle_error "VALIDATION_ERROR" "Failed to update JSON for app '$app_key' with version '$new_version'"
        return 1
    fi
}

# Packages module; initializes the installed versions JSON file if it doesn't exist.
packages::initialize_installed_versions_file() {
    local versions_file="$CONFIG_ROOT/installed_versions.json"
    
    if [[ ! -f "$versions_file" ]]; then
        loggers::log_message "INFO" "Initializing installed versions file: '$versions_file'"
        mkdir -p "$(dirname "$versions_file")" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to create directory for versions file"
            return 1
        }
        
        echo '{}' > "$versions_file" || {
            errors::handle_error "PERMISSION_ERROR" "Failed to create versions file: '$versions_file'"
            return 1
        }
    fi
    return 0
}

# Packages module; gets the installed version of an application from centralized JSON.
packages::get_installed_version() {
    local app_key="$1"
    packages::get_installed_version_from_json "$app_key"
}

# Packages module; extracts the version from a Debian package file.
packages::extract_deb_version() {
    local deb_file="$1"
    local version=""

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "DEB file not found: '$deb_file'"
        return 1
    fi

    version=$(dpkg-deb -f "$deb_file" Version 2>/dev/null)

    if [[ -z "$version" ]]; then
        version=$(basename "$deb_file" | grep -oE '^[0-9]+(\.[0-9]+)*(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?' | head -n1)
    fi

    echo "${version:-0.0.0}"
}

# Packages module; installs a Debian package.
packages::install_deb_package() {
    local deb_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"

    if [[ -z "$deb_file" ]] || [[ -z "$app_name" ]] || [[ -z "$version" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Missing required parameters for DEB installation"
        return 1
    fi

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "VALIDATION_ERROR" "DEB file not found: '$deb_file'" "$app_name"
        return 1
    fi

    loggers::print_ui_line "  " "→ " "Attempting to install $(_bold "$app_name") v$version..."

    if [[ $DRY_RUN -eq 1 ]]; then
        loggers::print_ui_line "    " "[DRY RUN] " "Would install v$version from: '$deb_file'" _color_yellow
        packages::update_installed_version_json "$app_key" "$version"
        return 0
    fi

    if [[ $(id -u) -ne 0 ]]; then
        errors::handle_error "PERMISSION_ERROR" "Installation requires root privileges. Please run the script with 'sudo'" "$app_name"
        return 1
    fi

    local install_output
    if ! install_output=$(apt install -y "$deb_file" 2>&1); then
        errors::handle_error "INSTALLATION_ERROR" "Package installation failed for '$app_name'."

        if [[ "$app_name" == "VeraCrypt" ]] && echo "$install_output" | grep -q "VeraCrypt volumes must be dismounted"; then
            errors::handle_error "PERMISSION_ERROR" "VeraCrypt volumes must be dismounted to perform this update" "$app_name"
        else
            loggers::log_message "INFO" "See apt output below for details:"
            echo "$install_output" >&2
        fi

        return 1
    fi

    if ! packages::update_installed_version_json "$app_key" "$version"; then
        loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but installation was successful."
    fi

    loggers::print_ui_line "  " "✓ " "Successfully installed $(_bold "$app_name") v$version" _color_green
    notifiers::send_notification "$app_name Updated" "Successfully installed v$version" "normal"
    return 0
}

# ==============================================================================
# SECTION: Configs Module (Refactored)
# ==============================================================================

# Configs module; validates a single modular application configuration.
configs::validate_single_config_file() {
    local config_file_path="$1"
    local filename="$(basename "$config_file_path")"
    local file_content
    file_content=$(cat "$config_file_path")

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

    local expected_filename="$(echo "$app_key" | tr '[:upper:]' '[:lower:]').json"
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

# Configs helper; loads the configuration schema from schema.json.
configs::load_schema() {
    local schema_file="$1"
    
    if [[ ! -f "$schema_file" ]]; then
        errors::handle_error "CONFIG_ERROR" "Configuration schema file not found: '$schema_file'."
        return 1
    fi
    
    local schema_content
    schema_content=$(cat "$schema_file")
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

# Configs helper; finds, validates, and merges all enabled config files into a JSON array.
configs::get_validated_apps_json() {
    local conf_dir="$1"
    
    if [[ ! -d "$conf_dir" ]]; then
        errors::handle_error "CONFIG_ERROR" "Modular configuration directory not found: '$conf_dir'."
        return 1
    fi
    
    local config_files=()
    while IFS= read -r -d '' file; do
        config_files+=("$file")
    done < <(find "$conf_dir" -maxdepth 1 -name "*.json" -not -name ".*" -not -name "_*" -type f -print0)
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        errors::handle_error "CONFIG_ERROR" "No config files found in: '$conf_dir'."
        return 1
    fi
    
    local merged_json_array="[]"
    local validated_and_enabled_files=0
    
    for file in "${config_files[@]}"; do
        if configs::validate_single_config_file "$file"; then
            local file_content
            file_content=$(cat "$file")
            local enabled_status_check
            enabled_status_check=$(systems::get_json_value "$file_content" '.enabled' "$(basename "$file")")
            if [[ "$enabled_status_check" == "true" ]]; then
                merged_json_array=$(echo "$merged_json_array" | jq --argjson item "$file_content" '. + [$item]')
                ((validated_and_enabled_files++))
            else
                loggers::log_message "INFO" "Skipping disabled config file: '$(basename "$file")'"
                ((SKIPPED_APPS_COUNT++))
            fi
        else
            loggers::log_message "WARN" "Skipping invalid config file: '$(basename "$file")' (error logged above)"
            ((FAILED_APPS_COUNT++))
        fi
    done
    
    if [[ "$validated_and_enabled_files" -eq 0 ]]; then
        errors::handle_error "CONFIG_ERROR" "No valid and enabled application configurations found."
        return 1
    fi
    
    echo "$merged_json_array"
}

# Configs helper; populates the global config variables from a merged JSON array.
configs::populate_globals_from_json() {
    local merged_json_array="$1"
    
    local apps_to_check_json="[]"
    local applications_json="{}"

    while IFS= read -r app_json; do
        local app_key
        app_key=$(systems::get_json_value "$app_json" '.app_key' "Config transformation") || continue
        apps_to_check_json=$(echo "$apps_to_check_json" | jq --arg key "$app_key" '. + [$key]')
        
        local app_details_json
        app_details_json=$(echo "$app_json" | jq '.application' 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            loggers::log_message "ERROR" "Failed to extract application block for key: '$app_key'. Skipping."
            ((FAILED_APPS_COUNT++))
            continue
        fi
        applications_json=$(echo "$applications_json" | jq --arg key "$app_key" --argjson details "$app_details_json" '. + {($key): $details}')
    done < <(echo "$merged_json_array" | jq -c '.[]')

    mapfile -t CUSTOM_APP_KEYS < <(echo "$apps_to_check_json" | jq -r '.[]')

    local app_key prop_key prop_value
    while IFS= read -r app_key; do
        [[ -z "$app_key" ]] && continue
        while IFS= read -r prop_key; do
            [[ -z "$prop_key" || "$prop_key" == "_comment"* ]] && continue
            prop_value=$(systems::get_json_value "$applications_json" ".\"$app_key\".\"$prop_key\"" "Property '$prop_key' for '$app_key'")
            if [[ $? -eq 0 && -n "$prop_value" ]]; then
                ALL_APP_CONFIGS["${app_key}_${prop_key}"]="$prop_value"
            fi
        done < <(echo "$applications_json" | jq -r --arg app_key "$app_key" '.[$app_key] | keys[]')
    done < <(echo "$applications_json" | jq -r 'keys[]')
}

# Configs module; orchestrates loading configuration from the modular directory.
configs::load_modular_directory() {
    if ! configs::load_schema "$CONFIG_ROOT/schema.json"; then
        return 1
    fi
    
    local merged_json
    merged_json=$(configs::get_validated_apps_json "$CONFIG_DIR")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    configs::populate_globals_from_json "$merged_json"
    
    loggers::log_message "INFO" "Successfully loaded ${#CUSTOM_APP_KEYS[@]} enabled modular configurations from: '$CONFIG_DIR'"
    return 0
}

# Configs module; creates the default configuration directory and files.
configs::create_default_files() {
    local target_conf_dir="${CONFIG_DIR}"
    
    mkdir -p "$target_conf_dir" || {
        errors::handle_error "PERMISSION_ERROR" "Failed to create config directory: '$target_conf_dir'"
        return 1
    }

    loggers::print_message "Creating default modular configuration files in: '$target_conf_dir'"

    local default_app_configs=$(cat <<'EOF'
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
        local filename="$(echo "$app_key" | tr '[:upper:]' '[:lower:]').json"
        local target_file="${target_conf_dir}/$filename"
        
        if [[ ! -f "$target_file" ]]; then
            echo "$default_app_configs" | jq --arg key "$app_key" '.[$key]' > "$target_file"
            if [[ $? -eq 0 ]]; then
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


# ==============================================================================
# SECTION: Updates Module
# ==============================================================================

# Updates module; determines if an update is needed by comparing versions.
updates::is_needed() {
    local current_version="$1"
    local latest_version="$2"
    versions::is_newer "$latest_version" "$current_version"
}

# Extracted helper for DEB renaming
updates::_rename_deb_file() {
    local current_path="$1"
    local template="$2"
    local version="$3"
    local app_name="$4"

    local target_filename
    target_filename=$(printf "$template" "$version")
    target_filename=$(systems::sanitize_filename "$target_filename")
    local new_path="/tmp/$target_filename"

    if [[ "$current_path" != "$new_path" ]]; then
        if mv "$current_path" "$new_path"; then
            systems::unregister_temp_file "$current_path"
            TEMP_FILES+=("$new_path")
            echo "$new_path"
            return 0
        else
            loggers::log_message "WARN" "Failed to rename downloaded DEB to '$new_path'. Proceeding with original name."
            echo "$current_path"
            return 1
        fi
    fi
    echo "$current_path"
    return 0
}

# New generic helper to handle GPG verification flow if configured
updates::_handle_gpg_verification() {
    local -n app_config_ref=$1
    local deb_path="$2"
    local download_url="$3"
    local app_name="${app_config_ref[name]}"

    local key_id="${app_config_ref[gpg_key_id]:-}"
    local fingerprint="${app_config_ref[gpg_fingerprint]:-}"

    if [[ -z "$key_id" ]] || [[ -z "$fingerprint" ]]; then
        loggers::log_message "DEBUG" "No GPG configuration for '$app_name'. Skipping verification."
        return 0
    fi

    if ! gpg::prompt_import_and_verify "$key_id" "$fingerprint" "$app_name"; then
        return 1
    fi

    local sig_download_url="${download_url}.sig"
    if ! updates::_verify_gpg_signature "$sig_download_url" "$deb_path" "$app_name"; then
        return 1
    fi

    return 0
}

updates::process_deb_package() {
    local app_name="$1"
    local app_key="$2"
    local gpg_key_id="$3"
    local gpg_fingerprint="$4"
    local deb_filename_template="$5"
    local latest_version="$6"
    local download_url="$7"
    local deb_file_to_install="${8:-}"
    local expected_checksum="${9:-}"
    local checksum_algorithm="${10:-sha256}"

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url"; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for DEB update flow" "$app_name"
        return 1
    fi

    # Create a local config array for GPG verification helper
    declare -A local_app_config=(
        ["name"]="$app_name"
        ["app_key"]="$app_key"
        ["gpg_key_id"]="$gpg_key_id"
        ["gpg_fingerprint"]="$gpg_fingerprint"
    )

    local final_deb_path
    if [[ -n "$deb_file_to_install" && -f "$deb_file_to_install" ]]; then
        final_deb_path="$deb_file_to_install"
        loggers::log_message "DEBUG" "Using pre-downloaded DEB: '$final_deb_path'"
    else
        local temp_deb_file
        local base_filename
        base_filename="$(basename "${download_url}" | cut -d'?' -f1 | sed 's/\.deb$//')"
        base_filename=$(systems::sanitize_filename "$base_filename")
        temp_deb_file=$(systems::create_temp_file "${base_filename}")
        if [[ $? -ne 0 ]]; then return 1; fi
        temp_deb_file="${temp_deb_file}.deb"

        if ! networks::download_file "$download_url" "$temp_deb_file" "$expected_checksum" "$checksum_algorithm"; then
            errors::handle_error "NETWORK_ERROR" "Failed to download DEB package" "$app_name"
            return 1
        fi
        final_deb_path="$temp_deb_file"
    fi

    if ! updates::_handle_gpg_verification local_app_config "$final_deb_path" "$download_url"; then
        loggers::log_message "ERROR" "GPG verification failed for $app_name. Aborting installation."
        return 1
    fi

    if [[ -n "$deb_filename_template" ]]; then
        local renamed_path
        renamed_path=$(updates::_rename_deb_file "$final_deb_path" "$deb_filename_template" "$latest_version" "$app_name")
        if [[ $? -ne 0 ]]; then
            loggers::log_message "WARN" "Proceeding with original DEB file name."
        fi
        final_deb_path="$renamed_path"
    fi

    local current_installed_version
    current_installed_version=$(packages::get_installed_version "$app_key")
    local prompt_msg="Do you want to install $(_bold "$app_name") v$latest_version?"
    if [[ "$current_installed_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update $(_bold "$app_name") to v$latest_version?"
    fi

    notifiers::send_notification "$app_name Update Available" "v$latest_version downloaded" "normal"

    if interfaces::confirm_prompt "$prompt_msg" "Y"; then
        if ! packages::install_deb_package "$final_deb_path" "$app_name" "$latest_version" "$app_key"; then
            return 1
        fi
        ((UPDATED_APPS_COUNT++))
    else
        loggers::print_ui_line "  " "🞨 " "Installation skipped." _color_yellow
        ((SKIPPED_APPS_COUNT++)) # FIX: Increment skipped counter
    fi
    return 0
}

# Updates module; checks for updates for a GitHub DEB application. (Refactored)
updates::check_github_deb() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local repo_owner="${app_config_ref[repo_owner]}"
    local repo_name="${app_config_ref[repo_name]}"
    local filename_pattern_template="${app_config_ref[filename_pattern_template]}"
    local source="GitHub Releases"

    loggers::print_ui_line "  " "→ " "Checking GitHub releases for $(_bold "$name")..."
    
    local installed_version
    installed_version=$(versions::normalize "$(packages::get_installed_version "$app_key")")
    
    local api_response
    api_response=$(github::get_latest_release_info "$repo_owner" "$repo_name")
    if [[ $? -ne 0 ]]; then
        loggers::print_ui_line "  " "✗ " "Failed to fetch GitHub releases for '$name'." _color_red
        return 1
    fi

    local latest_release_json
    latest_release_json=$(systems::get_json_value "$api_response" '.[0]' "$name")
    if [[ $? -ne 0 ]]; then
        loggers::print_ui_line "  " "✗ " "Failed to parse latest release information." _color_red
        return 1
    fi

    local latest_version
    latest_version=$(github::parse_version_from_release "$latest_release_json" "$name")
    if [[ $? -ne 0 ]]; then
        loggers::print_ui_line "  " "✗ " "Failed to get version from latest release." _color_red
        return 1
    fi

    loggers::print_ui_line "  " "Installed: " "$installed_version"
    loggers::print_ui_line "  " "Source:    " "$source"
    loggers::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        loggers::print_ui_line "  " "⬆ " "New version available: $latest_version" _color_yellow
        local download_filename
        download_filename=$(printf "$filename_pattern_template" "$latest_version")

        local download_url
        download_url=$(github::find_asset_url "$latest_release_json" "$download_filename" "$name")
        if [[ $? -ne 0 || -z "$download_url" ]] || ! validators::check_url_format "$download_url"; then
            loggers::print_ui_line "  " "✗ " "Download URL not found or invalid for '$download_filename'." _color_red
            return 1
        fi

        local expected_checksum
        expected_checksum=$(github::find_asset_checksum "$latest_release_json" "$download_filename")
        if [[ $? -ne 0 ]]; then
            loggers::print_ui_line "  " "✗ " "Failed to get GitHub checksum." _color_red
            return 1
        fi

        updates::process_deb_package \
            "$name" \
            "$app_key" \
            "${app_config_ref[gpg_key_id]:-}" \
            "${app_config_ref[gpg_fingerprint]:-}" \
            "$filename_pattern_template" \
            "$latest_version" \
            "$download_url" \
            "" \
            "$expected_checksum" \
            "sha256"
    else
        loggers::print_ui_line "  " "✓ " "Up to date." _color_green
        ((UP_TO_DATE_APPS_COUNT++))
    fi

    return 0
}

# Extracted helper for checksum-based update detection for DEB files
updates::_compare_deb_checksums() {
    local temp_file="$1"
    local package_name="$2"
    local installed_version="$3"
    local downloaded_version="$4"
    local app_name="$5"
    local app_key="$6"

    local needs_update=0
    local final_downloaded_version="$downloaded_version"

    loggers::print_ui_line "  " "→ " "Comparing package checksums for $(_bold "$app_name")..."

    local current_deb_path="/var/cache/apt/archives/${package_name}_${installed_version}_amd64.deb"
    if [[ -f "$current_deb_path" ]]; then
        local current_checksum
        current_checksum=$(sha256sum "$current_deb_path" | cut -d' ' -f1)
        local downloaded_checksum
        downloaded_checksum=$(sha256sum "$temp_file" | cut -d' ' -f1)

        if [[ "$downloaded_checksum" != "$current_checksum" ]]; then
            loggers::print_ui_line "  " "✓ " "New package detected (different checksum)." _color_green
            needs_update=1
            final_downloaded_version="${downloaded_version}-new-checksum"
        else
            loggers::log_message "INFO" "✓ Up to date (checksums match)."
        fi
    else
        loggers::log_message "INFO" "No cached DEB file found for '$package_name' ('$current_deb_path') for checksum comparison. Cannot confirm if new version by checksum if versions are identical."
        if versions::compare_strings "$installed_version" "0.0.0" -eq 1; then
            loggers::print_ui_line "  " "→ " "Assuming installation is needed (app not installed or cached DEB missing)."
            needs_update=1
        fi
    fi

    echo "$needs_update:$final_downloaded_version"
    return 0
}

# Updates module; checks for updates for a direct DEB application.
updates::check_direct_deb() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local package_name="${app_config_ref[package_name]}"
    local download_url="${app_config_ref[download_url]}"
    local deb_filename_template="${app_config_ref[deb_filename_template]}"
    local source="Direct Download"

    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        loggers::print_ui_line "  " "✗ " "Invalid download URL configured." _color_red
        return 1
    fi

    local installed_version
    installed_version=$(versions::normalize "$(packages::get_installed_version "$app_key")")

    # Always show "Checking ..." at the start
    loggers::print_ui_line "  " "→ " "Checking $(_bold "$name") for latest version..."

    # Verbose log lines: Installed and Source first
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Installed: $installed_version"
        loggers::log_message "INFO" "Source:    $source"
    fi

    local temp_download_file
    local base_filename_from_url
    base_filename_from_url="$(basename "$download_url" | cut -d'?' -f1 | sed 's/\.deb$//')"
    base_filename_from_url=$(systems::sanitize_filename "$base_filename_from_url")
    temp_download_file=$(systems::create_temp_file "${base_filename_from_url}")
    if [[ $? -ne 0 ]]; then return 1; fi

    if ! networks::download_file "$download_url" "$temp_download_file" ""; then
        loggers::print_ui_line "  " "✗ " "Failed to download package for '$name'." _color_red
        return 1
    fi

    local downloaded_version
    downloaded_version=$(versions::normalize "$(packages::extract_deb_version "$temp_download_file")")

    if [[ "$downloaded_version" == "0.0.0" ]]; then
        loggers::print_ui_line "  " "✗ " "Failed to extract version from downloaded package for '$name'. Will try checksum." _color_yellow
    fi

    # Verbose log line: Latest after fetch
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Latest:    $downloaded_version"
        loggers::print_message ""
    fi

    # Standardized summary output
    loggers::print_ui_line "  " "Installed: " "$installed_version"
    loggers::print_ui_line "  " "Source:    " "$source"
    loggers::print_ui_line "  " "Latest:    " "$downloaded_version"

    local needs_update=0
    if updates::is_needed "$installed_version" "$downloaded_version"; then
        needs_update=1
    elif versions::compare_strings "$downloaded_version" "$installed_version" -eq 1; then
        local checksum_result
        checksum_result=$(updates::_compare_deb_checksums \
            "$temp_download_file" \
            "$package_name" \
            "$installed_version" \
            "$downloaded_version" \
            "$name" \
            "$app_key")
        if [[ $? -ne 0 ]]; then return 1; fi

        needs_update=$(echo "$checksum_result" | cut -d':' -f1)
        downloaded_version=$(echo "$checksum_result" | cut -d':' -f2)
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        loggers::print_ui_line "  " "⬆ " "New version available: $downloaded_version" _color_yellow
        updates::process_deb_package \
            "$name" \
            "$app_key" \
            "${app_config_ref[gpg_key_id]:-}" \
            "${app_config_ref[gpg_fingerprint]:-}" \
            "$deb_filename_template" \
            "$downloaded_version" \
            "$download_url" \
            "$temp_download_file" \
            "" \
            "sha256"
    else
        loggers::print_ui_line "  " "✓ " "Up to date." _color_green
        ((UP_TO_DATE_APPS_COUNT++))
        rm -f "$temp_download_file"
        systems::unregister_temp_file "$temp_download_file"
    fi

    return 0
}

updates::process_appimage_file() {
    local app_name="$1"
    local latest_version="$2"
    local download_url="$3"
    local install_target_full_path="$4"
    local expected_checksum="$5"
    local checksum_algorithm="${6:-sha256}"
    local app_key="$7"

    if [[ -z "$latest_version" ]] || ! validators::check_url_format "$download_url" || [[ -z "$install_target_full_path" ]] || [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Invalid parameters for AppImage update flow (version, URL, install path, or app_key missing)" "$app_name"
        return 1
    fi

    local temp_appimage_path
    local base_filename_for_tmp
    base_filename_for_tmp="$(basename "$install_target_full_path" | sed 's/\.AppImage$//')"
    base_filename_for_tmp=$(systems::sanitize_filename "$base_filename_for_tmp")
    temp_appimage_path=$(mktemp "/tmp/${base_filename_for_tmp}.XXXXXX.AppImage")
    if [[ $? -ne 0 ]]; then
        errors::handle_error "VALIDATION_ERROR" "Failed to create temporary file with template: '${base_filename_for_tmp}.XXXXXX.AppImage'" "$app_name"
        return 1
    fi
    TEMP_FILES+=("$temp_appimage_path")

    if ! networks::download_file "$download_url" "$temp_appimage_path" "$expected_checksum" "$checksum_algorithm"; then
        errors::handle_error "NETWORK_ERROR" "Failed to download AppImage" "$app_name"
        return 1
    fi

    if ! chmod +x "$temp_appimage_path"; then
        errors::handle_error "PERMISSION_ERROR" "Failed to make AppImage executable: '$temp_appimage_path'" "$app_name"
        return 1
    fi

    local prompt_msg="Do you want to install $(_bold "$app_name") (v$latest_version)?"
    if [[ -f "$install_target_full_path" ]]; then
        prompt_msg="Do you want to update $(_bold "$app_name") to (v$latest_version)?"
    fi

    notifiers::send_notification "${app_name} Update Available" "New AppImage downloaded" "normal"

    if interfaces::confirm_prompt "$prompt_msg" "Y"; then
        if [[ $DRY_RUN -eq 1 ]]; then
            loggers::log_message "DEBUG" "  [DRY RUN] Would move '$temp_appimage_path' to '$install_target_full_path'."
            if ! packages::update_installed_version_json "$app_key" "$latest_version"; then
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name' in dry run."
            fi
            loggers::print_ui_line "  " "[DRY RUN] " "AppImage update simulated for $(_bold "$app_name")." _color_yellow
            return 0
        fi

        local target_dir
        target_dir="$(dirname "$install_target_full_path")"
        if ! mkdir -p "$target_dir"; then
            errors::handle_error "PERMISSION_ERROR" "Failed to create installation directory: '$target_dir'" "$app_name"
            return 1
        fi

        # Remove existing file if present
        if [[ -f "$install_target_full_path" ]]; then
            if ! rm -f "$install_target_full_path"; then
                errors::handle_error "PERMISSION_ERROR" "Failed to remove existing AppImage: '$install_target_full_path'" "$app_name"
                return 1
            fi
        fi

        loggers::log_message "DEBUG" "Moving from '$temp_appimage_path' to '$install_target_full_path'"
        if mv "$temp_appimage_path" "$install_target_full_path"; then
            systems::unregister_temp_file "$temp_appimage_path"
            chmod +x "$install_target_full_path" || loggers::log_message "WARN" "Failed to make final AppImage executable: '$install_target_full_path'."
            if [[ -n "$ORIGINAL_USER" ]] && getent passwd "$ORIGINAL_USER" &>/dev/null; then
                chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$install_target_full_path" 2>/dev/null || \
                    loggers::log_message "WARN" "Failed to change ownership of '$install_target_full_path' to '$ORIGINAL_USER'."
            fi
            if ! packages::update_installed_version_json "$app_key" "$latest_version"; then
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but installation was successful."
            fi
            loggers::print_ui_line "  " "✓ " "$(_bold "$app_name") AppImage updated successfully." _color_green
            notifiers::send_notification "${app_name} Updated" "New AppImage installed." "normal"
            ((UPDATED_APPS_COUNT++))
            return 0
        else
            errors::handle_error "INSTALLATION_ERROR" "Failed to move new AppImage from '$temp_appimage_path' to '$install_target_full_path'" "$app_name"
            return 1
        fi
    else
        loggers::print_ui_line "  " "🞨 " "Installation skipped." _color_yellow
        ((SKIPPED_APPS_COUNT++)) # FIX: Increment skipped counter
        return 0
    fi
}

# Extracted helper for GPG signature verification
updates::_verify_gpg_signature() {
    local sig_url="$1"
    local deb_path="$2"
    local app_name="$3"

    local temp_sig_path
    temp_sig_path=$(systems::create_temp_file "${app_name}_sig")
    if [[ $? -ne 0 ]]; then return 1; fi
    temp_sig_path="${temp_sig_path}.sig"

    loggers::print_ui_line "  " "→ " "Downloading signature for verification..."

    if ! networks::download_file "$sig_url" "$temp_sig_path" ""; then
        errors::handle_error "NETWORK_ERROR" "Failed to download signature for '$app_name'. Aborting." "$app_name"
        return 1
    fi

    loggers::print_ui_line "  " "→ " "Verifying signature..."
    local original_user_id_for_sudo=""
    if [[ -n "$ORIGINAL_USER" ]]; then
        original_user_id_for_sudo=$(getent passwd "$ORIGINAL_USER" | cut -d: -f3 2>/dev/null)
    fi

    if [[ -z "$original_user_id_for_sudo" ]]; then
        loggers::log_message "ERROR" "ORIGINAL_USER is invalid or empty ('$ORIGINAL_USER'). Cannot perform GPG signature verification. Running as current user (root)."
        if gpg --verify "$temp_sig_path" "$deb_path" &>/dev/null; then
            loggers::log_message "INFO" "✓ Signature verification passed."
            loggers::print_ui_line "  " "✓ " "Signature verification passed." _color_green
            return 0
        else
            errors::handle_error "GPG_ERROR" "Signature verification FAILED for '$app_name' DEB. Aborting installation due to potential tampering." "$app_name"
            return 1
        fi
    else
        if sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" gpg --verify "$temp_sig_path" "$deb_path" &>/dev/null; then
            loggers::log_message "INFO" "✓ Signature verification passed."
            loggers::print_ui_line "  " "✓ " "Signature verification passed." _color_green
            return 0
        else
            errors::handle_error "GPG_ERROR" "Signature verification FAILED for '$app_name' DEB. Aborting installation due to potential tampering." "$app_name"
            return 1
        fi
    fi
}

# Updates module; checks for updates for an AppImage application.
updates::check_appimage() {
    local -n app_config_ref=$1
    local name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    local download_url="${app_config_ref[download_url]}"
    local install_path="${app_config_ref[install_path]}"
    local github_repo_owner="${app_config_ref[repo_owner]:-}"
    local github_repo_name="${app_config_ref[repo_name]:-}"

    if ! validators::check_url_format "$download_url"; then
        errors::handle_error "CONFIG_ERROR" "Invalid download URL in configuration" "$name"
        loggers::print_ui_line "  " "✗ " "Invalid download URL configured." _color_red
        return 1
    fi
    if ! validators::check_file_path "$install_path"; then
        errors::handle_error "CONFIG_ERROR" "Invalid install path in configuration" "$name"
        loggers::print_ui_line "  " "✗ " "Invalid install path configured." _color_red
        return 1
    fi

    local resolved_install_base_dir="${install_path//\$HOME/$ORIGINAL_HOME}"
    resolved_install_base_dir="${resolved_install_base_dir/#\~/$ORIGINAL_HOME}"
    local appimage_file_path_current="${resolved_install_base_dir}/${name}.AppImage"

    local installed_version
    installed_version=$(versions::normalize "$(packages::get_installed_version "$app_key")")

    # Always show "Checking ..." at the start
    loggers::print_ui_line "  " "→ " "Checking $(_bold "$name") for latest version..."

    local latest_version=""
    local expected_checksum=""
    local checksum_algorithm="sha256"
    local source="Direct Download"

    # Verbose log lines: Installed and Source first
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Installed: $installed_version"
        loggers::log_message "INFO" "Source:    $source"
    fi

    if [[ -n "$github_repo_owner" ]] && [[ -n "$github_repo_name" ]]; then
        local api_response
        if api_response=$(github::get_latest_release_info "$github_repo_owner" "$github_repo_name"); then
            local latest_release_json
            latest_release_json=$(systems::get_json_value "$api_response" '.[0]' "$name")
            if [[ $? -eq 0 && -n "$latest_release_json" ]]; then
                latest_version=$(github::parse_version_from_release "$latest_release_json" "$name")
                if [[ $? -ne 0 ]]; then
                    loggers::log_message "WARN" "Could not extract semantic version from GitHub tag for '$name'."
                fi

                local download_filename_from_url="$(basename "$download_url" | cut -d'?' -f1)"
                expected_checksum=$(github::find_asset_checksum "$latest_release_json" "$download_filename_from_url")
                if [[ $? -ne 0 ]]; then loggers::log_message "WARN" "Failed to get GitHub checksum for '$name'."; fi
                source="GitHub Releases"
            fi
        else
            loggers::log_message "WARN" "Failed to fetch GitHub latest release for '$name'. Will try direct download URL."
        fi
    fi

    if [[ -z "$latest_version" ]]; then
        loggers::log_message "DEBUG" "Attempting to extract version from download URL filename: '$download_url'"
        local filename_from_url
        filename_from_url=$(basename "$download_url" | cut -d'?' -f1)
        latest_version=$(echo "$filename_from_url" | grep -oE '[0-9]+(\.[0-9]+)*(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?' | head -n1)
        if [[ -z "$latest_version" ]]; then
            loggers::log_message "WARN" "Could not extract version from AppImage download URL filename for '$name'. Will default to 0.0.0 for comparison."
            latest_version="0.0.0"
        fi
    fi

    # Verbose log line: Latest after fetch
    if [[ $VERBOSE -eq 1 ]]; then
        loggers::log_message "INFO" "Latest:    $latest_version"
        loggers::print_message ""
    fi

    # Standardized summary output
    loggers::print_ui_line "  " "Installed: " "$installed_version"
    loggers::print_ui_line "  " "Source:    " "$source"
    loggers::print_ui_line "  " "Latest:    " "$latest_version"

    if updates::is_needed "$installed_version" "$latest_version"; then
        loggers::print_ui_line "  " "⬆ " "New version available: $latest_version" _color_yellow
        updates::process_appimage_file \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$expected_checksum" \
            "$checksum_algorithm" \
            "$app_key"
    elif [[ "$installed_version" == "0.0.0" && "$latest_version" != "0.0.0" ]]; then
        loggers::print_ui_line "  " "⬆ " "App not installed. Installing $latest_version." _color_yellow
        updates::process_appimage_file \
            "${name}" \
            "${latest_version}" \
            "${download_url}" \
            "${appimage_file_path_current}" \
            "$expected_checksum" \
            "$checksum_algorithm" \
            "$app_key"
    else
        loggers::print_ui_line "  " "✓ " "Up to date." _color_green
        ((UP_TO_DATE_APPS_COUNT++))
    fi

    return 0
}

# Updates module; installs/updates a Flatpak application.
# Args:
#   $1: app_name (string)
#   $2: app_key (string)
#   $3: latest_version (string)
#   $4: flatpak_app_id (string)
updates::process_flatpak_app() {
    local app_name="$1"
    local app_key="$2"
    local latest_version="$3"
    local flatpak_app_id="$4"

    if [[ -z "$app_name" ]] || [[ -z "$app_key" ]] || [[ -z "$latest_version" ]] || [[ -z "$flatpak_app_id" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Missing required parameters for Flatpak installation" "$app_name"
        return 1
    fi

    if ! command -v flatpak &>/dev/null; then
        errors::handle_error "DEPENDENCY_ERROR" "Flatpak is not installed. Cannot update $app_name." "$app_name"
        loggers::print_ui_line "  " "✗ " "Flatpak not installed. Cannot update $(_bold "$app_name")." _color_red
        return 1
    fi
    if ! flatpak remotes | grep -q flathub; then
        loggers::print_ui_line "  " "→ " "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || {
            errors::handle_error "INSTALLATION_ERROR" "Failed to add Flathub remote. Cannot update $app_name." "$app_name"
            loggers::print_ui_line "  " "✗ " "Failed to add Flathub remote." _color_red
            return 1
        }
    fi
    loggers::print_ui_line "  " "→ " "Updating Flatpak appstream data..."
    flatpak update --appstream -y || {
        loggers::log_message "WARN" "Failed to update Flatpak appstream data for $app_name. Installation might proceed but information could be stale."
        loggers::print_ui_line "  " "! " "Failed to update Flatpak appstream data. Continuing anyway." _color_yellow
    }

    local current_installed_version
    current_installed_version=$(packages::get_installed_version "$app_key")

    local prompt_msg="Do you want to install $(_bold "$app_name") v$latest_version via Flatpak?"
    if [[ "$current_installed_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update $(_bold "$app_name") to v$latest_version via Flatpak?"
    fi

    notifiers::send_notification "$app_name Update Available" "v$latest_version found on Flathub" "normal"

    if interfaces::confirm_prompt "$prompt_msg" "Y"; then
        loggers::print_ui_line "  " "→ " "Installing/updating $(_bold "$app_name")..."
        if [[ $DRY_RUN -eq 1 ]]; then
            loggers::print_ui_line "    " "[DRY RUN] " "Would run: flatpak install --or-update -y flathub '$flatpak_app_id'" _color_yellow
            if ! packages::update_installed_version_json "$app_key" "$latest_version"; then
                loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name' in dry run."
            fi
            loggers::print_ui_line "  " "[DRY RUN] " "Flatpak update simulated for $(_bold "$app_name")." _color_yellow
            return 0
        else
            if flatpak install --or-update -y flathub "$flatpak_app_id"; then
                if ! packages::update_installed_version_json "$app_key" "$latest_version"; then
                    loggers::log_message "WARN" "Failed to update installed version JSON for '$app_name', but Flatpak installation was successful."
                fi
                loggers::print_ui_line "  " "✓ " "Successfully updated $(_bold "$app_name") via Flatpak." _color_green
                notifiers::send_notification "$app_name Updated" "Successfully installed v$latest_version (Flatpak)" "normal"
                ((UPDATED_APPS_COUNT++))
                return 0
            else
                errors::handle_error "INSTALLATION_ERROR" "Failed to install/update $app_name via Flatpak" "$app_name"
                return 1
            fi
        fi
    else
        loggers::print_ui_line "  " "🞨 " "Installation skipped." _color_yellow
        ((SKIPPED_APPS_COUNT++)) # FIX: Increment skipped counter
        return 0
    fi
}

# Updates helper; handles the logic for a 'custom' application type. (Refactored)
updates::handle_custom_check() {
    local config_array_name="$1" # FIX: Accept the name of the array, not a nameref
    local -n app_config_ref=$config_array_name
    local app_display_name="${app_config_ref[name]}"
    local installed_version
    installed_version=$(versions::normalize "$(packages::get_installed_version "${app_config_ref[app_key]}")")

    local custom_checker_script="${app_config_ref[custom_checker_script]}"
    if [[ -z "$custom_checker_script" ]]; then
        errors::handle_error "CONFIG_ERROR" "Missing 'custom_checker_script' for custom app type" "$app_display_name"
        loggers::print_ui_line "  " "✗ " "Configuration error: Missing custom checker script." _color_red
        return 1
    fi

    local script_base_dir="$(dirname "$CORE_DIR")"
    local custom_checkers_dir="${script_base_dir}/custom_checkers"
    local script_path="${custom_checkers_dir}/${custom_checker_script}"

    # Export functions for custom checker subshell
    export -f loggers::log_message
    export -f loggers::print_ui_line
    export -f systems::get_json_value
    export -f systems::require_json_value
    export -f systems::create_temp_file
    export -f systems::unregister_temp_file
    export -f systems::sanitize_filename
    export -f systems::reattempt_command
    export -f errors::handle_error
    export -f validators::check_url_format
    export -f packages::get_installed_version
    export -f versions::is_newer
    export ORIGINAL_HOME ORIGINAL_USER VERBOSE DRY_RUN
    declare -p NETWORK_CONFIG > /dev/null
    export -f $(declare -F | awk '{print $3}' | grep -E '^(updates|networks|packages|versions|validators|systems)::')

    loggers::print_ui_line "  " "→ " "Checking $(_bold "$app_display_name") for latest version..."

    local custom_checker_output=""
    local custom_checker_func="${app_config_ref[custom_checker_func]}"

    source "$script_path" || {
        errors::handle_error "CONFIG_ERROR" "Failed to source custom checker script: '$script_path'" "$app_display_name"
        return 1
    }

    if [[ -z "$custom_checker_func" ]] || ! type -t "$custom_checker_func" | grep -q 'function'; then
        errors::handle_error "CONFIG_ERROR" "Custom checker function '$custom_checker_func' not found in script '$custom_checker_script'" "$app_display_name"
        return 1
    fi

    # FIX: Pass the original array name to the checker function
    custom_checker_output=$("$custom_checker_func" "$config_array_name")
    local status
    status=$(echo "$custom_checker_output" | jq -r '.status')
    local latest_version
    latest_version=$(versions::normalize "$(echo "$custom_checker_output" | jq -r '.latest_version')")
    local source
    source=$(echo "$custom_checker_output" | jq -r '.source')
    local error_message
    error_message=$(echo "$custom_checker_output" | jq -r '.error_message // empty')

    loggers::print_ui_line "  " "Installed: " "$installed_version"
    loggers::print_ui_line "  " "Source:    " "$source"
    loggers::print_ui_line "  " "Latest:    " "$latest_version"

    # FIX: Add a version check here to be more robust than just trusting the checker's status
    if [[ "$status" == "success" ]] && updates::is_needed "$installed_version" "$latest_version"; then
        local install_type
        install_type=$(echo "$custom_checker_output" | jq -r '.install_type // "unknown"')
        
        loggers::print_ui_line "  " "⬆ " "New version available: $latest_version" _color_yellow
        
        case "$install_type" in
            "deb")
                local download_url_from_output
                download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
                local gpg_key_id_from_output
                gpg_key_id_from_output=$(echo "$custom_checker_output" | jq -r '.gpg_key_id // empty')
                local gpg_fingerprint_from_output  
                gpg_fingerprint_from_output=$(echo "$custom_checker_output" | jq -r '.gpg_fingerprint // empty')
                
                updates::process_deb_package \
                    "${app_config_ref[name]}" \
                    "${app_config_ref[app_key]}" \
                    "$gpg_key_id_from_output" \
                    "$gpg_fingerprint_from_output" \
                    "${app_config_ref[deb_filename_template]:-}" \
                    "$latest_version" \
                    "$download_url_from_output" \
                    "" "" "sha256"
                ;;
            "appimage")
                local download_url_from_output install_target_path_from_output
                download_url_from_output=$(echo "$custom_checker_output" | jq -r '.download_url')
                install_target_path_from_output=$(echo "$custom_checker_output" | jq -r '.install_target_path')
                
                updates::process_appimage_file \
                    "${app_config_ref[name]}" \
                    "${latest_version}" \
                    "${download_url_from_output}" \
                    "${install_target_path_from_output}" \
                    "" \
                    "sha256" \
                    "${app_config_ref[app_key]}"
                ;;
            "flatpak")
                local flatpak_app_id_from_output
                flatpak_app_id_from_output=$(echo "$custom_checker_output" | jq -r '.flatpak_app_id')
                
                updates::process_flatpak_app \
                    "${app_config_ref[name]}" \
                    "${app_config_ref[app_key]}" \
                    "$latest_version" \
                    "$flatpak_app_id_from_output"
                ;;
            *)
                loggers::print_ui_line "  " "✗ " "Unknown install type from custom checker: $install_type" _color_red
                return 1
                ;;
        esac
    elif [[ "$status" == "no_update" || "$status" == "success" ]]; then
        # FIX: Also treat "success" with no new version as "up to date"
        loggers::print_ui_line "  " "✓ " "Up to date." _color_green
        ((UP_TO_DATE_APPS_COUNT++))
    elif [[ "$status" == "error" ]]; then
        loggers::print_ui_line "  " "✗ " "Error: $error_message" _color_red
        return 1
    else
        loggers::print_ui_line "  " "✗ " "Unknown status from checker." _color_red
        return 1
    fi
    return 0
}

# Updates module; checks for updates for a single application defined in config. (Refactored)
updates::check_application() {
    local app_key="$1"
    local current_index="$2"
    local total_apps="$3"

    if [[ -z "$app_key" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Empty app key provided"
        ((FAILED_APPS_COUNT++))
        return 1
    fi

    declare -A _current_app_config
    local field_name
    for field_name in "${!ALL_APP_CONFIGS[@]}"; do
        if [[ "$field_name" =~ ^"${app_key}_" ]]; then
            _current_app_config["${field_name#"${app_key}"_}"]="${ALL_APP_CONFIGS[$field_name]}"
        fi
    done

    _current_app_config["app_key"]="$app_key"

    local app_display_name="${_current_app_config[name]:-$app_key}"
    interfaces::display_header "$app_display_name" "$current_index" "$total_apps"

    if [[ -z "${_current_app_config[type]:-}" ]]; then
        errors::handle_error "CONFIG_ERROR" "Application '$app_key' missing 'type' field." "$app_display_name"
        loggers::print_ui_line "  " "✗ " "Configuration error: Missing app type." _color_red
        ((FAILED_APPS_COUNT++))
        loggers::print_message ""
        return 1
    fi

    local app_check_status=0
    case "${_current_app_config[type]}" in
    "github_deb")
        updates::check_github_deb _current_app_config || app_check_status=1
        ;;
    "direct_deb")
        updates::check_direct_deb _current_app_config || app_check_status=1
        ;;
    "appimage")
        updates::check_appimage _current_app_config || app_check_status=1
        ;;
    "custom")
        updates::handle_custom_check _current_app_config || app_check_status=1
        ;;
    *)
        errors::handle_error "CONFIG_ERROR" "Unknown update type '${_current_app_config[type]}'" "$app_display_name"
        loggers::print_ui_line "  " "✗ " "Configuration error: Unknown update type." _color_red
        app_check_status=1
        ;;
    esac

    if [[ "$app_check_status" -ne 0 ]]; then
        ((FAILED_APPS_COUNT++))
    fi
    loggers::print_message "" # Blank line after each app block
    return "$app_check_status"
}

# ==============================================================================
# SECTION: Application Configurations (Global Variables)
# ==============================================================================

# All application configurations are now loaded exclusively from the JSON config files
# in the modular config directory to maintain a single source of truth.
declare -A ALL_APP_CONFIGS=()
# CUSTOM_APP_KEYS is now the main list of enabled apps from the modular config
declare -a CUSTOM_APP_KEYS=()

# ==============================================================================
# SECTION: CLI Module
# ==============================================================================

# CLI helper; gets available app keys from config files for display. (Refactored)
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

# CLI module; displays script usage information. (Refactored)
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

# CLI module; parses command-line arguments.
cli::parse_arguments() {
    local apps_specified_on_cmdline=0
    local input_app_keys_from_cli_temp=()

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
                errors::handle_error "VALIDATION_ERROR" "Option --cache-duration requires a positive integer."
                exit 1
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
            errors::handle_error "VALIDATION_ERROR" "Unknown option: '$1'"
            cli::show_usage >&2
            exit 1
            ;;
        *)
            input_app_keys_from_cli_temp+=("$1")
            apps_specified_on_cmdline=1
            shift
            ;;
        esac
    done

    if [[ "$apps_specified_on_cmdline" -eq 1 ]]; then
        input_app_keys_from_cli=("${input_app_keys_from_cli_temp[@]}")
    fi
}

# ==============================================================================
# SECTION: Main Function
# ==============================================================================

main() {
    packages::initialize_installed_versions_file || exit 1
    configs::load_modular_directory || exit 1

    loggers::print_message ""
    loggers::print_message "$(_bold "🔄 Packwatch: Application Update Checker")"
    loggers::print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local apps_to_check=("${CUSTOM_APP_KEYS[@]}")
    if [[ "${#input_app_keys_from_cli[@]}" -gt 0 ]]; then
        local valid_cli_apps=()
        for cli_app in "${input_app_keys_from_cli[@]}"; do
            local found=0
            for config_app_key in "${CUSTOM_APP_KEYS[@]}"; do
                if [[ "$cli_app" == "$config_app_key" ]]; then
                    valid_cli_apps+=("$cli_app")
                    found=1
                    break
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                loggers::log_message "WARN" "Application '$cli_app' specified on command line not found or not enabled in configurations. Skipping."
            fi
        done
        if [[ ${#valid_cli_apps[@]} -gt 0 ]]; then
            apps_to_check=("${valid_cli_apps[@]}")
        else
            errors::handle_error "VALIDATION_ERROR" "No valid application keys specified on command line found in enabled configurations. Exiting."
            exit 1
        fi
    fi

    local total_apps=${#apps_to_check[@]}
    if [[ "$total_apps" -eq 0 ]]; then
        loggers::print_message "No applications configured to check in '$CONFIG_DIR' directory with '\"enabled\": true'. Exiting."
        exit 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        loggers::print_message ""
        loggers::print_message "$(_color_yellow "🚀 Running in DRY RUN mode - no installations or file modifications will be performed.")"
    fi

    local current_index=1
    for app_key in "${apps_to_check[@]}"; do
    if ! updates::check_application "$app_key" "$current_index" "$total_apps"; then
        # Optionally log the failure
        :
    fi
    ((current_index++))
done
    
    loggers::print_message ""
    loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
    loggers::print_message "$(_bold "Update Summary:")"
    loggers::print_message "  $(_color_green "✓ Up to date:")    $UP_TO_DATE_APPS_COUNT"
    loggers::print_message "  $(_color_yellow "⬆ Updated:")       $UPDATED_APPS_COUNT"
    loggers::print_message "  $(_color_red "✗ Failed:")        $FAILED_APPS_COUNT"
    # FIX: Use a combined skipped count for the final summary
    local total_skipped=$((SKIPPED_APPS_COUNT))
    if [[ $total_skipped -gt 0 ]]; then
        loggers::print_message "  $(_color_cyan "🞨 Skipped/Disabled:") $total_skipped"
    fi
    loggers::print_message "$(_bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"

    if [[ $FAILED_APPS_COUNT -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# SECTION: Script Entry Point
# ==============================================================================

loggers::log_message "INFO" "Performing dependency check..."
declare -a missing_cmds=()
for cmd in wget curl gpg jq dpkg sha256sum lsb_release getent; do
    if ! command -v "$cmd" &>/dev/null; then
        missing_cmds+=("$cmd")
    fi
done

if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    errors::handle_error "DEPENDENCY_ERROR" "Missing required core commands: ${missing_cmds[*]}. Please install them."
    loggers::print_message ""
    loggers::print_message "$(_bold "To install core dependencies:")"
    loggers::print_message "  $(_color_cyan "sudo apt update && sudo apt install -y wget curl gpg jq libnotify-bin dpkg coreutils lsb-release getent")"
    loggers::print_message ""
    loggers::print_message "If 'notify-send' is missing, install 'libnotify-bin'."
    loggers::print_message "If 'flatpak' is missing, refer to https://flatpak.org/setup/."
    exit "${ERROR_CODES[DEPENDENCY_ERROR]}"
fi
loggers::log_message "INFO" "All core dependencies found."

declare -a input_app_keys_from_cli=()

cli::parse_arguments "$@"

main
