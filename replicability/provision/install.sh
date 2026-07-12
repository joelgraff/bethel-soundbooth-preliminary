#!/bin/bash
# soundbooth-project/replicability/provision/install.sh
#
# Basic installer for the soundbooth rig from a fresh Ubuntu desktop.
# Run as the target user after minimal OS install.
#
#   cd soundbooth-project/replicability/provision
#   ./install.sh
#
# This is the seed of the "soundbooth-setup" system.
# It will grow to support source/sink discovery and declarative config.

set -euo pipefail

echo "=== Soundbooth Rig Provisioner ==="
echo "Working from: $(pwd)"

# 1. Packages
if [[ -f apt-packages.txt ]]; then
    echo "Installing apt packages from list (this may take a while)..."
    sudo apt update
    # Filter out some obvious base packages if desired; for now install the list
    xargs -a apt-packages.txt sudo apt install -y || true
else
    echo "No apt-packages.txt found, skipping."
fi

if [[ -f snap-packages.txt ]]; then
    echo "Installing snaps..."
    while read -r snapname; do
        case "$snapname" in
            bare|core*|snapd|snapd-desktop-integration|gtk-common-themes|gnome-*-2404|mesa-2404|kf6-core24|lxqt-support-core24)
                echo "  (base/core) skipping $snapname"
                ;;
            *)
                echo "  snap install $snapname"
                sudo snap install "$snapname" || true
                ;;
        esac
    done < snap-packages.txt
fi

# 2. Create user dirs if missing (example)
mkdir -p "$HOME/bin" "$HOME/soundbooth-project"

# 3. (Optional) Remove unused ollama / open-webui test install
if snap list 2>/dev/null | grep -q open-webui || command -v ollama >/dev/null 2>&1; then
    echo "Detected possible ollama / open-webui test components."
    read -r -p "Remove them? (y/N) " ans
    if [[ "$ans" =~ ^[Yy] ]]; then
        sudo snap remove open-webui 2>/dev/null || true
        # ollama is often a manual install or docker; document manual removal
        echo "If ollama was installed via script, remove manually."
    fi
fi

# 4. Enable user services (assumes the .service files are already present or will be restored)
echo "Enabling soundbooth user services (if unit files exist)..."
systemctl --user enable --now qpwgraph.service vlc.service 2>/dev/null || true
# ardour.service will be enabled when its unit is in place

echo "=== Basic provision step complete ==="
echo "Next: restore configs from backup, run REBUILD steps, power on Presonus, test audio."
echo "See ../REBUILD.md"
