#!/bin/bash

set -ouex pipefail

# Copy shared homelab system files (k0s units, homelab-setup, configs).
cp -avf "/ctx/system_files"/. /

# Fedora stack: base tools. Podman is kept for ad-hoc debugging, but all
# workloads run on k0s/Kubernetes (KubeStellar). k0s uses containerd.
dnf5 install -y tmux \
	git \
	firewalld \
        zstd \
	fwupd-efi \
        podman \
	vim \
	curl \
	jq \
	wireguard-tools \
	NetworkManager-wifi \
	container-selinux \
        atheros-firmware \
        brcmfmac-firmware \
	realtek-firmware \
	iwlegacy-firmware \
        iwlwifi-dvm-firmware \
        iwlwifi-mvm-firmware

# Ensure runtime directories exist (bootc images may have /var as tmpfs in
# some layouts; systemd-tmpfiles will recreate on boot, but be explicit).
mkdir -p /etc/k0s /var/lib/k0s /etc/homelab /etc/homelab/secrets /var/lib/homelab

# tmpfiles rule to recreate /etc/homelab/secrets on boot (sensitive, 0700).
install -d -m 0755 /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/homelab.conf <<'EOF'
d /etc/homelab 0755 root root -
d /etc/homelab/secrets 0700 root root -
d /var/lib/homelab 0755 root root -
EOF

# Make homelab helper scripts executable.
chmod +x /usr/libexec/homelab-setup \
         /usr/libexec/homelab-k0s-token \
         /usr/libexec/homelab-k0s-token-server \
         /usr/libexec/homelab-k0s-join

# Base services: firewalld for node security; podman.socket kept for debugging.
systemctl enable firewalld.service
systemctl enable podman.socket
