#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

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

# Service enablement 
systemctl enable podman.socket
