SHELL := /usr/bin/env bash

# Flags kept in one place to match CI exactly
SHELLCHECK_FLAGS := -S style -x
SHFMT_FLAGS := -i 4 -ci -sr

.PHONY: lint-shell format-shell format-check ci tools

# Optional: verify tools exist locally
tools:
	@command -v shellcheck >/dev/null || { echo "shellcheck not found"; exit 1; }
	@command -v shfmt >/dev/null || { echo "shfmt not found"; exit 1; }

lint-shell: tools
	@mapfile -t files < <(git ls-files '*.sh'); \
	if [ "$${#files[@]}" -eq 0 ]; then \
		echo "No shell scripts found."; \
	else \
		shellcheck $(SHELLCHECK_FLAGS) "$${files[@]}"; \
	fi

# Check formatting (no write) — same as the Action step
format-check: tools
	@shfmt -d $(SHFMT_FLAGS) .

# Auto-format locally if you want fixes applied
format-shell: tools
	@shfmt -w $(SHFMT_FLAGS) .

# CI target: run ShellCheck then shfmt diff
ci: lint-shell format-check
	@echo "CI checks passed."
