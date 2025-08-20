#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/core/updates/validation.sh
# ==============================================================================
# Responsibilities:
#   - Provides functions for validating application configurations.
# ==============================================================================

# Validates the application configuration against predefined schemas.
# Usage: updates::_validate_app_config app_type_string app_config_nameref_string
# Returns 0 if valid, 1 if invalid. Logs errors internally.
updates::_validate_app_config() {
    local app_type="$1"
    local -n config_ref=$2 # Use nameref for the actual config array

    local app_name="${config_ref[name]:-unknown_app}"

    local required_fields_str
    if [[ -v APP_TYPE_VALIDATIONS["$app_type"] ]]; then
        required_fields_str="${APP_TYPE_VALIDATIONS[$app_type]}" # May be empty: means no required fields.
    else
        errors::handle_error "CONFIG_ERROR" "No validation schema found for app type '$app_type'." "$app_name" "Please define it in APP_TYPE_VALIDATIONS."
        updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"config_validation\", \"error_type\": \"CONFIG_ERROR\", \"message\": \"No validation schema found for app type.\"}"
        return 1
    fi

    local field
    if [[ -n "$required_fields_str" ]]; then
        IFS=',' read -ra fields <<< "$required_fields_str"
        local field
        for field in "${fields[@]}"; do
            # Skip empty tokens (in case of trailing commas or accidental double commas)
            [[ -z "$field" ]] && continue
            if [[ -z "${config_ref[$field]:-}" ]]; then
                errors::handle_error "VALIDATION_ERROR" "Missing required field '$field' for app type '$app_type'." "$app_name"
                updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"config_validation\", \"error_type\": \"VALIDATION_ERROR\", \"message\": \"Missing required field '$field'.\"}"
                return 1
            fi
        done
    fi

    return 0
}
