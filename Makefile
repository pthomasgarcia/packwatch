SHELL := /usr/bin/env bash

# Flags kept in one place to match CI exactly
# -i 4 = 4 spaces per indent for normal blocks
# -ci = indent switch cases
# -sr = simplify redirects
# -ln bash = enforce Bash mode
# -kp = keep existing indentation on continuation lines
SHFMT_FLAGS := -i 4 -ci -sr -ln bash -kp
SHELLCHECK_FLAGS := -S style -x

.PHONY: lint-shell format-shell format-check check-line-length ci tools

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

# Check line length using shfmt (80 chars by default)
check-line-length: tools
	@echo "Checking line lengths with shfmt..."
	@shfmt -l -d $(SHFMT_FLAGS) . || { \
		echo "Some files have formatting issues or long lines"; \
		exit 1; \
	}

# Check formatting (no write)
format-check: tools
	@shfmt -d $(SHFMT_FLAGS) .

# Auto-format locally
format-shell: tools
	@shfmt -w $(SHFMT_FLAGS) .

# CI target
ci: lint-shell check-line-length
	@echo "CI checks passed."
