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
    if command -v notify-send &>/dev/null; then
        # If running under sudo, send as the original user
        if [[ -n "$SUDO_USER" ]]; then
            local original_user_id
            original_user_id=$(getent passwd "$SUDO_USER" | cut -d: -f3 2>/dev/null)
            if [[ -n "$original_user_id" ]]; then
                sudo -u "$SUDO_USER" env \
                    DISPLAY=:0 \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${original_user_id}/bus" \
                    notify-send --urgency="$urgency" "$title" "$message" 2>/dev/null || true
            else
                loggers::log_message "WARN" "Could not determine user ID for '$SUDO_USER'. Cannot send desktop notification."
            fi
        else
            notify-send --urgency="$urgency" "$title" "$message" 2>/dev/null || true
        fi
    fi
}

# ==============================================================================
# END OF MODULE
# ==============================================================================
