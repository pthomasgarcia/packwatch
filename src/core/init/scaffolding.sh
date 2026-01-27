#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for scaffolding module
if [ -n "${PACKWATCH_SCAFFOLDING_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_SCAFFOLDING_LOADED=1

# Packwatch Phase 2: Scaffolding
# Purpose: Load modules that provide the core application framework, including
# configuration management, state counters, and basic user notifications.
# These are essential building blocks before the main runtime logic.

# Required: globals.sh, systems.sh, loggers.sh, errors.sh (from Phase 0)
#           validators.sh, interfaces.sh, cli.sh (from Phase 1)

# Strict sourcing order:
# 1. configs.sh: Central to loading application configurations.
# 2. counters.sh: Manages application-wide statistics.
# 3. notifiers.sh: Handles desktop notifications.

source "$CORE_DIR/configs.sh"
source "$CORE_DIR/../lib/counters.sh"
source "$CORE_DIR/../lib/notifiers.sh"
source "$CORE_DIR/../lib/gpg.sh"
source "$CORE_DIR/../lib/string_utils.sh"
source "$CORE_DIR/../lib/systems.sh"
source "$CORE_DIR/../lib/responses.sh"
source "$CORE_DIR/../lib/web_parsers.sh"

# Any module sourced by this phase should implement an idempotent guard
# (e.g., PACKWATCH_MODULE_LOADED).

# ==============================================================================
# END OF MODULE
# ==============================================================================
