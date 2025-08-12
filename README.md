# Packwatch: App Update Checker

Packwatch is a powerful and extensible shell-based utility for checking for updates to your favorite applications. It is designed to be modular, allowing you to easily add new application checkers by creating simple JSON configuration files.

## Features

- **Modular Design:** Each application is defined in its own JSON configuration file, making it easy to add, remove, or modify checkers.
- **Multiple Check Methods:** Supports various methods for checking updates, including GitHub releases, APT repositories, and direct URL lookups.
- **Configurable:** Easily configure which applications to check.
- **Dry-Run Mode:** See what updates are available without performing any downloads or installations.
- **Verbose Output:** Enable verbose logging for debugging and detailed information.
- **Dependency Checking:** Ensures all required tools are available before running.

## Requirements

To run Packwatch, you need the following dependencies installed on your system:

- `wget`
- `curl`
- `gpg`
- `jq`
- `dpkg`
- `sha256sum`
- `lsb_release`
- `getent`
- `coreutils`
- `libnotify-bin` (for desktop notifications)

You can typically install these on a Debian-based system with:
```bash
sudo apt install -y wget curl gpg jq dpkg coreutils lsb-release getent libnotify-bin
```

For Flatpak support, ensure you have Flatpak installed. You can find instructions at [flatpak.org/setup/](https://flatpak.org/setup/).

## Installation

1.  Clone this repository to your local machine:
    ```bash
    git clone <repository-url>
    cd <repository-directory>
    ```
2.  (Optional) Create the default configuration files. This is a good way to get started.
    ```bash
    src/core/main.sh --create-config
    ```
    This will populate the `config/conf.d/` directory with example JSON files.

## Usage

The main entry point for the script is `src/core/main.sh`.

### Basic Commands

-   **Check for all enabled applications:**
    ```bash
    src/core/main.sh
    ```

-   **Check for specific applications:**
    Provide the application keys (the JSON filename without the extension) as arguments.
    ```bash
    src/core/main.sh ghostty tabby zed
    ```

-   **Show the help message:**
    ```bash
    src/core/main.sh --help
    ```

### Command-Line Options

-   `-h, --help`: Show the help message and exit.
-   `-v, --verbose`: Enable verbose output for debugging.
-   `-n, --dry-run`: Perform a dry run, checking for updates without downloading or installing anything.
-   `--cache-duration N`: Set the cache duration in seconds (default: 300).
-   `--create-config`: Create default modular configuration files and exit.
-   `--version`: Show the script version and exit.

## Configuration

Packwatch is configured through JSON files located in the `config/conf.d/` directory. Each file represents an application to be checked.

You can enable or disable an application by setting the `"enabled": true/false` flag within its JSON file.

To add a new application, create a new `.json` file in the `config/conf.d/` directory, following the structure of the existing files.

## For Developers

This project uses `shellcheck` for static analysis and `shfmt` for formatting.

### Development Tools

-   **`shellcheck`**: A static analysis tool for shell scripts.
-   **`shfmt`**: A shell script formatter.

### Makefile Commands

The `Makefile` provides convenient targets for development:

-   **Lint Shell Scripts:**
    ```bash
    make lint-shell
    ```

-   **Format Shell Scripts:**
    ```bash
    make format-shell
    ```

-   **Check Formatting (without modifying files):**
    ```bash
    make format-check
    ```

-   **Run all CI checks:**
    ```bash
    make ci
    ```
