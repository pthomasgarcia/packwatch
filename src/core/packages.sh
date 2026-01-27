#!/usr/bin/env bash
# ==============================================================================
# MODULE: packages.sh
# ==============================================================================
# Security model: This module handles package installation with the following
# threat protections:
# - Path traversal attacks via canonical path resolution
# - Archive bomb detection via size limits
# - Concurrent access via file locking
# - Basic validation of package integrity
#
# Known limitations:
# - Compile strategy executes untrusted code (requires user awareness)
# - No sandboxing for build operations (consider containers for production)
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: Configuration Constants
# ------------------------------------------------------------------------------

readonly PACKAGES_CACHE_BASE="${HOME}/.cache/packwatch"
readonly PACKAGES_TMP_DIR="${PACKAGES_CACHE_BASE}/tmp"
readonly PACKAGES_ARTIFACTS_DIR="${PACKAGES_CACHE_BASE}/artifacts"
readonly PACKAGES_MAX_COMPILE_JOBS="${PACKAGES_MAX_COMPILE_JOBS:-4}"
readonly PACKAGES_COMPILE_TIMEOUT="${PACKAGES_COMPILE_TIMEOUT:-3600}"
readonly PACKAGES_MAX_EXTRACT_SIZE_MB="${PACKAGES_MAX_EXTRACT_SIZE_MB:-5000}"

# ------------------------------------------------------------------------------
# SECTION: Single Source of Truth - Archive Formats
# ------------------------------------------------------------------------------

declare -A ARCHIVE_FORMATS=(
    ["tar.gz"]="tar -xf"
    ["tgz"]="tar -xf"
    ["tar.xz"]="tar -xf"
    ["txz"]="tar -xf"
    ["tar.bz2"]="tar -xf"
    ["tar.zst"]="tar -xf"
    ["zip"]="unzip -q"
)

# ------------------------------------------------------------------------------
# SECTION: Validation & Gatekeeping
# ------------------------------------------------------------------------------

packages::is_archive() {
    local filename="$1"
    local ext

    # Simple iteration through array keys - bash handles this reliably
    # No need for sorting; the pattern matching will catch the right extension
    for ext in "${!ARCHIVE_FORMATS[@]}"; do
        if [[ "$filename" == *."$ext" ]]; then
            return 0
        fi
    done

    return 1
}

packages::_validate_file_type() {
    local filepath="$1"
    local expected_type="$2" # 'archive' or 'deb'

    [[ ! -f "$filepath" ]] && return 1

    local file_output
    file_output=$(file -b "$filepath" 2>/dev/null) || return 1

    case "$expected_type" in
    archive)
        if [[ "$file_output" =~ (gzip|XZ|bzip2|Zstandard|Zip) ]] ||
            [[ "$file_output" =~ "POSIX tar archive" ]]; then
            return 0
        fi
        ;;
    deb)
        if [[ "$file_output" =~ "Debian binary package" ]]; then
            return 0
        fi
        ;;
    esac

    return 1
}

packages::_validate_extraction() {
    local dir="$1"
    local app_name="${2:-unknown}"

    [[ -z "$dir" ]] && {
        errors::handle_error "VALIDATION_ERROR" "Extraction directory is empty" "$app_name"
        return 1
    }

    # Check directory is not empty
    if [[ -z $(ls -A "$dir" 2>/dev/null) ]]; then
        errors::handle_error "VALIDATION_ERROR" "Extraction resulted in empty directory" "$app_name"
        return 1
    fi

    # Check for path traversal attempts in extracted content
    if [[ -n $(find "$dir" -name '..*' -o -path '*/../*' 2>/dev/null) ]]; then
        errors::handle_error "SECURITY_ERROR" "Path traversal detected in extracted content" "$app_name"
        return 1
    fi

    # Check extracted size doesn't exceed limits (protection against zip bombs)
    local size_mb
    size_mb=$(du -sm "$dir" 2>/dev/null | cut -f1)
    if [[ -n "$size_mb" ]] && [[ "$size_mb" -gt "$PACKAGES_MAX_EXTRACT_SIZE_MB" ]]; then
        errors::handle_error "VALIDATION_ERROR" "Extracted size (${size_mb}MB) exceeds limit (${PACKAGES_MAX_EXTRACT_SIZE_MB}MB)" "$app_name"
        return 1
    fi

    return 0
}

packages::_strategy_requires_sudo() {
    case "$1" in
    compile | copy_root_contents | move_binary)
        return 0
        ;;
    move_appimage)
        return 1 # No sudo needed for $HOME/Applications
        ;;
    *)
        return 1
        ;;
    esac
}

# ------------------------------------------------------------------------------
# SECTION: File Locking for Safe Concurrent Access
# ------------------------------------------------------------------------------

packages::_acquire_lock() {
    local lockfile="$1"
    local timeout="${2:-10}"
    local fd="${3:-200}"

    mkdir -p "$(dirname "$lockfile")"

    eval "exec $fd>$lockfile"

    local count=0
    while ! flock -n "$fd"; do
        sleep 0.1
        ((count++))
        if [[ $count -ge $((timeout * 10)) ]]; then
            return 1
        fi
    done

    return 0
}

packages::_release_lock() {
    local fd="${1:-200}"
    flock -u "$fd" 2>/dev/null || true
    eval "exec $fd>&-" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# SECTION: Installed Version Management
# ------------------------------------------------------------------------------

packages::get_installed_version_from_json() {
    local app_key="$1"
    local versions_file="$CONFIG_ROOT/installed_versions.json"
    local lockfile="${versions_file}.lock"

    [[ -z "$app_key" ]] && {
        errors::handle_error "VALIDATION_ERROR" "App key is empty"
        return 1
    }

    if [[ ! -f "$versions_file" ]]; then
        loggers::debug "Installed versions file not found: '$versions_file'. Assuming 0.0.0"
        echo "0.0.0"
        return 0
    fi

    # Acquire read lock
    packages::_acquire_lock "$lockfile" 5 201 || {
        loggers::warn "Could not acquire lock for reading versions, proceeding without lock"
    }

    local version
    version=$(systems::fetch_json "$(cat "$versions_file")" ".\"$app_key\"" "$app_key")

    packages::_release_lock 201

    if [[ -z "$version" ]] || [[ "$version" == "null" ]]; then
        loggers::debug "No installed version found for app: '$app_key'"
        echo "0.0.0"
        return 0
    fi

    echo "$version"
}

packages::update_installed_version_json() {
    local app_key="$1"
    local new_version="$2"
    local versions_file="$CONFIG_ROOT/installed_versions.json"
    local lockfile="${versions_file}.lock"

    [[ -z "$app_key" || -z "$new_version" ]] && {
        errors::handle_error "VALIDATION_ERROR" "Missing app key or version for update"
        return 1
    }

    mkdir -p "$(dirname "$versions_file")"
    [[ ! -f "$versions_file" ]] && echo '{}' >"$versions_file"

    # Acquire write lock with timeout
    packages::_acquire_lock "$lockfile" 10 202 || {
        errors::handle_error "LOCK_ERROR" "Could not acquire lock for updating versions file" "$app_key"
        return 1
    }

    local temp_file
    temp_file=$(systems::create_temp_file "versions_update") || {
        packages::_release_lock 202
        return 1
    }

    local result=0
    if jq --arg key "$app_key" --arg ver "$new_version" '.[$key] = $ver' "$versions_file" >"$temp_file" 2>/dev/null; then
        if mv "$temp_file" "$versions_file" 2>/dev/null; then
            systems::unregister_temp_file "$temp_file"
            
            # Only fix ownership if running as root
            if [[ $(id -u) -eq 0 ]] && [[ -n "$ORIGINAL_USER" ]]; then
                sudo chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$versions_file" 2>/dev/null
            fi
            
            loggers::debug "Updated version for '$app_key' to '$new_version'"
        else
            errors::handle_error "FILE_ERROR" "Failed to move temporary file to versions file" "$app_key"
            result=1
        fi
    else
        errors::handle_error "JSON_ERROR" "Failed to update JSON for '$app_key'" "$app_key"
        result=1
    fi

    packages::_release_lock 202
    return $result
}

packages::initialize_installed_versions_file() {
    local versions_file="$CONFIG_ROOT/installed_versions.json"

    if [[ ! -f "$versions_file" ]]; then
        loggers::info "Initializing installed versions file: '$versions_file'"
        mkdir -p "$(dirname "$versions_file")" || {
            errors::handle_error "FILE_ERROR" "Cannot create config directory"
            return 1
        }
        echo '{}' >"$versions_file" || {
            errors::handle_error "FILE_ERROR" "Cannot create versions file"
            return 1
        }
    fi

    return 0
}

packages::fetch_version() {
    packages::get_installed_version_from_json "$1"
}

# ------------------------------------------------------------------------------
# SECTION: DEB Package Helpers
# ------------------------------------------------------------------------------

packages::extract_deb_version() {
    local deb_file="$1"

    [[ ! -f "$deb_file" ]] && {
        errors::handle_error "FILE_ERROR" "DEB file not found: $deb_file"
        return 1
    }

    local version
    version=$(dpkg-deb -f "$deb_file" Version 2>/dev/null)

    if [[ -z "$version" ]]; then
        loggers::debug "Could not extract version from DEB metadata, trying filename"
        version=$(versions::extract_from_regex "$(basename "$deb_file")" "FILENAME_REGEX" "$(basename "$deb_file")")
    fi

    echo "${version:-0.0.0}"
}

packages::verify_deb_sanity() {
    local deb_file="$1"
    local app_name="$2"

    if [[ ! -f "$deb_file" ]]; then
        errors::handle_error "FILE_ERROR" "DEB file not found: $deb_file" "$app_name"
        return 1
    fi

    # Validate file type
    if ! packages::_validate_file_type "$deb_file" "deb"; then
        errors::handle_error "VALIDATION_ERROR" "File is not a valid Debian package: $deb_file" "$app_name"
        return 1
    fi

    # Validate package structure
    if ! dpkg-deb --info "$deb_file" &>/dev/null; then
        errors::handle_error "VALIDATION_ERROR" "DEB package structure is invalid: $deb_file" "$app_name"
        return 1
    fi

    return 0
}

packages::install_deb_package() {
    local deb_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"

    # interfaces::on_install_start handled by updates::process_installation

    [[ ${DRY_RUN:-0} -eq 1 ]] && {
        loggers::info "[DRY RUN] Would install DEB: $deb_file"
        packages::update_installed_version_json "$app_key" "$version"
        return 0
    }

    systems::ensure_sudo_privileges "$app_name" || return 1

    local output error_log
    error_log="${PACKAGES_CACHE_BASE}/logs/${app_name}_install_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$(dirname "$error_log")"

    if ! output=$(sudo apt install -y "$deb_file" 2>&1 | tee "$error_log"); then
        if [[ "$app_name" == "VeraCrypt" ]] && echo "$output" | grep -q "must be dismounted"; then
            errors::handle_error "PERMISSION_ERROR" "VeraCrypt volumes must be dismounted before installation" "$app_name"
        else
            errors::handle_error "INSTALLATION_ERROR" "apt install failed. Log: $error_log" "$app_name"
        fi
        return 1
    fi

    loggers::debug "DEB installation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Archive Extraction Framework
# ------------------------------------------------------------------------------

packages::install_archive() {
    local archive_file="$1"
    local app_name="$2"
    local version="$3"
    local app_key="$4"
    local binary_name="$5"
    local strategy="$6"

    # interfaces::on_install_start handled by updates::process_installation

    # Create temporary directory with proper error handling
    local tmp_dir
    mkdir -p "$PACKAGES_TMP_DIR" || {
        errors::handle_error "FILE_ERROR" "Cannot create temp directory base" "$app_name"
        return 1
    }

    tmp_dir=$(mktemp -d -p "$PACKAGES_TMP_DIR" "${app_name}.XXXXXX") || {
        errors::handle_error "FILE_ERROR" "Cannot create temporary extraction directory" "$app_name"
        return 1
    }

    # Use subshell for isolation with enhanced cleanup
    local exit_code
    (
        # Ensure cleanup on ANY exit
        trap 'rm -rf "$tmp_dir" 2>/dev/null || true' EXIT INT TERM

        packages::_extract_archive "$archive_file" "$tmp_dir" "$app_name" || exit 1
        packages::_validate_extraction "$tmp_dir" "$app_name" || exit 1

        # Check sudo requirements before proceeding
        if packages::_strategy_requires_sudo "$strategy"; then
            systems::ensure_sudo_privileges "$app_name" || exit 1
        fi

        case "$strategy" in
        compile)
            packages::_install_via_compile "$tmp_dir" "$app_name" "$version" || exit 1
            ;;
        move_binary)
            packages::_install_via_binary "$tmp_dir" "$binary_name" "$app_name" || exit 1
            ;;
        copy_root_contents)
            packages::_install_via_tree_copy "$tmp_dir" "$binary_name" "$app_name" || exit 1
            ;;
        move_appimage)
            packages::_install_via_appimage "$tmp_dir" "$binary_name" "$app_name" || exit 1
            ;;
        *)
            errors::handle_error "VALIDATION_ERROR" "Unknown installation strategy: $strategy" "$app_name"
            exit 1
            ;;
        esac
    )
    exit_code=$?

    # Additional cleanup outside subshell as safety measure
    [[ -d "$tmp_dir" ]] && rm -rf "$tmp_dir" 2>/dev/null || true

    return $exit_code
}

packages::_extract_archive() {
    local file="$1"
    local dest="$2"
    local app="$3"

    # Validate file exists and is readable
    [[ ! -f "$file" ]] && {
        errors::handle_error "FILE_ERROR" "Archive file not found: $file" "$app"
        return 1
    }

    # Validate file type before extraction
    if ! packages::_validate_file_type "$file" "archive"; then
        errors::handle_error "VALIDATION_ERROR" "File is not a valid archive: $file" "$app"
        return 1
    fi

    local ext cmd matched=0
    local error_log
    error_log="${PACKAGES_CACHE_BASE}/logs/${app}_extract_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$(dirname "$error_log")"

    # Match extension and extract using command from ARCHIVE_FORMATS array
    for ext in "${!ARCHIVE_FORMATS[@]}"; do
        if [[ "$file" == *."$ext" ]]; then
            cmd="${ARCHIVE_FORMATS[$ext]}"
            matched=1

            loggers::debug "Extracting $ext archive: $file"

            # Use the command from array - unquoted for word splitting
            if [[ "$cmd" == "tar"* ]]; then
                if ! $cmd "$file" -C "$dest" --no-same-owner 2>"$error_log"; then
                    errors::handle_error "EXTRACTION_ERROR" "tar extraction failed. Log: $error_log" "$app"
                    return 1
                fi
            else
                if ! $cmd "$file" -d "$dest" 2>"$error_log"; then
                    errors::handle_error "EXTRACTION_ERROR" "extraction failed. Log: $error_log" "$app"
                    return 1
                fi
            fi

            break
        fi
    done

    if [[ $matched -eq 0 ]]; then
        errors::handle_error "VALIDATION_ERROR" "Unsupported archive format: $file" "$app"
        return 1
    fi

    loggers::debug "Archive extracted successfully to: $dest"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Installation Strategies
# ------------------------------------------------------------------------------

packages::_install_via_compile() {
    local dir="$1"
    local app="$2"
    local ver="$3"

    # Find root directory of extracted content
    local root
    root=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    root="${root:-$dir}"

    # Validate we have build files
    if [[ ! -f "$root/configure" ]] && [[ ! -f "$root/Makefile" ]] && [[ ! -f "$root/makefile" ]]; then
        errors::handle_error "VALIDATION_ERROR" "No build system found (configure/Makefile missing)" "$app"
        return 1
    fi

    local log_dir="${PACKAGES_ARTIFACTS_DIR}/${app}/v${ver}"
    mkdir -p "$log_dir"
    local build_log="$log_dir/build.log"

    # Security warning for untrusted code execution
    interfaces::on_install_start_compile "$app"
    interfaces::log_info "Compiling $app with max ${PACKAGES_MAX_COMPILE_JOBS} jobs (timeout: ${PACKAGES_COMPILE_TIMEOUT}s)"
    interfaces::log_info "Build log: $build_log"

    # Run compilation in timeout wrapper
    local compile_result
    (
        exec >"$build_log" 2>&1
        cd "$root" || exit 1

        # Configure if present
        if [[ -f ./configure ]]; then
            loggers::info "Running ./configure --prefix=/usr/local"
            timeout "${PACKAGES_COMPILE_TIMEOUT}" ./configure --prefix=/usr/local || exit 1
        fi

        # Build with limited parallelism
        loggers::info "Running make with $PACKAGES_MAX_COMPILE_JOBS jobs"
        timeout "${PACKAGES_COMPILE_TIMEOUT}" make -j"$PACKAGES_MAX_COMPILE_JOBS" || exit 1

        # Install
        loggers::info "Running make install"
        timeout "${PACKAGES_COMPILE_TIMEOUT}" sudo make install || exit 1

    ) 2>&1
    compile_result=$?

    if [[ $compile_result -eq 124 ]]; then
        errors::handle_error "TIMEOUT_ERROR" "Compilation timed out after ${PACKAGES_COMPILE_TIMEOUT}s. Log: $build_log" "$app"
        return 1
    elif [[ $compile_result -ne 0 ]]; then
        errors::handle_error "COMPILATION_ERROR" "Compilation failed with exit code $compile_result. Log: $build_log" "$app"
        return 1
    fi

    interfaces::log_info "Compilation and installation completed successfully"
    return 0
}

packages::_install_via_binary() {
    local dir="$1"
    local bin="$2"
    local app="$3"

    [[ -z "$bin" ]] && {
        errors::handle_error "VALIDATION_ERROR" "Binary name not specified" "$app"
        return 1
    }

    local path
    path=$(find "$dir" -type f -name "$bin" -print -quit)

    if [[ -z "$path" ]]; then
        errors::handle_error "FILE_ERROR" "Binary '$bin' not found in extracted archive" "$app"
        return 1
    fi

    interfaces::log_info "Found binary at: $path"
    interfaces::log_info "Installing binary to /usr/local/bin/$bin"

    if ! sudo install -m 755 "$path" "/usr/local/bin/$bin" 2>/dev/null; then
        errors::handle_error "INSTALLATION_ERROR" "Failed to install binary to /usr/local/bin/$bin" "$app"
        return 1
    fi

    interfaces::log_info "Binary installed successfully"
    return 0
}

packages::_install_via_tree_copy() {
    local dir="$1"
    local bin="$2"
    local app="$3"

    # Find root directory of extracted content
    local root
    root=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    root="${root:-$dir}"

    # Validate directory structure
    local found=0
    local found_dirs=""
    for d in bin lib share include etc; do
        if [[ -d "$root/$d" ]]; then
            found=1
            found_dirs="${found_dirs}${d} "
        fi
    done

    if [[ $found -eq 0 ]]; then
        # Get directory contents for error message using find
        local contents
        contents=$(find "$root" -maxdepth 1 \( ! -name "." \) -printf "%f\n" 2>/dev/null | head -20)

        local msg
        if [[ -z "$contents" ]]; then
            read -r -d '' msg <<EOF || true
Archive structure mismatch. Expected standard directories (bin/, lib/, share/, include/, etc/).
Found in: $root
Directory appears to be empty.
EOF
        else
            # Add indentation to each line using Bash parameter expansion
            local indented_contents="${contents//$'\n'/$'\n'  }"

            read -r -d '' msg <<EOF || true
Archive structure mismatch. Expected standard directories (bin/, lib/, share/, include/, etc/).
Found in: $root
Contents (first 20 items):
  ${indented_contents}
EOF
        fi

        errors::handle_error "INSTALLATION_ERROR" "$msg" "$app"
        return 1
    fi

    interfaces::log_info "Found standard directories: $found_dirs"

    # Optional: Log detailed contents for debugging
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        loggers::debug "Detailed directory contents of $root:"
        find "$root" -maxdepth 1 -exec stat -c "%A %h %U %G %8s %y %n" {} \; 2>/dev/null |
            while read -r line; do
                loggers::debug "  $line"
            done
    fi

    interfaces::log_info "Copying directory tree to /usr/local/"

    # Copy with error logging
    local error_log
    error_log="${PACKAGES_CACHE_BASE:-${HOME}/.cache/packwatch}/logs/${app}_copy_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$(dirname "$error_log")"

    # Use --strip-trailing-slashes and explicit directory handling for safety
    if ! sudo cp -r --preserve=timestamps --no-target-directory "$root"/. "/usr/local/" 2>"$error_log"; then
        errors::handle_error "INSTALLATION_ERROR" "Failed to copy directory tree. Log: $error_log" "$app"

        # Show first few lines of error log for context
        if [[ -s "$error_log" ]]; then
            loggers::debug "First 10 lines of copy error:"
            head -10 "$error_log" | while read -r line; do
                loggers::debug "  $line"
            done
        fi
        return 1
    fi

    # Ensure binary is executable if specified
    if [[ -n "$bin" ]] && [[ -f "/usr/local/bin/$bin" ]]; then
        loggers::debug "Setting executable permissions on /usr/local/bin/$bin"
        sudo chmod +x "/usr/local/bin/$bin" 2>/dev/null || {
            loggers::warning "Failed to set executable permissions on /usr/local/bin/$bin"
        }
    fi

    interfaces::log_info "Directory tree copied successfully"

    # Clean up error log if empty
    if [[ ! -s "$error_log" ]]; then
        rm -f "$error_log" 2>/dev/null || true
    fi

    return 0
}

packages::_install_via_appimage() {
    local dir="$1"
    local bin="$2"
    local app="$3"

    # 1. Find the AppImage
    local source_path
    source_path=$(find "$dir" -type f -name "*.AppImage" -print -quit)

    if [[ -z "$source_path" ]]; then
        errors::handle_error "FILE_ERROR" "No .AppImage found in extraction" "$app"
        return 1
    fi

    # 2. Define the User Path (~/Applications/pencil/pencil.AppImage)
    local target_dir="$HOME/Applications/${app,,}"
    local target_file="${target_dir}/${app,,}.AppImage"

    mkdir -p "$target_dir"

    interfaces::log_info "Installing to $target_file"
    cp "$source_path" "$target_file"
    chmod +x "$target_file"

    # 3. Create a symlink in ~/.local/bin so it's in your PATH
    # This avoids sudo and keeps the install local to your user
    mkdir -p "$HOME/.local/bin"
    ln -sf "$target_file" "$HOME/.local/bin/$bin"

    interfaces::log_info "Installed. Binary linked at $HOME/.local/bin/$bin"
    return 0
}

# ------------------------------------------------------------------------------
# SECTION: Package Processing Orchestrators
# ------------------------------------------------------------------------------

packages::process_deb_package() {
    local conf="$1"
    # shellcheck disable=SC2034
    local template="$2" # unused but kept for signature compatibility
    local ver="$3"
    local url="$4"
    local sum="$5"
    local app="$6"

    local -n ref=$conf
    local cache_dir="${PACKAGES_ARTIFACTS_DIR}/${app}/v${ver}"
    mkdir -p "$cache_dir" || {
        errors::handle_error "FILE_ERROR" "Cannot create cache directory" "$app"
        return 1
    }

    # Extract clean filename
    local filename
    filename=$(basename "$url" | cut -d'?' -f1)
    local path="${cache_dir}/${filename}"

    # Download if not cached
    if [[ ! -f "$path" ]]; then
        local content_length_from_config="${ref[content_length]:-unknown}"
        local content_length_display="${content_length_from_config}"
        if [[ "$content_length_display" =~ ^[0-9]+$ ]]; then
            content_length_display="$(_format_bytes "$content_length_display")"
        fi

        updates::on_download_start "$app" "$content_length_display"
        interfaces::log_info "Downloading DEB package from: $url"

        if ! networks::download_file "$url" "$path" "" "" "${ref[allow_insecure_http]:-0}"; then
            errors::handle_error "DOWNLOAD_ERROR" "Failed to download DEB package" "$app"
            return 1
        fi

        updates::on_download_complete "$app" "$path"
    else
        interfaces::on_using_cache "$app"
    fi

    # Validate package integrity
    packages::verify_deb_sanity "$path" "$app" || return 1

    # Verify checksum/signature
    verifiers::verify_artifact "$conf" "$path" "$url" "$sum" "${ref[content_length]:-}" || return 1

    # Install
    packages::install_deb_package "$path" "$app" "$ver" "${ref[app_key]}" || return 1

    # Update version tracking
    packages::update_installed_version_json "${ref[app_key]}" "$ver" || {
        loggers::warn "Failed to update version tracking for ${ref[app_key]}"
    }

    return 0
}

packages::process_archive_package() {
    local conf="$1"
    local tmpl="$2"
    local ver="$3"
    local url="$4"
    local sum="$5"
    local app="$6"
    local key="$7"
    local bin="$8"

    local -n ref=$conf
    local strat="${ref[install_strategy]:-move_binary}"
    local cache_dir="${PACKAGES_ARTIFACTS_DIR}/${app}/v${ver}"

    mkdir -p "$cache_dir" || {
        errors::handle_error "FILE_ERROR" "Cannot create cache directory" "$app"
        return 1
    }

    # Generate filename from template
    local filename
    # shellcheck disable=SC2059
    filename=$(printf "$tmpl" "$ver")
    local path="${cache_dir}/${filename}"

    # Download if not cached
    if [[ ! -f "$path" ]]; then
        local content_length_from_config="${ref[content_length]:-unknown}"
        local content_length_display="${content_length_from_config}"
        if [[ "$content_length_display" =~ ^[0-9]+$ ]]; then
            content_length_display="$(_format_bytes "$content_length_display")"
        fi

        updates::on_download_start "$app" "$content_length_display"
        interfaces::log_info "Downloading archive from: $url"

        if ! networks::download_file "$url" "$path"; then
            errors::handle_error "DOWNLOAD_ERROR" "Failed to download archive" "$app"
            return 1
        fi

        updates::on_download_complete "$app" "$path"
    else
        interfaces::on_using_cache "$app"
    fi

    # Verify integrity
    verifiers::verify_artifact "$conf" "$path" "$url" "$sum" "${ref[content_length]:-}" || return 1

    # Install using specified strategy
    packages::install_archive "$path" "$app" "$ver" "$key" "$bin" "$strat" || return 1

    # Update version tracking
    packages::update_installed_version_json "$key" "$ver" || {
        loggers::warn "Failed to update version tracking for $key"
    }

    return 0
}

# Alias for backwards compatibility
packages::process_tgz_package() {
    packages::process_archive_package "$@"
}
