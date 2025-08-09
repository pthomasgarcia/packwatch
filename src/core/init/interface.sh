#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for interface module
if [ -n "${PACKWATCH_INTERFACE_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_INTERFACE_LOADED=1

# Packwatch Phase 1: Interface
# Purpose: Load modules necessary for Command Line Interface (CLI) parsing and user output
# related to early execution stages (e.g., --help, --version).

# Required: globals.sh, systems.sh, loggers.sh, errors.sh from Phase 0.

# Strict sourcing order:
# 1. validators.sh: Provides basic validation helpers (e.g., URL format, file paths).
#    Needed by CLI/interfaces for argument validation.
# 2. interfaces.sh: Handles user-facing output like headers, prompts, and general UI.
#    Needed early for --help/--version messages.
# 3. cli.sh: Contains the primary logic for parsing command-line arguments.
#    Relies on interfaces.sh for help output and validators.sh for arg validation.

source "$CORE_DIR/../lib/validators.sh"
source "$CORE_DIR/interfaces.sh"
source "$CORE_DIR/cli.sh"

# Any module sourced by this phase should implement an idempotent guard
# (e.g., PACKWATCH_MODULE_LOADED).
