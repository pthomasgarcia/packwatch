#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

# Packwatch Phase 0: Bootloader
# Purpose: Initialize the most fundamental environment for safe execution.
# This phase ensures core globals, system utilities, logging, and error handling
# are available from the earliest possible moment.

# Note: CORE_DIR must be set by main.sh before sourcing this file.

# Strict sourcing order:
# 1. globals.sh: Defines core constants, global variables, and initial state (like exit codes).
# 2. systems.sh: Provides low-level system helpers (temp files, dependency checks, cleanup traps).
# 3. loggers.sh: Enables basic logging to stderr/stdout.
# 4. errors.sh: Provides centralized error handling, relying on loggers.sh.

source "$CORE_DIR/globals.sh"
source "$CORE_DIR/../lib/systems.sh"
source "$CORE_DIR/../lib/loggers.sh"
source "$CORE_DIR/../lib/errors.sh"

# Any module sourced by this phase should implement an idempotent guard
# (e.g., PACKWATCH_MODULE_LOADED).
