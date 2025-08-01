#!/usr/bin/env bash
# ==============================================================================
# Packwatch: Counter Management
# ==============================================================================
# Centralized management of all application state counters.
# ==============================================================================

# --- Counter Definitions ---
declare -Ag COUNTERS=(
    ["updated"]=0
    ["up_to_date"]=0
    ["failed"]=0
    ["skipped"]=0
)

# --- Counter Management Functions ---
counters::reset() {
    COUNTERS["updated"]=0
    COUNTERS["up_to_date"]=0
    COUNTERS["failed"]=0
    COUNTERS["skipped"]=0
}

counters::inc() {
    local counter_type=$1
    if [[ -z "${COUNTERS[$counter_type]:-}" ]]; then
        loggers::log_message "ERROR" "Invalid counter type: $counter_type"
        return 1
    fi
    ((COUNTERS["$counter_type"]++))
    return 0
}

counters::get() {
    local counter_type=$1
    if [[ -z "${COUNTERS[$counter_type]:-}" ]]; then
        loggers::log_message "ERROR" "Invalid counter type: $counter_type"
        return 1
    fi
    printf '%d' "${COUNTERS[$counter_type]}"
    return 0
}

counters::set() {
    local counter_type=$1
    local value=$2
    
    if [[ -z "${COUNTERS[$counter_type]:-}" ]]; then
        loggers::log_message "ERROR" "Invalid counter type: $counter_type"
        return 1
    fi
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        loggers::log_message "ERROR" "Invalid counter value: $value (must be a non-negative integer)"
        return 1
    fi
    
    COUNTERS["$counter_type"]=$value
    return 0
}

counters::dump() {
    loggers::log_message "DEBUG" "Counter state:"
    loggers::log_message "DEBUG" "  updated:    $(counters::get updated)"
    loggers::log_message "DEBUG" "  up_to_date: $(counters::get up_to_date)"
    loggers::log_message "DEBUG" "  failed:     $(counters::get failed)"
    loggers::log_message "DEBUG" "  skipped:    $(counters::get skipped)"
}

# --- Convenience Functions for Common Operations ---
counters::inc_updated() { counters::inc "updated"; }
counters::inc_up_to_date() { counters::inc "up_to_date"; }
counters::inc_failed() { counters::inc "failed"; }
counters::inc_skipped() { counters::inc "skipped"; }

counters::get_updated() { counters::get "updated"; }
counters::get_up_to_date() { counters::get "up_to_date"; }
counters::get_failed() { counters::get "failed"; }
counters::get_skipped() { counters::get "skipped"; }
