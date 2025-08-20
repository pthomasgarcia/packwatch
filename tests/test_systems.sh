#!/usr/bin/env bash
# Tests for systems::sanitize_filename

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TEST_DIR/test_helpers.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/../src/lib/systems.sh"

# Stub loggers & errors to avoid side effects
loggers::log_message() { :; }
errors::handle_error() { :; }

# Test cases

# 1. Preserve simple extensions
test_sanitize_preserves_tar_gz() {
    local out
    out=$(systems::sanitize_filename "foo.tar.gz")
    assert_equal "$out" "foo.tar.gz" "Preserves multi-dot extension foo.tar.gz"
}

# 2. Preserve .sh
test_sanitize_preserves_sh() {
    local out
    out=$(systems::sanitize_filename "installer.sh")
    assert_equal "$out" "installer.sh" "Preserves .sh extension"
}

# 3. Strip leading dot and traversal
test_sanitize_strips_leading_dot_and_traversal() {
    local out
    out=$(systems::sanitize_filename "../.hidden/config")
    # '../.hidden/config' -> '..' replaced, slashes to dashes, leading dots removed
    # original path components collapse to '-hidden-config' then leading dash trimmed
    assert_equal "$out" "hidden-config" "Strips traversal and leading dots"
}

# 4. Replace unsafe chars
test_sanitize_replaces_unsafe() {
    local out
    out=$(systems::sanitize_filename "file name(1).txt")
    assert_equal "$out" "file-name-1-.txt" "Replaces spaces and parentheses with dashes"
}

# 5. Collapse repeated dots
test_sanitize_collapse_repeated_dots() {
    local out
    out=$(systems::sanitize_filename "archive..tar....gz")
    assert_equal "$out" "archive.tar.gz" "Collapses repeated dots"
}

main() { run_test_suite; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
