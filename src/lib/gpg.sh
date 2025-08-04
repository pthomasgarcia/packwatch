#!/usr/bin/env bash

# GPG module; provides functions for GPG key management and verification.
#
# Dependencies:
#   - errors.sh
#   - globals.sh
#   - interfaces.sh
#   - loggers.sh
# ==============================================================================

# Internal helper to get GPG fingerprint as the original user, with robust error handling.
# Args:
#   $1: key_id (string) - The GPG key ID.
# Returns:
#   The GPG fingerprint if successful, empty string otherwise. Logs errors.
_get_gpg_fingerprint_as_user() {
	local key_id="$1"
	local gpg_output=""
	local gpg_error_output=""

	if [[ -z "$ORIGINAL_USER" ]]; then
		loggers::log_message "ERROR" "ORIGINAL_USER is not set. Cannot perform GPG operation as original user. Falling back to root."
		gpg_output=$(gpg --fingerprint --with-colons "$key_id" 2>&1)
	elif ! getent passwd "$ORIGINAL_USER" &>/dev/null; then
		loggers::log_message "ERROR" "ORIGINAL_USER '$ORIGINAL_USER' does not exist. Cannot perform GPG operation as original user. Falling back to root."
		gpg_output=$(gpg --fingerprint --with-colons "$key_id" 2>&1)
	elif [[ ! -d "$ORIGINAL_HOME" ]]; then
		loggers::log_message "ERROR" "ORIGINAL_HOME '$ORIGINAL_HOME' is not a valid directory. Cannot perform GPG operation as original user. Falling back to root."
		gpg_output=$(gpg --fingerprint --with-colons "$key_id" 2>&1)
	elif [[ ! -d "$ORIGINAL_HOME/.gnupg" ]]; then
		loggers::log_message "ERROR" "GPG home directory '$ORIGINAL_HOME/.gnupg' does not exist. Cannot perform GPG operation as original user. Falling back to root."
		gpg_output=$(gpg --fingerprint --with-colons "$key_id" 2>&1)
	else
		# Attempt as original user, capturing stderr
		gpg_output=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
			gpg --fingerprint --with-colons "$key_id" 2>&1)
	fi

	# Check if gpg_output contains error indicators or if gpg command failed
	if echo "$gpg_output" | grep -qE "(gpg:|error:|failed|No public key)"; then
		gpg_error_output="$gpg_output" # Capture the full output as error
		loggers::log_message "ERROR" "GPG command failed or returned an error: $gpg_error_output"
		return 1 # Indicate failure
	fi

	echo "$gpg_output" | awk -F: '/^fpr:/ {print $10}' | head -n1
	return 0 # Indicate success
}

# GPG module; prompts the user to import and verify a GPG key if not already present.
# Args:
#   $1: key_id (string) - The GPG key ID to import.
#   $2: expected_fingerprint (string) - The expected fingerprint for verification.
#   $3: app_name (string) - The name of the application for context in messages.
# Returns:
#   0 on success (key is present and verified or user confirmed manual import), 1 on failure.
gpg::prompt_import_and_verify() {
	local key_id="$1"
	local expected_fingerprint="$2"
	local app_name="$3"

	loggers::print_message "→ Checking GPG key for $app_name..."

	local actual_fingerprint
	actual_fingerprint=$(_get_gpg_fingerprint_as_user "$key_id")

	local normalized_expected="${expected_fingerprint//[[:space:]]/}"
	local normalized_actual="${actual_fingerprint//[[:space:]]/}"

	if [[ -n "$actual_fingerprint" ]] && [[ "$normalized_actual" == "$normalized_expected" ]]; then
		loggers::print_message "✓ GPG key is already present and verified."
		return 0
	fi

	loggers::print_message "⚠️  GPG key for $app_name (ID: $key_id) not found or fingerprint mismatch."
	loggers::log_message "    To proceed with secure updates, you MUST manually import and verify this key."
	loggers::log_message "    Please run the following commands in your terminal (as your regular user, NOT root):"
	loggers::log_message ""
	loggers::log_message "    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $key_id"
	loggers::log_message "    gpg --fingerprint $key_id"
	loggers::log_message ""
	loggers::log_message "    Carefully compare the displayed fingerprint with the expected one:"
	loggers::log_message "    Expected: $expected_fingerprint"
	loggers::log_message "    Actual:   $actual_fingerprint (if present)"
	loggers::log_message ""

	if interfaces::confirm_prompt "Have you manually imported the key and verified its fingerprint?" "N"; then
		# Re-check after user confirmation
		actual_fingerprint=$(_get_gpg_fingerprint_as_user "$key_id")
		normalized_actual="${actual_fingerprint//[[:space:]]/}"

		if [[ -n "$actual_fingerprint" ]] && [[ "$normalized_actual" == "$normalized_expected" ]]; then
			loggers::print_message "✓ GPG key successfully imported and verified by user."
			return 0
		else
			errors::handle_error "GPG_ERROR" "GPG key import or fingerprint verification failed after manual attempt for $app_name." "$app_name"
			return 1
		fi
	else
		errors::handle_error "GPG_ERROR" "GPG key import and verification skipped by user for $app_name. Aborting secure update." "$app_name"
		return 1
	fi
}
