# Packwatch

![Packwatch banner](assets/banner.jpg)

## What it is
Packwatch is a modular shell utility that checks for updates to your applications.  
Add a new checker by dropping a single JSON file—no code changes required.

## Highlights
- **Pluggable checkers** – GitHub, APT, static URL, Flatpak, …  
- **Dry-run mode** – see what’s new before you pull the trigger  
- **Desktop notifications** – optional libnotify integration  
- **CI-friendly** – exit codes and JSON output for automation

## Quick start
```bash
git clone https://github.com/pthomasgarcia/packwatch.git
cd packwatch

# (optional) create starter config files
src/core/main.sh --create-config

# check everything you have enabled
src/core/main.sh

# or just a few apps
src/core/main.sh ghostty tabby zed
```

## Requirements
Packwatch requires the following tools to be available in your path:

- `wget`
- `curl`
- `gpg`
- `jq`
- `dpkg`
- `sha256sum`
- `lsb_release`
- `getent`
- `lsof`
- `ajv`

Optional:
- `notify-send` (for desktop notifications)

### Installation
**Debian/Ubuntu:**
```bash
sudo apt install wget curl gpg jq dpkg coreutils lsb-release libc-bin libnotify-bin lsof npm
sudo npm i @jirutka/ajv-cli
```

**Flatpak support:**
Install Flatpak from [flatpak.org/setup](https://flatpak.org/setup).

## CLI flags
| Flag | Purpose |
|------|---------|
| `-h, --help` | show help |
| `-v, --verbose` | debug logging |
| `-n, --dry-run` | check only, no downloads |
| `--cache-duration N` | cache results for N seconds (default 300) |
| `--create-config` | scaffold `config/conf.d/*.json` files |
| `--version` | show version |

## Adding your own app
1. Create `config/conf.d/myapp.json`
2. Set at least these keys:

```json
{
  "enabled": true,
  "method": "github-release",
  "repo": "owner/myapp",
  "current": "1.2.3"
}
```

3. Run `src/core/main.sh myapp` – done.

See existing files for APT, URL, and Flatpak examples.

## Hacking
```bash
# lint & format
make lint-shell format-shell

# run the same checks CI runs
make ci
```

Tools used: [shellcheck](https://www.shellcheck.net) + [shfmt](https://github.com/mvdan/sh).

---

MIT © 
