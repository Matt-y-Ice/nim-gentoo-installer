#!/bin/bash

set -e

echo "[INFO] Starting first-boot user configuration..."

commands=(
    "flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
    "systemctl --user enable --now pipewire.socket pipewire-pulse.socket"
    "systemctl --user enable --now wireplumber.service"
    "git config --global user.email 'matty_ice_2011@pm.me'"
    "git config --global user.name 'mattyice'"
)

for cmd in "${commands[@]}"; do
    echo "[INFO] Executing: $cmd"
    if ! eval "$cmd"; then
        echo "[ERROR] Command failed: $cmd"
        exit 1
    fi
done

echo "[INFO] All commands executed successfully."
