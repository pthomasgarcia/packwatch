#!/usr/bin/env bash
# ==============================================================================
# MODULE: src/lib/progress.sh
# ==============================================================================
# Responsibilities:
#   - Functions for rendering and managing download progress bars.
# ==============================================================================

# Source necessary globals for formatting
: "${CORE_DIR:?CORE_DIR must be set before sourcing core modules}"
# shellcheck source=src/core/globals.sh
source "$CORE_DIR/globals.sh"
# shellcheck source=src/core/interfaces.sh
source "$CORE_DIR/interfaces.sh"
# Helper function for formatting bytes for progress tracking
_format_bytes() {
    local bytes="$1"
    if ((bytes < 1024)); then
        echo "${bytes} B"
    elif ((bytes < 1024 * 1024)); then
        # Convert to KB with rounding to nearest tenth using integer arithmetic
        local unit=1024
        local tenths=$(((bytes * 10 + unit / 2) / unit))
        local int_part=$((tenths / 10))
        local frac_part=$((tenths % 10))
        echo "${int_part}.${frac_part} KB"
    elif ((bytes < 1024 * 1024 * 1024)); then
        # Convert to MB with rounding to nearest tenth using integer arithmetic
        local unit=$((1024 * 1024))
        local tenths=$(((bytes * 10 + unit / 2) / unit))
        local int_part=$((tenths / 10))
        local frac_part=$((tenths % 10))
        echo "${int_part}.${frac_part} MB"
    else
        # Convert to GB with rounding to nearest tenth using integer arithmetic
        local unit=$((1024 * 1024 * 1024))
        local tenths=$(((bytes * 10 + unit / 2) / unit))
        local int_part=$((tenths / 10))
        local frac_part=$((tenths % 10))
        echo "${int_part}.${frac_part} GB"
    fi
}

# Renders the custom progress bar.
# Usage: progress::render_bar "app_name" "downloaded_bytes" "total_bytes" [current_speed] [time_remaining]
progress::render_bar() {
    local app_name="$1"
    local downloaded="$2"
    local total="$3"
    local speed="${4:-}" # Optional speed (e.g., "1.2 MB/s")
    local eta="${5:-}"   # Optional ETA (e.g., "00:15")

    local percent=0
    local total_disp="unknown"
    local downloaded_disp="unknown"

    if [[ "$downloaded" =~ ^[0-9]+$ ]]; then
        downloaded_disp="$(_format_bytes "$downloaded")"
    fi
    if [[ "$total" =~ ^[0-9]+$ ]] && ((total > 0)); then
        total_disp="$(_format_bytes "$total")"
        if [[ "$downloaded" =~ ^-?[0-9]+$ ]]; then
            # Coerce negative values to 0 before computing percent
            ((downloaded < 0)) && downloaded=0
            percent=$((downloaded * 100 / total))
            # Clamp percent into [0,100]
            ((percent < 0)) && percent=0
            ((percent > 100)) && percent=100
        fi
    fi

    # Bar characters
    local bar_width=20
    local filled_chars=$((percent * bar_width / 100))
    local empty_chars=$((bar_width - filled_chars))
    local bar_filled=""
    local bar_empty=""
    local i

    for ((i = 0; i < filled_chars; i++)); do bar_filled="${bar_filled}|"; done # Use pipe for filled
    # No pointer character
    for ((i = 0; i < empty_chars; i++)); do bar_empty="${bar_empty} "; done

    local progress_string="[${bar_filled:0:bar_width}${bar_empty:0:$((bar_width - ${#bar_filled}))}] ${percent}% (${downloaded_disp} / ${total_disp})"

    if [[ -n "$speed" ]]; then
        progress_string="${progress_string} ${speed}"
    fi
    if [[ -n "$eta" ]]; then
        progress_string="${progress_string} ETA ${eta}"
    fi

    # Use interfaces::print_ui_line to ensure consistent UI, adding carriage return
    # and ensuring no newline for dynamic update
    interfaces::print_ui_line "  " "⤓ " "Downloading ${FORMAT_BOLD}$app_name${FORMAT_RESET}: ${progress_string}" "" "\r" >&2
}

# Clears the current progress line by overwriting it with spaces and then a newline.
# This should be called after the download is complete or failed to ensure a clean terminal.
progress::clear_line() {
    # Move cursor to beginning of line and overwrite with spaces, then move back
    local cols
    cols="$(tput cols 2> /dev/null || echo 80)"
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    printf "\r%*s\r" "$cols" ""
    # Print a final newline to ensure subsequent output starts on a fresh line
    printf "\n"
}
