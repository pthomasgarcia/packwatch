# Packwatch: App Update Checker

![Packwatch Demo](assets/packwatch-demo.jpg)

Packwatch is a powerful and extensible shell-based utility for checking for updates to your favorite applications. It is designed to be modular, allowing you to easily add new application checkers by creating simple JSON configuration files.

## Features

- **Modular Design:** Each application is defined in its own JSON configuration file.
- **Multiple Check Methods:** Supports GitHub releases, APT repositories, and direct URL lookups.
- **Configurable:** Easily enable or disable application checks.
- **Dry-Run Mode:** Check for updates without performing downloads or installations.
- **Verbose Output:** Enable detailed logging for debugging.
- **Dependency Checking:** Ensures all required tools are available.

## Requirements

To run Packwatch, you need the following dependencies: `wget`, `curl`, `gpg`, `jq`, `dpkg`, `sha256sum`, `lsb_release`, `getent`, `coreutils`, and `libnotify-bin`.

On Debian-based systems, you can install them with:
```bash
sudo apt install -y wget curl gpg jq dpkg coreutils lsb-release getent libnotify-bin
```
For Flatpak support, see [flatpak.org/setup/](https://flatpak.org/setup/).

## Installation & Usage

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/pthomasgarcia/packwatch.git
    cd packwatch
    ```

2.  **Run the script:**
    - Check all enabled apps: `src/core/main.sh`
    - Check specific apps: `src/core/main.sh ghostty tabby`
    - Get help: `src/core/main.sh --help`

3.  **(Optional) Create default configs:**
    ```bash
    src/core/main.sh --create-config
    ```

## Configuration

Customize Packwatch by editing the JSON files in `config/conf.d/`. Enable or disable applications by setting `"enabled": true/false`.

## Contributing

This project uses `shellcheck` for linting and `shfmt` for formatting. Use the provided `Makefile` to run checks before committing.

- **Run all CI checks:** `make ci`
- **Lint scripts:** `make lint-shell`
- **Format scripts:** `make format-shell`
