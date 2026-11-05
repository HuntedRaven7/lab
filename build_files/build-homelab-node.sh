#!/bin/bash
set -ouex pipefail

NODE="${1:?usage: build-homelab-node.sh <node-id>}"

# Copy node-specific system files (including Podman quadlets)
if [[ -d "/ctx/system_files" ]]; then
    cp -avf "/ctx/system_files"/. /
fi

# Ensure quadlet directory exists (node may be empty initially)
mkdir -p /etc/containers/systemd

# Reload systemd units (quadlets are generated at boot; keep image build-safe)
# systemctl daemon-reload is not run in image builds.
