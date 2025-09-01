#!/usr/bin/env bash
# ==============================================================================
# MODULE: string_utils.sh
# ==============================================================================
# Responsibilities:
#   - String manipulation utilities.
#
# Dependencies:
#   - None
# ==============================================================================

# Extract the value of a "Key: Value" line from given text; echoes the
# trimmed value.
# Usage: string_utils::extract_colon_value "<TEXT>" "<KEY_REGEX>"
string_utils::extract_colon_value() {
    local text="$1" key_re="$2"
    awk -F: -v key_re="$key_re" '
        {
          k=$1
          gsub(/^[ \t]+|[ \t]+$/, "", k)
          if (k ~ key_re) {
             v=$2
             sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
             print v
             exit
          }
        }' <<< "$text" | xargs
}
