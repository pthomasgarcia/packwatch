#!/usr/bin/env bash
# ==============================================================================
# MODULE: tests/test_progress.sh
# ==============================================================================
# Responsibilities:
#   - Unit tests for src/lib/progress.sh
# ==============================================================================

# Define CORE_DIR for test environment
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src/core" && pwd)"
export CORE_DIR

# shellcheck source=/dev/null
source "$CORE_DIR/globals.sh"
# shellcheck source=/dev/null
source "$CORE_DIR/interfaces.sh" # Needed for print_ui_line dependency
export LIB_DIR                   # Export LIB_DIR after globals.sh is sourced
# shellcheck source=/dev/null
source "$LIB_DIR/progress.sh"

# shellcheck source=tests/test_helpers.sh
source "./tests/test_helpers.sh"

# Mock interfaces::print_ui_line to capture its output for testing
mock_interfaces_print_ui_line_output=""
interfaces::print_ui_line() {
    local indent="$1"
    local prefix="$2"
    local message="$3"
    # shellcheck disable=SC2034
    local color_constant="${4:-}"
    # shellcheck disable=SC2034
    local suffix="${5:-}" # Capture the suffix to check for \r

    # We only care about the printable content for assertion, not the carriage return.
    mock_interfaces_print_ui_line_output="${indent}${prefix}${message}"
}

# Test _format_bytes function
test_format_bytes() {
    assert_equal "$(_format_bytes 100)" "100 B" "_format_bytes 100 B"
    assert_equal "$(_format_bytes 1024)" "1.0 KB" "_format_bytes 1 KB"
    assert_equal "$(_format_bytes 1536)" "1.5 KB" "_format_bytes 1.5 KB"
    assert_equal "$(_format_bytes $((1024 * 1024)))" "1.0 MB" "_format_bytes 1 MB"
    assert_equal "$(_format_bytes $((1536 * 1024)))" "1.5 MB" "_format_bytes 1.5 MB"
    assert_equal "$(_format_bytes $((1024 * 1024 * 1024)))" "1.0 GB" "_format_bytes 1 GB"
}

# Test progress::render_bar function
test_render_bar() {
    local app_name="TestApp"

    # Test 0%
    mock_interfaces_print_ui_line_output=""
    progress::render_bar "$app_name" 0 1000
    expected_output="  ⤓ Downloading ${FORMAT_BOLD}TestApp${FORMAT_RESET}: [                    ] 0% (0 B / 1000 B)"
    assert_contains "$mock_interfaces_print_ui_line_output" "$expected_output" "render_bar 0%"

    # Test 50%
    mock_interfaces_print_ui_line_output=""
    progress::render_bar "$app_name" 500 1000
    expected_output="  ⤓ Downloading ${FORMAT_BOLD}TestApp${FORMAT_RESET}: [||||||||||          ] 50% (500 B / 1000 B)"
    assert_contains "$mock_interfaces_print_ui_line_output" "$expected_output" "render_bar 50%"

    # Test 100%
    mock_interfaces_print_ui_line_output=""
    progress::render_bar "$app_name" 1000 1000
    expected_output="  ⤓ Downloading ${FORMAT_BOLD}TestApp${FORMAT_RESET}: [||||||||||||||||||||] 100% (1000 B / 1000 B)"
    assert_contains "$mock_interfaces_print_ui_line_output" "$expected_output" "render_bar 100%"

    # Test with unknown total size
    mock_interfaces_print_ui_line_output=""
    progress::render_bar "$app_name" 1234 "unknown"
    expected_output="  ⤓ Downloading ${FORMAT_BOLD}TestApp${FORMAT_RESET}: [                    ] 0% (1.2 KB / unknown)"
    assert_contains "$mock_interfaces_print_ui_line_output" "$expected_output" "render_bar unknown total"

    # Test with speed and ETA (should not be present in current render_bar)
    mock_interfaces_print_ui_line_output=""
    progress::render_bar "$app_name" 500 1000 "1.0 MB/s" "00:05" # These args should be ignored by render_bar
    expected_output="  ⤓ Downloading ${FORMAT_BOLD}TestApp${FORMAT_RESET}: [||||||||||          ] 50% (500 B / 1000 B)"
    assert_contains "$mock_interfaces_print_ui_line_output" "$expected_output" "render_bar with speed/eta (ignored)"
}

# Test progress::clear_line
test_clear_line() {              # shellcheck disable=SC2329,SC2317
    local original_tput_cols_cmd # Declare local here to fix SC2329
    # Mock printf for tput cols and subsequent newline
    printf() { # shellcheck disable=SC2329
        if [[ "$1" == $'\r%*s\r' ]]; then
            # Simulate clearing the line
            echo "Simulating clear line"
        elif [[ "$1" == $'\n' ]]; then
            echo "Simulating newline"
        fi
    }
    original_tput_cols_cmd=$(type -t tput)
    tput() { # shellcheck disable=SC2329
        if [[ "$1" == "cols" ]]; then
            echo "80" # Mock a typical terminal width
        else
            command tput "$@"
        fi
    }

    progress::clear_line # Just call it and ensure it doesn't crash
    assert_success "clear_line runs without error"

    # Restore original tput if it was a command
    if [[ "$original_tput_cols_cmd" == "command" ]]; then
        unset -f tput
    fi
}

# Run all tests
run_test_suite "Progress Bar Tests" \
    test_format_bytes \
    test_render_bar \
    test_clear_line
