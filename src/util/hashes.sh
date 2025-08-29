#!/usr/bin/env bash

# ==============================================================================
# MODULE: util/hashes.sh
# ==============================================================================
# Responsibilities:
#   - Provides utility functions for generating hashes.
# ==============================================================================

# Generates a hash for the given input string using SHA256, SHA1, or MD5.
# Arguments:
#   $1 - The string to hash.
# Returns:
#   The generated hash string.
hashes::generate() {
    local input_string="$1"
    # Validate required argument: must be set and non-empty
    if [[ -z "${input_string+x}" || -z "$input_string" ]]; then
        echo "hashes::generate: input_string is required" >&2
        return 1
    fi
    local _hash
    if command -v sha256sum > /dev/null 2>&1; then
        _hash="$(printf %s "$input_string" | sha256sum | cut -d' ' -f1)"
    elif command -v shasum > /dev/null 2>&1; then
        _hash="$(printf %s "$input_string" | shasum -a 256 | cut -d' ' -f1)"
    else
        _hash="$(printf %s "$input_string" | md5sum | cut -d' ' -f1)"
    fi
    printf "%s" "$_hash"
}
