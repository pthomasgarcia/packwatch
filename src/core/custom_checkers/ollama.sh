#!/usr/bin/env bash
# Custom checker for Ollama

check_ollama_updates() {
    local config_array_name="$1"
    local -n app_config_ref=$config_array_name
    
    local app_name="${app_config_ref[name]}"
    local app_key="${app_config_ref[app_key]}"
    
    # Get current installed version
    local current_version="0.0.0"
    if command -v ollama &>/dev/null; then
        current_version=$(ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [[ -z "$current_version" ]]; then
            current_version="0.0.0"
        fi
    fi
    
    # Get latest version from GitHub releases
    local latest_version="0.0.0"
    local api_response
    api_response=$(curl -s -m 30 "https://api.github.com/repos/ollama/ollama/releases/latest")
    if [[ $? -eq 0 && -n "$api_response" ]]; then
        latest_version=$(echo "$api_response" | jq -r ".tag_name" 2>/dev/null | sed 's/^v//')
        if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
            latest_version="0.0.0"
        fi
    fi
    
    # Normalize versions
    current_version=$(versions::normalize "$current_version")
    latest_version=$(versions::normalize "$latest_version")
    
    local result_json
    if updates::is_needed "$current_version" "$latest_version"; then
        result_json=$(jq -n \
            --arg status "success" \
            --arg latest_version "$latest_version" \
            --arg source "GitHub Releases" \
            --arg install_type "custom" \
            '{
                status: $status,
                latest_version: $latest_version,
                source: $source,
                install_type: $install_type
            }')
    else
        result_json=$(jq -n \
            --arg status "no_update" \
            --arg latest_version "$current_version" \
            --arg source "GitHub Releases" \
            '{
                status: $status,
                latest_version: $latest_version,
                source: $source,
                install_type: "none"
            }')
    fi
    
    echo "$result_json"
}

# Function to install/update Ollama
install_ollama() {
    local latest_version="$1"
    
    loggers::print_ui_line "  " "→ " "Installing Ollama v$latest_version..."
    
    # Download and run the official install script
    local temp_script
    temp_script=$(mktemp "/tmp/ollama-install.XXXXXX.sh")
    if [[ $? -ne 0 ]]; then
        errors::handle_error "INSTALLATION_ERROR" "Failed to create temporary file for Ollama installer"
        return 1
    fi
    
    if ! curl -fsSL "https://ollama.com/install.sh" -o "$temp_script"; then
        errors::handle_error "NETWORK_ERROR" "Failed to download Ollama installer script"
        rm -f "$temp_script"
        return 1
    fi
    
    # Make executable and run
    chmod +x "$temp_script"
    
    if sudo bash "$temp_script"; then
        rm -f "$temp_script"
        loggers::print_ui_line "  " "✓ " "Ollama v$latest_version installed successfully." _color_green
        return 0
    else
        rm -f "$temp_script"
        errors::handle_error "INSTALLATION_ERROR" "Ollama installation script failed"
        return 1
    fi
}

# Override the process function to handle Ollama's special installation
updates::process_ollama_update() {
    local app_name="$1"
    local latest_version="$2"
    
    local prompt_msg="Do you want to install $(_bold "$app_name") v$latest_version?"
    if [[ "$current_version" != "0.0.0" ]]; then
        prompt_msg="Do you want to update $(_bold "$app_name") to v$latest_version?"
    fi
    
    if "$UPDATES_PROMPT_CONFIRM_IMPL" "$prompt_msg" "Y"; then
        updates::on_install_start "$app_name"
        if [[ $DRY_RUN -eq 1 ]]; then
            loggers::print_ui_line "    " "[DRY RUN] " "Would install Ollama v$latest_version" _color_yellow
            updates::on_install_complete "$app_name"
            return 0
        fi
        
        if install_ollama "$latest_version"; then
            updates::on_install_complete "$app_name"
            counters::inc_updated
            return 0
        else
            updates::trigger_hooks ERROR_HOOKS "$app_name" "{\"phase\": \"install\", \"error_type\": \"INSTALLATION_ERROR\"}"
            return 1
        fi
    else
        updates::on_install_skipped "$app_name"
        counters::inc_skipped
        return 0
    fi
}
