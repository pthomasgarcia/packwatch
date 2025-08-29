#!/usr/bin/env bash
# ==============================================================================
# MODULE: tests/test_updates.sh
# ==============================================================================
# Description:
#   Comprehensive tests for the updates module, covering various update types,
#   dry runs, error handling, and notifications.
# ==============================================================================

# shellcheck disable=SC2034,SC2154,SC2005

# Resolve script directory and repository root for robust sourcing
script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
repo_root="$(cd -- "${script_dir}/.." &> /dev/null && pwd)"
CORE_DIR="${repo_root}/src/core"

# Source common test helpers using absolute path
# shellcheck source=/dev/null
source "${script_dir}/test_helpers.sh"

# Source the module under test using absolute path
# shellcheck source=/dev/null
source "${CORE_DIR}/updates.sh"

# --- GLOBAL DECLARATIONS FOR TESTING ---
# Define these arrays directly in the test script to ensure they are available
# for sourced modules, bypassing potential scoping issues in complex sourcing scenarios.

# 1. Plugin Architecture for App Types
declare -A UPDATE_HANDLERS
UPDATE_HANDLERS["github_release"]="updates::check_github_release"
UPDATE_HANDLERS["direct_download"]="updates::check_direct_download"
UPDATE_HANDLERS["appimage"]="updates::check_appimage"
UPDATE_HANDLERS["script"]="updates::check_script"
UPDATE_HANDLERS["flatpak"]="updates::check_flatpak"
UPDATE_HANDLERS["custom"]="updates::handle_custom_check"

# 4. Configuration Validation Schema
declare -A APP_TYPE_VALIDATIONS
APP_TYPE_VALIDATIONS["github_release"]="repo_owner,repo_name,filename_pattern_template"
APP_TYPE_VALIDATIONS["direct_download"]="name,download_url"
APP_TYPE_VALIDATIONS["appimage"]="name,install_path,download_url"
APP_TYPE_VALIDATIONS["script"]="name,download_url,version_url,version_regex"
APP_TYPE_VALIDATIONS["flatpak"]="name,flatpak_app_id"
APP_TYPE_VALIDATIONS["custom"]="name,custom_checker_script,custom_checker_func"

# 9. Dependency Injection for Testing - also explicitly define here if needed for tests
UPDATES_DOWNLOAD_FILE_IMPL="${UPDATES_DOWNLOAD_FILE_IMPL:-networks::download_file}"
UPDATES_GET_JSON_VALUE_IMPL="${UPDATES_GET_JSON_VALUE_IMPL:-systems::fetch_json}"
UPDATES_PROMPT_CONFIRM_IMPL="${UPDATES_PROMPT_CONFIRM_IMPL:-interfaces::confirm_prompt}"
UPDATES_GET_INSTALLED_VERSION_IMPL="${UPDATES_GET_INSTALLED_VERSION_IMPL:-packages::fetch_version}"
UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL="${UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL:-packages::update_installed_version_json}"
UPDATES_GET_LATEST_RELEASE_INFO_IMPL="${UPDATES_GET_LATEST_RELEASE_INFO_IMPL:-repositories::get_latest_release_info}"
UPDATES_EXTRACT_DEB_VERSION_IMPL="${UPDATES_EXTRACT_DEB_VERSION_IMPL:-packages::extract_deb_version}"
UPDATES_FLATPAK_SEARCH_IMPL="${UPDATES_FLATPAK_SEARCH_IMPL:-flatpak search}"

# 10. Event Hooks - also explicitly define here if needed for tests
declare -a PRE_CHECK_HOOKS
declare -a POST_CHECK_HOOKS
declare -a PRE_INSTALL_HOOKS
declare -a POST_INSTALL_HOOKS
declare -a POST_VERIFY_HOOKS
declare -a ERROR_HOOKS

# ==============================================================================
# MOCKS
# ==============================================================================

# Mock dependencies that updates.sh relies on
configs::get_app_config() {
    local app_key="$1"
    local -n _output_ref=$2
    case "$app_key" in
        "TestAppGitHub")
            _output_ref[name]="TestAppGitHub"
            _output_ref[app_key]="TestAppGitHub"
            _output_ref[type]="github_release"
            _output_ref[repo_owner]="test-owner"
            _output_ref[repo_name]="test-repo"
            _output_ref[filename_pattern_template]="test-app-v%s.deb"
            ;;
        "TestAppDirectDownload")
            _output_ref[name]="TestAppDirectDownload"
            _output_ref[app_key]="TestAppDirectDownload"
            _output_ref[type]="direct_download"
            _output_ref[download_url]="http://example.com/test-app-1.0.0.deb"
            _output_ref[allow_insecure_http]="1"
            ;;
        "TestAppAppImage")
            _output_ref[name]="TestAppAppImage"
            _output_ref[app_key]="TestAppAppImage"
            _output_ref[type]="appimage"
            _output_ref[download_url]="http://example.com/TestApp.AppImage"
            _output_ref[install_path]="/opt"
            ;;
        "TestAppScript")
            _output_ref[name]="TestAppScript"
            _output_ref[app_key]="TestAppScript"
            _output_ref[type]="script"
            _output_ref[download_url]="http://example.com/install.sh"
            _output_ref[version_url]="http://example.com/version.txt"
            _output_ref[version_regex]="^Version: (.*)$"
            ;;
        "TestAppFlatpak")
            _output_ref[name]="TestAppFlatpak"
            _output_ref[app_key]="TestAppFlatpak"
            _output_ref[type]="flatpak"
            _output_ref[flatpak_app_id]="org.example.TestApp"
            ;;
        "TestAppCustom")
            _output_ref[name]="TestAppCustom"
            _output_ref[app_key]="TestAppCustom"
            _output_ref[type]="custom"
            _output_ref[custom_checker_script]="test_custom_checker.sh"
            _output_ref[custom_checker_func]="custom_checker::check"
            ;;
        "InvalidAppMissingType")
            _output_ref[name]="InvalidAppMissingType"
            _output_ref[app_key]="InvalidAppMissingType"
            ;;
        "InvalidAppUnknownType")
            _output_ref[name]="InvalidAppUnknownType"
            _output_ref[app_key]="InvalidAppUnknownType"
            _output_ref[type]="unknown_type"
            ;;
        "InvalidAppMissingField")
            _output_ref[name]="InvalidAppMissingField"
            _output_ref[app_key]="InvalidAppMissingField"
            _output_ref[type]="github_release"
            _output_ref[repo_owner]="test-owner"
            # Missing repo_name
            ;;
        *)
            return 1 # Config not found
            ;;
    esac
    return 0
}

interfaces::display_header() {
    # Suppress UI header during tests
    :
}

interfaces::print_ui_line() {
    # Suppress UI output during tests, capture if needed for specific assertions
    # echo "UI: $@" >&2
    :
}

loggers::output() {
    # Suppress log messages printed directly to stdout/stderr
    :
}

loggers::log() {
    # Capture logs for assertions if needed, otherwise suppress
    # echo "LOG: $1 - $2" >&2
    :
}

errors::handle_error() {
    # Capture errors for assertions
    echo "ERROR: $1 - $2" >&2
}

counters::inc_failed() {
    TEST_FAILED_COUNT=$((TEST_FAILED_COUNT + 1))
}

counters::inc_updated() {
    TEST_UPDATED_COUNT=$((TEST_UPDATED_COUNT + 1))
}

counters::inc_skipped() {
    TEST_SKIPPED_COUNT=$((TEST_SKIPPED_COUNT + 1))
}

counters::inc_up_to_date() {
    TEST_UP_TO_DATE_COUNT=$((TEST_UP_TO_DATE_COUNT + 1))
}

# Mock update handlers
updates::check_github_release() {
    local -n config_ref=$1
    if [[ "${config_ref[app_key]}" == "TestAppGitHub" ]]; then
        # Simulate an update available
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating GitHub update for ${config_ref[name]}"
            # Mock the internal process_installation call
            MOCKED_INSTALL_APP="${config_ref[name]}"
            MOCKED_INSTALL_VERSION="1.1.0"
            MOCKED_INSTALL_TYPE="github_release"
            return 0 # Success, update handled
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating GitHub no update for ${config_ref[name]}"
            updates::handle_up_to_date # Explicitly call the common handler
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating GitHub error for ${config_ref[name]}"
            return 1
        fi
    fi
    return 1 # Fallback for unexpected calls
}

updates::check_direct_download() {
    local -n config_ref=$1
    if [[ "${config_ref[app_key]}" == "TestAppDirectDownload" ]]; then
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating Direct Download update for ${config_ref[name]}"
            MOCKED_INSTALL_APP="${config_ref[name]}"
            MOCKED_INSTALL_VERSION="2.1.0"
            MOCKED_INSTALL_TYPE="direct_download"
            return 0
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating Direct Download no update for ${config_ref[name]}"
            updates::handle_up_to_date
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating Direct Download error for ${config_ref[name]}"
            return 1
        fi
    fi
    return 1
}

updates::check_appimage() {
    local -n config_ref=$1
    if [[ "${config_ref[app_key]}" == "TestAppAppImage" ]]; then
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating AppImage update for ${config_ref[name]}"
            MOCKED_INSTALL_APP="${config_ref[name]}"
            MOCKED_INSTALL_VERSION="3.1.0"
            MOCKED_INSTALL_TYPE="appimage"
            return 0
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating AppImage no update for ${config_ref[name]}"
            updates::handle_up_to_date
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating AppImage error for ${config_ref[name]}"
            return 1
        fi
    fi
    return 1
}

updates::check_script() {
    local -n config_ref=$1
    if [[ "${config_ref[app_key]}" == "TestAppScript" ]]; then
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating Script update for ${config_ref[name]}"
            MOCKED_INSTALL_APP="${config_ref[name]}"
            MOCKED_INSTALL_VERSION="4.1.0"
            MOCKED_INSTALL_TYPE="script"
            return 0
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating Script no update for ${config_ref[name]}"
            updates::handle_up_to_date
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating Script error for ${config_ref[name]}"
            return 1
        fi
    fi
    return 1
}

updates::check_flatpak() {
    local -n config_ref=$1
    if [[ "${config_ref[app_key]}" == "TestAppFlatpak" ]]; then
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating Flatpak update for ${config_ref[name]}"
            MOCKED_INSTALL_APP="${config_ref[name]}"
            MOCKED_INSTALL_VERSION="5.1.0"
            MOCKED_INSTALL_TYPE="flatpak"
            return 0
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating Flatpak no update for ${config_ref[name]}"
            updates::handle_up_to_date
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating Flatpak error for ${config_ref[name]}"
            return 1
        fi
    fi
    return 1
}

updates::handle_custom_check() {
    local config_array_name="$1"
    local -n app_config_ref=$config_array_name
    if [[ "${app_config_ref[app_key]}" == "TestAppCustom" ]]; then
        if [[ "$_TEST_SCENARIO" == "update_available" || "$_TEST_SCENARIO" == "user_accepts" || "$_TEST_SCENARIO" == update_available_user_accepts* ]]; then
            echo "Simulating Custom update for ${app_config_ref[name]}"
            MOCKED_INSTALL_APP="${app_config_ref[name]}"
            MOCKED_INSTALL_VERSION="6.1.0"
            MOCKED_INSTALL_TYPE="custom"
            return 0
        elif [[ "$_TEST_SCENARIO" == "no_update" ]]; then
            echo "Simulating Custom no update for ${app_config_ref[name]}"
            updates::handle_up_to_date
            return 0
        elif [[ "$_TEST_SCENARIO" == "error" ]]; then
            echo "Simulating Custom error for ${app_config_ref[name]}"
            return 1
        fi
    fi
    return 1
}

# Mock process_installation (called by specific update type handlers)
updates::process_installation() {
    local app_name="$1"
    local app_key="$2"
    local latest_version="$3"
    local install_command_func="$4"
    shift 4
    local -a install_command_args=("$@")

    loggers::log "DEBUG" "Mock process_installation called for $app_name (v$latest_version) with command: $install_command_func ${install_command_args[*]}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        loggers::log "INFO" "DRY RUN: Would install $app_name v$latest_version"
        # Simulate updating installed version in dry run for verification
        "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"
        return 0
    fi

    # Simulate actual installation success
    loggers::log "INFO" "Simulating actual installation of $app_name v$latest_version"
    "$UPDATES_UPDATE_INSTALLED_VERSION_JSON_IMPL" "$app_key" "$latest_version"
    counters::inc_updated
    return 0
}

# Mock interfaces::confirm_prompt to always return Y or N based on scenario
interfaces::confirm_prompt() {
    local prompt_msg="$1"
    local default_ans="$2"
    if [[ "$_TEST_SCENARIO" == "user_accepts" ]]; then
        echo "Mocking user acceptance for: $prompt_msg"
        return 0 # Yes
    elif [[ "$_TEST_SCENARIO" == "user_declines" ]]; then
        echo "Mocking user declination for: $prompt_msg"
        return 1 # No
    else
        # Unknown or unset scenario: honor provided default answer
        echo "[WARN] Unknown _TEST_SCENARIO='${_TEST_SCENARIO:-}' for confirm_prompt; honoring default '$default_ans' for: $prompt_msg" >&2
        case "${default_ans,,}" in
            y | yes)
                return 0
                ;;
            n | no)
                return 1
                ;;
            *)
                # Fallback: treat empty or unexpected default as acceptance
                return 0
                ;;
        esac
    fi
}

# Mock networks::download_file
networks::download_file() {
    local url="$1"
    local dest_path="$2"
    loggers::log "DEBUG" "Mock networks::download_file: Downloading $url to $dest_path"
    # Simulate successful download by creating a dummy file
    echo "dummy content" > "$dest_path"
    return 0
}

# Mock systems::create_temp_file
systems::create_temp_file() {
    local prefix="${1:-temp_file}"
    local temp_file_path
    temp_file_path=$(mktemp "/tmp/${prefix}.XXXXXX")
    echo "$temp_file_path"
    return 0
}

# Mock systems::create_temp_dir
systems::create_temp_dir() {
    local temp_dir_path
    temp_dir_path=$(mktemp -d "/tmp/temp_dir.XXXXXX")
    echo "$temp_dir_path"
    return 0
}

# Mock systems::unregister_temp_file
systems::unregister_temp_file() {
    # Do nothing, temp files will be cleaned by the test runner
    :
}

# Mock other external dependencies
packages::fetch_version() {
    local app_key="$1"
    case "$app_key" in
        "TestAppGitHub") echo "$_TEST_INSTALLED_VERSION_GITHUB" ;;
        "TestAppDirectDownload") echo "$_TEST_INSTALLED_VERSION_DIRECT" ;;
        "TestAppAppImage") echo "$_TEST_INSTALLED_VERSION_APPIMAGE" ;;
        "TestAppScript") echo "$_TEST_INSTALLED_VERSION_SCRIPT" ;;
        "TestAppFlatpak") echo "$_TEST_INSTALLED_VERSION_FLATPAK" ;;
        "TestAppCustom") echo "$_TEST_INSTALLED_VERSION_CUSTOM" ;;
        *) echo "0.0.0" ;;
    esac
}

packages::update_installed_version_json() {
    local app_key="$1"
    local version="$2"
    loggers::log "DEBUG" "Mock: packages::update_installed_version_json called for $app_key with $version"
    # In a real test, you might store this in a mock data structure
    case "$app_key" in
        "TestAppGitHub") _MOCKED_INSTALLED_VERSION_GITHUB="$version" ;;
        "TestAppDirectDownload") _MOCKED_INSTALLED_VERSION_DIRECT="$version" ;;
        "TestAppAppImage") _MOCKED_INSTALLED_VERSION_APPIMAGE="$version" ;;
        "TestAppScript") _MOCKED_INSTALLED_VERSION_SCRIPT="$version" ;;
        "TestAppFlatpak") _MOCKED_INSTALLED_VERSION_FLATPAK="$version" ;;
        "TestAppCustom") _MOCKED_INSTALLED_VERSION_CUSTOM="$version" ;;
    esac
    return 0
}

repositories::get_latest_release_info() {
    local owner="$1"
    local repo="$2"
    local temp_file
    if declare -F systems::create_temp_file > /dev/null 2>&1; then
        temp_file=$(systems::create_temp_file "release_info") || temp_file=$(mktemp)
    else
        temp_file=$(mktemp)
    fi
    echo "[{\"tag_name\":\"v1.1.0\", \"assets\":[{\"name\":\"test-app-v1.1.0.deb\", \"browser_download_url\":\"http://example.com/test-app-v1.1.0.deb\"}]}]" > "$temp_file"
    test_register_temp_file "$temp_file"
    echo "$temp_file"
    return 0
}

repositories::parse_version_from_release() {
    local json_file="$1"
    local app_name="$2"
    local tag_name
    tag_name=$(jq -r '.[0].tag_name' "$json_file")
    echo "${tag_name#v}"
}

repositories::find_asset_url() {
    local json_file="$1"
    local filename_template="$2"
    local app_name="$3"
    # Simulate finding asset URL
    echo "http://example.com/test-app-v1.1.0.deb"
    return 0
}

repositories::find_asset_digest() {
    # Mock this as needed for checksum tests
    echo ""
    return 0
}

versions::is_newer() {
    local new_ver="$1"
    local old_ver="$2"

    # Normalize by stripping leading 'v' and trimming whitespace
    new_ver="$(versions::normalize "$new_ver" | tr -d ' \t')"
    old_ver="$(versions::normalize "$old_ver" | tr -d ' \t')"

    # Strip any non-numeric suffix from each segment (e.g., 1.2.3-beta -> 1.2.3)
    # Conservative: remove everything after first non-digit in each segment.
    local IFS='.'
    read -r -a new_parts <<< "$new_ver"
    read -r -a old_parts <<< "$old_ver"

    local max_len=${#new_parts[@]}
    ((${#old_parts[@]} > max_len)) && max_len=${#old_parts[@]}

    local i
    for ((i = 0; i < max_len; i++)); do
        local n_seg="${new_parts[i]:-0}"
        local o_seg="${old_parts[i]:-0}"
        # Strip non-digit suffixes
        n_seg="${n_seg%%[^0-9]*}"
        o_seg="${o_seg%%[^0-9]*}"
        # Default empty to 0
        [[ -z "$n_seg" ]] && n_seg=0
        [[ -z "$o_seg" ]] && o_seg=0
        # Remove leading zeros
        n_seg="$((10#$n_seg))"
        o_seg="$((10#$o_seg))"
        if ((n_seg > o_seg)); then
            return 0 # new is newer
        elif ((n_seg < o_seg)); then
            return 1 # new is older
        fi
    done
    # All segments equal
    return 1
}

versions::normalize() {
    # Basic normalization for mock purposes
    echo "${1#v}"
}

versions::extract_from_regex() {
    local content="$1"
    local regex="$2"
    local app_name="$3"
    if [[ "$content" =~ $regex ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

networks::fetch_cached_data() {
    local url="$1"
    local type="$2"
    local temp_file
    temp_file=$(mktemp)
    # Simulate content for version_url
    if [[ "$url" == "http://example.com/version.txt" ]]; then
        echo "Version: 4.1.0" > "$temp_file"
    fi
    echo "$temp_file"
    return 0
}

flatpak() {
    local cmd="$1"
    if [[ "$cmd" == "search" ]]; then
        echo "Name        Description               Version Branch Remotes"
        echo "TestApp     A test application        5.1.0   stable flathub"
    fi
    return 0
}

sudo() {
    loggers::log "DEBUG" "Mock: sudo command executed: '$*'"
    return 0
}

chmod() {
    loggers::log "DEBUG" "Mock: chmod command executed: '$*'"
    return 0
}

mv() {
    loggers::log "DEBUG" "Mock: mv command executed: '$*'"
    # Simulate move by creating a dummy file at destination
    touch "$2"
    return 0
}

rm() {
    loggers::log "DEBUG" "Mock: rm command executed: '$*'"
    return 0
}

# ==============================================================================
# TEST FUNCTIONS
# ==============================================================================

# Reset test counters and mock states
reset_test_state() {
    TEST_FAILED_COUNT=0
    TEST_UPDATED_COUNT=0
    TEST_SKIPPED_COUNT=0
    TEST_UP_TO_DATE_COUNT=0
    if ((${#TEST_TEMP_FILES[@]})); then
        for _f in "${TEST_TEMP_FILES[@]}"; do
            if [[ -f "$_f" ]]; then
                rm -f "$_f"
            fi
        done
        TEST_TEMP_FILES=()
    fi
    MOCKED_INSTALL_APP=""
    MOCKED_INSTALL_VERSION=""
    MOCKED_INSTALL_TYPE=""
    _TEST_SCENARIO=""
    _TEST_INSTALLED_VERSION_GITHUB="0.0.0"
    _TEST_INSTALLED_VERSION_DIRECT="0.0.0"
    _TEST_INSTALLED_VERSION_APPIMAGE="0.0.0"
    _TEST_INSTALLED_VERSION_SCRIPT="0.0.0"
    _TEST_INSTALLED_VERSION_FLATPAK="0.0.0"
    _TEST_INSTALLED_VERSION_CUSTOM="0.0.0"
    _MOCKED_INSTALLED_VERSION_GITHUB="0.0.0"
    _MOCKED_INSTALLED_VERSION_DIRECT="0.0.0"
    _MOCKED_INSTALLED_VERSION_APPIMAGE="0.0.0"
    _MOCKED_INSTALLED_VERSION_SCRIPT="0.0.0"
    _MOCKED_INSTALLED_VERSION_FLATPAK="0.0.0"
    _MOCKED_INSTALLED_VERSION_CUSTOM="0.0.0"
    DRY_RUN=0 # Ensure dry run is off by default
}

# Test Case 1: General - Dry Run functionality
test_general_dry_run() {
    reset_test_state
    DRY_RUN=1
    _TEST_SCENARIO="user_accepts"
    _TEST_INSTALLED_VERSION_GITHUB="1.0.0" # Make sure there's an update

    assert_equal "$TEST_UPDATED_COUNT" 0 "No apps should be marked updated in dry run"
    assert_equal "$TEST_SKIPPED_COUNT" 0 "No apps should be marked skipped in dry run"
    assert_equal "$TEST_UP_TO_DATE_COUNT" 0 "No apps should be marked up-to-date in dry run"
    assert_equal "$TEST_FAILED_COUNT" 0 "No apps should fail in dry run (if underlying mock succeeds)"
    assert_equal "$_MOCKED_INSTALLED_VERSION_GITHUB" "1.1.0" "Mocked installed version should be updated in dry run for verification"

    DRY_RUN=0 # Reset for next tests
}

# Test Case 2: General - No Update Available
test_general_no_update() {
    reset_test_state
    _TEST_SCENARIO="no_update"
    _TEST_INSTALLED_VERSION_GITHUB="1.1.0" # Same as latest mocked version

    updates::check_application "TestAppGitHub" 1 1

    assert_equal "$TEST_UPDATED_COUNT" 0 "No apps should be updated"
    assert_equal "$TEST_SKIPPED_COUNT" 0 "No apps should be skipped"
    assert_equal "$TEST_UP_TO_DATE_COUNT" 1 "One app should be up-to-date"
    assert_equal "$TEST_FAILED_COUNT" 0 "No apps should fail"
}

# Test Case 3: General - Update Available (User Accepts)
test_general_update_accept() {
    reset_test_state
    _TEST_SCENARIO="update_available"
    _TEST_INSTALLED_VERSION_GITHUB="1.0.0"                   # Older version
    UPDATES_PROMPT_CONFIRM_IMPL="interfaces::confirm_prompt" # Ensure mock is used

    updates::check_application "TestAppGitHub" 1 1

    assert_equal "$TEST_UPDATED_COUNT" 1 "One app should be updated"
    assert_equal "$TEST_SKIPPED_COUNT" 0 "No apps should be skipped"
    assert_equal "$TEST_UP_TO_DATE_COUNT" 0 "No apps should be up-to-date"
    assert_equal "$TEST_FAILED_COUNT" 0 "No apps should fail"
    assert_equal "$_MOCKED_INSTALLED_VERSION_GITHUB" "1.1.0" "Installed version should be updated"
}

# Test Case 4: General - Update Available (User Declines)
test_general_update_decline() {
    reset_test_state
    _TEST_SCENARIO="user_declines"
    _TEST_INSTALLED_VERSION_GITHUB="1.0.0" # Older version

    updates::check_application "TestAppGitHub" 1 1

    assert_equal "$TEST_UPDATED_COUNT" 0 "No apps should be updated"
    assert_equal "$TEST_SKIPPED_COUNT" 1 "One app should be skipped"
    assert_equal "$TEST_UP_TO_DATE_COUNT" 0 "No apps should be up-to-date"
    assert_equal "$TEST_FAILED_COUNT" 0 "No apps should fail"
    assert_equal "$_MOCKED_INSTALLED_VERSION_GITHUB" "1.0.0" "Installed version should NOT be updated"
}

# Test Case 5: Error Handling - Missing Type
test_error_missing_type() {
    reset_test_state
    local error_output
    error_output=$(updates::check_application "InvalidAppMissingType" 1 1 2>&1)

    assert_equal "$TEST_FAILED_COUNT" 1 "One app should fail"
    assert_contains "$error_output" "ERROR: CONFIG_ERROR - Application 'InvalidAppMissingType' missing 'type' field." "Error message for missing type"
}

# Test Case 6: Error Handling - Unknown Type
test_error_unknown_type() {
    reset_test_state
    local error_output
    error_output=$(updates::check_application "InvalidAppUnknownType" 1 1 2>&1)

    assert_equal "$TEST_FAILED_COUNT" 1 "One app should fail"
    assert_contains "$error_output" "ERROR: CONFIG_ERROR - Unknown update type 'unknown_type'" "Error message for unknown type"
}

# Test Case 7: Error Handling - Missing Required Field
test_error_missing_required_field() {
    reset_test_state
    local error_output
    error_output=$(updates::check_application "InvalidAppMissingField" 1 1 2>&1)

    assert_equal "$TEST_FAILED_COUNT" 1 "One app should fail"
    assert_contains "$error_output" "ERROR: VALIDATION_ERROR - Missing required field 'repo_name' for app type 'github_release'." "Error message for missing field"
}

# Test Case 8: Orchestration - perform_all_checks
test_orchestration_all_checks() {
    reset_test_state
    _TEST_SCENARIO="update_available"
    _TEST_INSTALLED_VERSION_GITHUB="1.0.0"
    _TEST_INSTALLED_VERSION_DIRECT="2.0.0"
    _TEST_INSTALLED_VERSION_APPIMAGE="3.0.0"
    _TEST_INSTALLED_VERSION_SCRIPT="4.0.0"
    _TEST_INSTALLED_VERSION_FLATPAK="5.0.0"
    _TEST_INSTALLED_VERSION_CUSTOM="6.0.0"

    local apps=(
        "TestAppGitHub"
        "TestAppDirectDownload"
        "TestAppAppImage"
        "TestAppScript"
        "TestAppFlatpak"
        "TestAppCustom"
        "InvalidAppMissingType" # This one will fail
    )
    updates::perform_all_checks "${apps[@]}"

    assert_equal "$TEST_UPDATED_COUNT" 6 "Six apps should be updated"
    assert_equal "$TEST_SKIPPED_COUNT" 0 "No apps should be skipped"
    assert_equal "$TEST_UP_TO_DATE_COUNT" 0 "No apps should be up-to-date"
    assert_equal "$TEST_FAILED_COUNT" 1 "One app should fail"
}

# ==============================================================================
# RUN TESTS
# ==============================================================================

echo "Running updates module tests..."
run_test_suite
echo "All updates module tests completed."
