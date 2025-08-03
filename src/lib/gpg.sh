#!/usr/bin/env bash

# GPG module; provides functions for GPG key management and verification.

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
	actual_fingerprint=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
		gpg --fingerprint --with-colons "$key_id" 2>/dev/null |
		awk -F: '/^fpr:/ {print $10}' | head -n1)

	local normalized_expected="${expected_fingerprint//[[:space:]]/}"
	local normalized_actual="${actual_fingerprint//[[:space:]]/}"

	if [[ -n "$actual_fingerprint" ]] && [[ "$normalized_actual" == "$normalized_expected" ]]; then
		loggers::print_message "✓ GPG key is already present and verified."
		return 0
	fi

	loggers::print_message "⚠️  GPG key for $app_name (ID: $key_id) not found or fingerprint mismatch."
	loggers::print_message "    To proceed with secure updates, you MUST manually import and verify this key."
	loggers::print_message "    Please run the following commands in your terminal (as your regular user, NOT root):"
	loggers::print_message ""
	loggers::print_message "    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $key_id"
	loggers::print_message "    gpg --fingerprint $key_id"
	loggers::print_message ""
	loggers::print_message "    Carefully compare the displayed fingerprint with the expected one:"
	loggers::print_message "    Expected: $expected_fingerprint"
	loggers::print_message "    Actual:   $actual_fingerprint (if present)"
	loggers::print_message ""

	if interfaces::confirm_prompt "Have you manually imported the key and verified its fingerprint?" "N"; then
		# Re-check after user confirmation
		actual_fingerprint=$(sudo -u "$ORIGINAL_USER" GNUPGHOME="$ORIGINAL_HOME/.gnupg" \
			gpg --fingerprint --with-colons "$key_id" 2>/dev/null |
			awk -F: '/^fpr:/ {print $10}' | head -n1)
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
