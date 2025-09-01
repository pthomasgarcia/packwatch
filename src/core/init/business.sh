#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for business module
if [ -n "${PACKWATCH_BUSINESS_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_BUSINESS_LOADED=1

# Packwatch Phase 3b: Business
# Purpose: Load the central module that defines the application's
# core business logic,
# orchestrating the update checking and installation workflows.

# Required: All modules from Phase 0 (bootloader), Phase 1 (interface),
#           Phase 2 (scaffolding), and Phase 3a (runtime).
# updates.sh relies heavily on all modules loaded in previous phases.

# Strict sourcing order:
# 1. updates.sh: The main orchestrator of the update process, dispatching to
#    type-specific handlers and managing the update flow.

source "$CORE_DIR/updates.sh"

# Any module sourced by this phase should implement an idempotent guard
# (e.g., PACKWATCH_MODULE_LOADED).
