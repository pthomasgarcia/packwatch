#!/usr/bin/env bash
# Test suite for checker_utils.sh focused on cache / IO error paths.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TEST_DIR/test_helpers.sh"

# Minimal stubs for dependencies used by checker_utils::emit_error and related functions
loggers::log_message() { :; }
# Capture last notification (notifiers)
notifiers::send_notification() {
    LAST_NOTIFICATION_TYPE=$1
    LAST_NOTIFICATION_MSG=$2
    LAST_NOTIFICATION_LEVEL=$3
    : "$LAST_NOTIFICATION_TYPE" "$LAST_NOTIFICATION_MSG" "$LAST_NOTIFICATION_LEVEL"
}
errors::handle_error() { # mimic logging + exit code mapping
    local type="$1" msg="$2" app="$3"
    : "$msg" "$app" # suppress unused warnings
    # simulate exit code mapping; return 20 for CACHE_ERROR, else 1
    case "$type" in
        CACHE_ERROR) return 20 ;;
    esac
    return 1
}
validators::check_url_format() { return 0; }
networks::decode_url() { echo "$1"; }

# Source systems + checker_utils
# shellcheck source=/dev/null
source "$TEST_DIR/../src/util/checker_utils.sh"

# --- Tests ---

# Ensure load_cached_content_or_error emits CACHE_ERROR JSON to stdout when file missing.
test_load_cached_content_or_error_missing_file() {
    local output
    output=$(checker_utils::load_cached_content_or_error "/nonexistent/path/hopefully" "test-app" 2> /dev/null || true)
    # We redirected stderr to /dev/null to isolate JSON (emit_error prints JSON to stdout)
    local error_type
    error_type=$(echo "$output" | jq -r '.error_type // empty')
    assert_equal "$error_type" "CACHE_ERROR" "load_cached_content_or_error emits CACHE_ERROR error_type for missing file"
}

main() { run_test_suite; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
