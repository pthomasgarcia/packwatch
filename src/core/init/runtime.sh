#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# Idempotent guard for runtime module
if [ -n "${PACKWATCH_RUNTIME_LOADED:-}" ]; then
    return 0
fi
PACKWATCH_RUNTIME_LOADED=1

# Packwatch Phase 3a: Runtime
# Purpose: Load core application mechanisms and utilities.
# These modules provide the foundational services (e.g., version handling,
# network communication, repository interaction, package management)
# upon which the main business logic (in business.sh) will operate.

# Required: All modules from Phase 0 (bootloader), Phase 1 (interface),
#           and Phase 2 (scaffolding).

# Strict sourcing order:
# 1. versions.sh: Handles version string normalization and comparison. Used by
#    various modules for version logic.
# 2. networks.sh: Manages all network requests, downloads, and caching.
#    Relies on systems.sh and configs.sh for global settings.
# 3. repositories.sh: Interacts with external code repositories (e.g., GitHub API).
#    Relies heavily on networks.sh and versions.sh.
# 4. packages.sh: Manages installed versions and handles package installation.
#    Relies on networks.sh, systems.sh, versions.sh.

source "$CORE_DIR/../lib/versions.sh"
source "$CORE_DIR/../lib/networks.sh"
source "$CORE_DIR/repositories.sh"
source "$CORE_DIR/../lib/verifiers.sh"
source "$CORE_DIR/packages.sh"

# Any module sourced by this phase should implement an idempotent guard
# (e.g., PACKWATCH_MODULE_LOADED).
