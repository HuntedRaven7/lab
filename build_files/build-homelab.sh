#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# Netbird install
# do netbird up to get it setup
tee /etc/yum.repos.d/netbird.repo <<EOF
[netbird]
name=netbird
baseurl=https://pkgs.netbird.io/yum/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.netbird.io/yum/repodata/repomd.xml.key
repo_gpgcheck=1
EOF

dnf5 -y install 'dnf5-command(copr)'
dnf5 -y install dnf-plugins-core

# Fedora stack
dnf5 install -y tmux \
	git \
	firewalld \
        zstd \
	fwupd-efi \
        podman \
	wireguard-tools \
	NetworkManager-wifi \
	container-selinux \
        atheros-firmware \
        brcmfmac-firmware \
	realtek-firmware \
	iwlegacy-firmware \
        iwlwifi-dvm-firmware \
        iwlwifi-mvm-firmware 

# Netbird's %post runs systemctl daemon-reload which cannot work in a container build
dnf5 -y install --setopt=tsflags=noscripts netbird
netbird service install || true
systemctl enable netbird.service

# Service enablement 
systemctl enable rpm-ostreed-automatic.timer
systemctl enable podman.socket
