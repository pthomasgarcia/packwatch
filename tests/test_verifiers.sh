#!/usr/bin/env bash
#
# Test suite for the verifiers.sh module.
#
# This test suite uses a simple, custom testing framework defined in tests/test_helpers.sh.
# It covers various scenarios for checksum and GPG signature verification to ensure
# the verifiers.sh module is robust and reliable.
#
# To run this test suite:
#   ./tests/test_verifiers.sh
#

# --- Test Setup ---

# Set the base directory for the test suite
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR

# Source the test helpers
# shellcheck source=/dev/null
source "$TEST_DIR/test_helpers.sh"

# Source the module to be tested
# shellcheck source=/dev/null
source "$TEST_DIR/../src/lib/verifiers.sh"

# --- Mocks and Stubs ---

# Mock dependencies to isolate the verifiers.sh module during tests.
# This allows us to control the behavior of external commands like sha256sum and gpg.

sha256sum() {
    if [[ "${MOCK_SHA256SUM_FAIL:-0}" -eq 1 ]]; then
        echo "bad_checksum  $1"
    else
        echo "mock_checksum  $1"
    fi
}

gpg() {
    if [[ "${MOCK_GPG_FAIL:-0}" -eq 1 ]]; then
        return 1
    else
        return 0
    fi
}

# Mock other dependencies
interfaces::print_ui_line() { :; }
loggers::log_message() { :; }
errors::handle_error() { :; }
updates::trigger_hooks() { :; }
networks::download_text_to_cache() { echo "mock_checksum_file"; }
networks::url_exists() { return 0; }
validators::extract_checksum_from_file() { echo "mock_checksum"; }
systems::unregister_temp_file() { :; }
gpg::verify_detached() {
    if [[ "${MOCK_GPG_VERIFY_FAIL:-0}" -eq 1 ]]; then
        return 1
    else
        return 0
    fi
}

# --- Test Cases ---

test_compute_checksum() {
    local result
    result=$(verifiers::compute_checksum "/tmp/dummy_file")
    assert_equal "$result" "mock_checksum" "test_compute_checksum: computes checksum correctly"
}

test_verify_checksum_success() {
    assert_success "verifiers::verify_checksum should succeed with matching checksums" \
        verifiers::verify_checksum "/tmp/dummy_file" "mock_checksum"
}

test_verify_checksum_failure() {
    assert_failure "verifiers::verify_checksum should fail with mismatched checksums" \
        verifiers::verify_checksum "/tmp/dummy_file" "wrong_checksum"
}

test_verify_signature_success() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
    )
    assert_success "verifiers::verify_signature should succeed with valid signature" \
        verifiers::verify_signature MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file"
}

test_verify_signature_failure() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
    )
    MOCK_GPG_VERIFY_FAIL=1
    assert_failure "verifiers::verify_signature should fail with invalid signature" \
        verifiers::verify_signature MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file"
    unset MOCK_GPG_VERIFY_FAIL
}

test_verify_artifact_checksum_only_success() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
    )
    assert_success "verifiers::verify_artifact should succeed with valid checksum only" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file" "mock_checksum"
}

test_verify_artifact_checksum_only_failure() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
    )
    assert_failure "verifiers::verify_artifact should fail with invalid checksum only" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file" "wrong_checksum"
}

test_verify_artifact_signature_only_success() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
        [skip_checksum]=1
    )
    assert_success "verifiers::verify_artifact should succeed with valid signature only" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file"
}

test_verify_artifact_signature_only_failure() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
        [skip_checksum]=1
    )
    MOCK_GPG_VERIFY_FAIL=1
    assert_failure "verifiers::verify_artifact should fail with invalid signature only" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file"
    unset MOCK_GPG_VERIFY_FAIL
}

test_verify_artifact_both_success() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
    )
    assert_success "verifiers::verify_artifact should succeed with both valid checksum and signature" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file" "mock_checksum"
}

test_verify_artifact_checksum_fails() {
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
    )
    assert_failure "verifiers::verify_artifact should fail if checksum is invalid" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file" "wrong_checksum"
}

test_verify_artifact_signature_fails() {
    # shellcheck disable=SC2034
    declare -A MOCK_CONFIG=(
        [name]="test-app"
        [gpg_key_id]="TESTKEY"
        [gpg_fingerprint]="TESTFINGERPRINT"
    )
    MOCK_GPG_VERIFY_FAIL=1
    assert_failure "verifiers::verify_artifact should fail if signature is invalid" \
        verifiers::verify_artifact MOCK_CONFIG "/tmp/dummy_file" "http://example.com/file" "mock_checksum"
    unset MOCK_GPG_VERIFY_FAIL
}

# --- Test Runner ---

main() {
    run_test_suite
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
