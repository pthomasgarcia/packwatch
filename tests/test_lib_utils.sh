#!/usr/bin/env bash
# Test suite for refactored utility functions.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TEST_DIR/test_helpers.sh"

# Minimal stubs for dependencies
loggers::log_message() { :; }
errors::handle_error() {
    local type="$1" msg="$2" app="$3"
    : "$msg" "$app" # suppress unused warnings
    case "$type" in
        CACHE_ERROR) return 20 ;;
    esac
    return 1
}
validators::check_url_format() { return 0; }
networks::decode_url() { echo "$1"; }
networks::fetch_cached_data() { return 1; } # Simulate a cache miss/failure

# Source the new library files
# shellcheck source=/dev/null
source "$TEST_DIR/../src/lib/responses.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/../src/lib/networks.sh"

# --- Tests ---

# Ensure load_cached_content_or_error emits CACHE_ERROR JSON to stdout when file missing.
test_load_cached_content_or_error_missing_file() {
    local output
    output=$(networks::load_cached_content_or_error "/nonexistent/path/hopefully" "test-app" 2> /dev/null || true)
    # We redirected stderr to /dev/null to isolate JSON (emit_error prints JSON to stdout)
    local error_type
    error_type=$(echo "$output" | jq -r '.error_type // empty')
    assert_equal "$error_type" "CACHE_ERROR" "load_cached_content_or_error emits CACHE_ERROR error_type for missing file"
}

main() { run_test_suite; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
