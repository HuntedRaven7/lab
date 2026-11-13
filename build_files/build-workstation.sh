#!/bin/bash
set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# Fedora/Terra stack
PACKAGES=(
	git-credential-libsecret 
	flatpak-spawn 
	gum 
	alsa-firmware 
	just 
	autofs 
	kitty
	borgbackup 
	distrobox 
	fastfetch 
	git 
	firewalld 
	wireguard-tools 
	NetworkManager-wifi 
	foo2zjs 
	iwlegacy-firmware 
	iwlwifi-dvm-firmware 
	iwlwifi-mvm-firmware 
	just 
	xorg-x11-xauth 
	fzf 
	ffmpeg 
	ffmpegthumbnailer 
	alsa-firmware 
)

dnf5 -y install "${PACKAGES[@]}"

# Flatpak slop
FLATHUB_REPO_SHA256=3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a
install -d -m0755 /etc/flatpak/remotes.d
flathub_tmp="$(mktemp)"
curl --fail --retry 3 --silent --show-error \
	--output "${flathub_tmp}" \
	https://dl.flathub.org/repo/flathub.flatpakrepo
echo "${FLATHUB_REPO_SHA256}  ${flathub_tmp}" | sha256sum --check --strict
install -m0644 "${flathub_tmp}" /etc/flatpak/remotes.d/flathub.flatpakrepo
rm -f "${flathub_tmp}"

# Services
systemctl enable podman
systemctl enable gdm
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /run/systemd/generator/tailscaled.service /etc/systemd/system/multi-user.target.wants/tailscaled.service
