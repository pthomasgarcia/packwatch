# Plan: Configuration Refactor

## Phase 1: Schema Definition & Validation Logic
- [ ] Task: Define the initial JSON schema in `config/schema.json` capturing all current configuration properties.
- [ ] Task: Create a validation script `src/lib/validators.sh` (or append to existing) using `jq` to validate config files against the schema.
- [ ] Task: Write unit tests for the validator to ensure it correctly identifies valid and invalid JSON structures.
- [ ] Task: Conductor - User Manual Verification 'Schema Definition & Validation Logic' (Protocol in workflow.md)

## Phase 2: Core Engine Integration
- [ ] Task: Modify `src/core/configs.sh` to invoke the validator before loading configurations.
- [ ] Task: Implement error handling to log validation failures to `stderr` and skip invalid files (or halt based on strictness settings).
- [ ] Task: Conductor - User Manual Verification 'Core Engine Integration' (Protocol in workflow.md)

## Phase 3: Migration & Cleanup
- [ ] Task: Audit all existing files in `config/conf.d/` and ensure they comply with the new `schema.json`.
- [ ] Task: Update documentation to reflect the new configuration schema and validation rules.
- [ ] Task: Conductor - User Manual Verification 'Migration & Cleanup' (Protocol in workflow.md)
