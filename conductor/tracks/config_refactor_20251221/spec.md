# Specification: Configuration Refactor

## 1. Overview
The current configuration system relies on flat JSON files which can be error-prone and difficult to validate. This track aims to migrate to a structured schema approach, improving validation, readability, and type safety for application configurations.

## 2. Goals
- Define a strict JSON schema for application checker configurations.
- Implement a validation step that checks all config files against this schema on startup.
- Refactor existing configuration loading logic to support nested structures (if beneficial) and clearer field definitions.
- Ensure backward compatibility or provide a migration script for existing configurations.

## 3. Technical Implementation
- **Schema Definition:** Create a `schema.json` that defines required fields (`name`, `check_type`, `url`, etc.) and optional metadata.
- **Validation Logic:** Use `jsonschema` (if available via python/node) or a `jq`-based validator to enforce structure.
- **Refactoring:** Update `src/core/configs.sh` to load and validate configurations using the new schema.
- **Migration:** Convert existing files in `config/conf.d/` to match the strict schema if necessary.

## 4. Acceptance Criteria
- [ ] A formal JSON schema exists in `config/schema.json`.
- [ ] Packwatch fails to start (or skips invalid files) with a clear error if a config file violates the schema.
- [ ] All existing configuration files pass validation.
- [ ] New configuration fields (e.g., `version_extraction_regex`) are documented in the schema.
