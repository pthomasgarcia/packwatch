# Tech Stack - Packwatch

## Core Technologies
- **Bash:** The primary programming language used for the core engine, modular checkers, and utility scripts.
- **JSON:** Used for all application-specific update configurations and system settings.

## System Utilities
- **curl & wget:** Used for fetching remote data, performing HTTP requests, and downloading application assets.
- **gpg:** Utilized for signature verification and ensuring the integrity of downloaded packages.
- **jq:** The primary tool for parsing and manipulating JSON data within the shell environment.
- **grep, sed, awk:** Standard Unix utilities used for text processing and web parsing.

## Development & Quality Tools
- **shfmt:** Enforces a consistent code style and formatting across all shell scripts.
- **shellcheck:** Static analysis tool used to identify and fix common shell scripting errors and potential bugs.
- **GNU Make:** Orchestrates development tasks such as linting, formatting, and CI checks via the `Makefile`.
