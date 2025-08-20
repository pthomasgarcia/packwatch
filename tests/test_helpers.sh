#!/usr/bin/env bash
#
# A simple, custom testing framework for Packwatch.
#
# This framework provides basic assertion functions and a test runner to facilitate
# the creation of test suites for the various modules in the project.
#

# --- Global State ---

# Counters for tracking test results
TEST_TOTAL=0
TEST_PASSED=0
TEST_FAILED=0

# --- Assertion Functions ---

# Assert that a command succeeds (returns exit code 0).
# Usage: assert_success "Description of the test"
assert_success() {
    local description="$1"
    shift
    ((TEST_TOTAL++))

    if "$@"; then
        echo "✓ PASS: $description"
        ((TEST_PASSED++))
    else
        echo "✗ FAIL: $description"
        ((TEST_FAILED++))
    fi
}

# Assert that a command fails (returns a non-zero exit code).
# Usage: assert_failure "Description of the test"
assert_failure() {
    local description="$1"
    shift
    ((TEST_TOTAL++))

    if ! "$@"; then
        echo "✓ PASS: $description"
        ((TEST_PASSED++))
    else
        echo "✗ FAIL: $description"
        ((TEST_FAILED++))
    fi
}
# Assert that two strings are equal.
# Usage: assert_equal "actual" "expected" "Description of the test"
assert_equal() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    ((TEST_TOTAL++))

    if [[ "$actual" == "$expected" ]]; then
        echo "✓ PASS: $description"
        ((TEST_PASSED++))
    else
        echo "✗ FAIL: $description (Expected: '$expected', Got: '$actual')"
        ((TEST_FAILED++))
    fi
}

# Assert that a string contains a substring.
# Usage: assert_contains "haystack" "needle" "Description of the test"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    ((TEST_TOTAL++))
    # Treat empty needle as a hard error (mis-specified test)
    if [[ -z "$needle" ]]; then
        echo "✗ FAIL: $description (empty needle)"
        ((TEST_FAILED++))
        return 1
    fi

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "✓ PASS: $description"
        ((TEST_PASSED++))
    else
        # Escape / quote both haystack and needle so whitespace & special chars are visible
        local q_haystack q_needle
        q_haystack=$(printf '%q' "$haystack")
        q_needle=$(printf '%q' "$needle")
        echo "✗ FAIL: $description (substring not found) haystack=$q_haystack needle=$q_needle"
        ((TEST_FAILED++))
    fi
}

# Assert that a string does NOT contain a substring.
# Usage: assert_not_contains "haystack" "needle" "Description of the test"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    ((TEST_TOTAL++))

    # Treat empty needle as a hard error (mis-specified test)
    if [[ -z "$needle" ]]; then
        echo "✗ FAIL: $description (empty needle)"
        ((TEST_FAILED++))
        return 1
    fi

    if [[ "$haystack" == *"$needle"* ]]; then
        local q_haystack q_needle
        q_haystack=$(printf '%q' "$haystack")
        q_needle=$(printf '%q' "$needle")
        echo "✗ FAIL: $description (unexpected substring present) haystack=$q_haystack needle=$q_needle"
        ((TEST_FAILED++))
        return 1
    else
        echo "✓ PASS: $description"
        ((TEST_PASSED++))
        return 0
    fi
}

# --- Test Runner ---

# Run all functions in the current script that start with "test_".
run_test_suite() {
    echo "Running test suite: ${BASH_SOURCE[1]}"
    echo "----------------------------------------"

    # Find all test functions
    local test_functions
    test_functions=$(declare -F | awk '{print $3}' | grep "^test_")

    # Execute each test function
    for func in $test_functions; do
        $func
    done

    echo "----------------------------------------"
    echo "Test Results: $TEST_PASSED passed, $TEST_FAILED failed, $TEST_TOTAL total."

    # Return a non-zero exit code if any tests failed
    if [[ $TEST_FAILED -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}
