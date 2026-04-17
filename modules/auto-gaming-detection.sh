#!/usr/bin/env bash
#
# Auto-Detect Gaming Configuration
# Reads NixOS configuration and automatically configures gaming whitelist
#
# Usage: source this in compute-market module
#

set -euo pipefail

# ============================================================================
# AUTO-DETECT GAMES FROM NIXOS CONFIGURATION
# ============================================================================

detect_installed_games() {
    local config_file="/etc/nixos/hosts/$(hostname)/configuration.nix"

    if [ ! -f "$config_file" ]; then
        log_warn "No NixOS configuration found for $(hostname)"
        return
    fi

    log_info "🎮 Scanning NixOS configuration for installed games..."

    # Detect Steam games from library
    local steam_library="$HOME/.steam/steam/steamapps/common"
    if [ -d "$steam_library" ]; then
        log_info "Found Steam library: $steam_library"

        # List installed games
        while IFS= read -r game_dir; do
            local game_name=$(basename "$game_dir")
            log_debug "Found Steam game: $game_name"

            # Add to whitelist (common patterns)
            echo "$game_name"
        done < <(find "$steam_library" -maxdepth 1 -type d ! -name "common" ! -name "Steam*" 2>/dev/null)
    fi

    # Detect anime-game-launcher (seen in running processes)
    if pgrep -f "anime-game-launcher" >/dev/null 2>&1; then
        log_info "Found anime-game-launcher process"
        # Don't add to whitelist (it's a launcher, not a game)
    fi

    # Detect Lutris games
    local lutris_dir="$HOME/.local/share/lutris"
    if [ -d "$lutris_dir" ]; then
        log_info "Found Lutris installation"
        # Lutris games don't have standard executables, skip
    fi

    # Detect Heroic games
    local heroic_dir="$HOME/.config/heroic"
    if [ -d "$heroic_dir" ]; then
        log_info "Found Heroic Games Launcher"
        # Heroic games don't have standard executables, skip
    fi

    # Detect Wine prefixes
    local wine_dir="$HOME/.wine"
    if [ -d "$wine_dir" ]; then
        log_info "Found Wine prefix"
        # Wine games don't have standard executables, skip
    fi
}

# ============================================================================
# GENERATE GAMING WHITELIST
# ============================================================================

generate_gaming_whitelist() {
    log_info "🔍 Generating gaming whitelist from system analysis..."

    # Common game executable patterns (Windows games via Proton/Wine)
    local common_patterns=(
        # Steam game IDs (if we can detect them)
        "steam_app_[0-9]+\.exe"

        # Popular games (add your favorites here)
        "Cyberpunk2077\.exe"
        "eldenring\.exe"
        "Dota2\.exe"
        "csgo\.exe"
        "TeamFortress2\.exe"
    )

    # Detect running game processes (learn from actual usage)
    log_info "Scanning for recently run games..."

    # Check nvidia-smi for GPU-bound processes
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_processes=$(nvidia-smi pmon -c 1 -s um | awk 'NR>3 && $2 != "-" {print $2}' | sort -u)

        for proc in $gpu_processes; do
            # Check if process looks like a game (not a launcher/helper)
            if [[ ! "$proc" =~ (steam|wine|proton|lutris|heroic|helper|webhelper) ]]; then
                log_info "Detected GPU-bound process: $proc"
                echo "$proc"
            fi
        done
    fi
}

# ============================================================================
# MAIN: AUTO-CONFIGURE GAMING WHITELIST
# ============================================================================

auto_configure_gaming() {
    log_info "🎯 Auto-configuring gaming detection whitelist..."

    # Check if whitelist is already configured
    if [ -n "$GAMING_GAMES" ]; then
        log_info "Gaming whitelist already configured: $GAMING_GAMES"
        return
    fi

    # Generate whitelist from system analysis
    local detected_games=$(generate_gaming_whitelist)

    if [ -z "$detected_games" ]; then
        log_warn "No games detected - gaming detection will be disabled"
        log_info "To enable gaming detection, set GAMING_GAMES in your NixOS config:"
        log_info "  systemd.services.compute-market.environment.GAMING_GAMES = \"Game1.exe Game2.exe\";"
        return
    fi

    # Set environment variable
    export GAMING_GAMES="$detected_games"

    log_info "✅ Auto-configured gaming whitelist:"
    log_info "   $GAMING_GAMES"
    log_info ""
    log_info "To customize, edit your NixOS configuration:"
    log_info "  systemd.services.compute-market.environment.GAMING_GAMES = \"your-game.exe another-game.exe\";"
}

# Run auto-configuration if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_configure_gaming
fi
