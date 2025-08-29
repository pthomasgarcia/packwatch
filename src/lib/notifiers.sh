#!/usr/bin/env bash
# ==============================================================================
# MODULE: notifiers.sh
# ==============================================================================
# Responsibilities:
#   - Desktop notifications for user-facing events
#
# Usage:
#   Source this file in your main script:
#     source "$CORE_DIR/notifiers.sh"
#
#   Then use:
#     notifiers::send_notification "Title" "Message" "urgency"
#
# Dependencies:
#   - loggers.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Notifier Function
# ------------------------------------------------------------------------------

# Send a desktop notification.
# Usage: notifiers::send_notification "Title" "Message" "urgency"
#   Title   - Notification title
#   Message - Notification body
#   Urgency - (Optional) "low", "normal", or "critical" (default: "normal")
notifiers::send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    # Only send notification if notify-send is available
    if command -v notify-send &> /dev/null; then
        # If running under sudo, send as the original user
        # If running under sudo, send as the original user. Otherwise, send as the current user.
        local target_user="${SUDO_USER:-$USER}"
        local user_id
        user_id=$(getent passwd "$target_user" | cut -d: -f3 2> /dev/null)

        if [[ -z "$user_id" ]]; then
            loggers::warn "Could not determine user ID for '$target_user'. Cannot send desktop notification."
            return
        fi

        # Construct the command to run as the target user
        local notify_cmd=(
            "env"
            "DISPLAY=:0"
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${user_id}/bus"
            "notify-send" "--urgency=$urgency" "$title" "$message"
        )

        if [[ $(id -u) -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "$target_user" "${notify_cmd[@]}" 2> /dev/null || true
        else
            "${notify_cmd[@]}" 2> /dev/null || true
        fi
    fi
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
