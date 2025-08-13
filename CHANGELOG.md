# Changelog

## [1.0.0] - YYYY-MM-DD

### Features

- **Centralized Verification Logic:** The artifact verification process has been completely centralized into the `verifiers.sh` module. This includes checksum (sha256/sha512) and GPG signature verification. All legacy and inline verification logic has been removed from other modules, and all verification flows now use the public API provided by `verifiers.sh`.

### Refactoring

- **Hardened Verification Module:** The `verifiers.sh` and `gpg.sh` modules have been hardened for improved portability and robustness. This includes the addition of idempotent guards, the removal of brittle `sudo`-based logic in favor of temporary GPG keyrings, and the enforcement of a deterministic library loading order.

### Testing

- **Added Test Suite for Verification:** A comprehensive, automated test suite has been added for the `verifiers.sh` module. These tests cover the full verification matrix, including checksums, signatures, and combined scenarios, and are now integrated into the CI pipeline.
