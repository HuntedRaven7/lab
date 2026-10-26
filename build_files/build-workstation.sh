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

# Terra repos :3
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release

dnf5 -y install 'dnf5-command(copr)'
dnf5 -y install dnf-plugins-core

# Fedora/Terra stack
dnf5 install -y git-credential-libsecret \
	flatpak-spawn \
	ghostty \
	gum \
	mangowm \
	alsa-firmware \
	just \
	autofs \
	borgbackup \
	distrobox \
	fastfetch \
	git \
	firewalld \
	wireguard-tools \
	NetworkManager-wifi \
	foo2zjs \
	iwlegacy-firmware \
        iwlwifi-dvm-firmware \
        iwlwifi-mvm-firmware \
	just \
	wl-clipboard \
	xorg-x11-xauth \
	fzf \
	ffmpeg \
	ffmpegthumbnailer \
	alsa-firmware \

# This is only for quickshell I hate hyprland
dnf5 -y copr enable lionheartp/Hyprland

dnf5 -y install quickshell

dnf5 -y copr disable lionheartp/Hyprland

# Netbird's %post runs systemctl daemon-reload which cannot work in a container build
dnf5 -y install --setopt=tsflags=noscripts netbird
netbird service install || true
systemctl enable netbird.service

# Flatpak slop
#mkdir -p /usr/share/flatpak/preinstall.d/
#cp /ctx/custom/flatpaks/*.preinstall /usr/share/flatpak/preinstall.d/

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
