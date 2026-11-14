#!/bin/bash
set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# YIPPEE SLOP
if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    FEDORA_VER="$(rpm -E %fedora)"
    RPMFUSION_RELEASE_PACKAGES=(
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm"
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm"
    )
    dnf5 -y install --skip-unavailable "${RPMFUSION_RELEASE_PACKAGES[@]}" || \
        echo "WARN: could not install RPM Fusion release repos (Steam may be unavailable)"
fi

# Fedora/Terra stack
PACKAGES=(
	git
	git-credential-libsecret
	flatpak-spawn
	gum
	just
	autofs
	fastfetch
	firewalld
	wireguard-tools
	NetworkManager-wifi
	foo2zjs
	iwlegacy-firmware
	iwlwifi-dvm-firmware
	iwlwifi-mvm-firmware
	xorg-x11-xauth
	fzf
	ffmpeg
	ffmpegthumbnailer
	alsa-firmware
)

# Major Desktop Stack
PACKAGES+=(
	gdm
	gnome-shell
	gnome-session-wayland-session
	gnome-settings-daemon
	gnome-control-center
	gnome-keyring
	ghostty
	nautilus
	xdg-user-dirs
	xdg-user-dirs-gtk
	xdg-desktop-portal
	xdg-desktop-portal-gnome
	xdg-desktop-portal-gtk
	polkit
	glib-networking
	gvfs-client
	gvfs-fuse
	gvfs-smb
	gvfs-archive
	gnome-disk-utility
	adwaita-icon-theme
	google-noto-sans-vf-fonts
	google-noto-serif-vf-fonts
	google-noto-sans-mono-vf-fonts
	google-noto-emoji-color-fonts
	pipewire
	wireplumber
	pipewire-alsa
	pipewire-pulseaudio
	pipewire-gstreamer
	mesa-dri-drivers
	mesa-libEGL
)

GAMESCOPE_TERRA_PACKAGES=(
	terra-gamescope.x86_64
	terra-gamescope-libs.x86_64
	terra-gamescope-libs.i686
)

GAMESCOPE_FEDORA_PACKAGES=(
	gamescope
	gamescope-libs.x86_64
	gamescope-libs.i686
)

REMOVE_PACKAGES=(
	pipewire-config-raop
	mesa-va-drivers
)

TERRA_SWAP_PACKAGES=(
	xorg-x11-server-Xwayland terra-xorg-x11-server-Xwayland
	wireplumber terra-wireplumber
)

TERRA_BLUEZ_PACKAGES=(
	terra-bluez
	terra-bluez-libs
	terra-bluez-obexd
	terra-bluez-cups
)

VERSIONLOCK_PACKAGES=(
	terra-xorg-x11-server-Xwayland
	terra-bluez
	mesa-dri-drivers
	mesa-filesystem
	mesa-libEGL
	mesa-libGL
	mesa-libgbm
	mesa-vulkan-drivers
)

EXTRA_PACKAGES=(
	mesa-libEGL.i686
	intel-opencl
	scx-scheds
	scx-tools
	bpftune
	bpfrag
)

OPENH264_PACKAGES=(
	openh264.x86_64
	openh264.i686
)

GAMING_PACKAGES=(
	gamemode.x86_64
	gamemode.i686
	mangohud.x86_64
	mangohud.i686
	vkBasalt.x86_64
	vkBasalt.i686
	libFAudio.x86_64
	libFAudio.i686
	wine
	winetricks
	umu-launcher
	protontricks
	vulkan-tools
	mesa-vulkan-drivers.x86_64
	mesa-vulkan-drivers.i686
	mesa-dri-drivers.i686
	openxr
	openxr-libs
	xrandr
	xorg-x11-server-Xwayland
)

LAUNCHER_PACKAGES=(
	steam
)

if ! dnf5 -y install --skip-unavailable "${GAMESCOPE_TERRA_PACKAGES[@]}" 2>/dev/null; then
    dnf5 -y install --skip-unavailable "${GAMESCOPE_FEDORA_PACKAGES[@]}" || true
fi

dnf5 -y remove "${REMOVE_PACKAGES[@]}"

dnf5 -y swap --from-repo=terra-mesa mesa-filesystem mesa-filesystem

dnf5 -y swap --allowerasing --repo terra-extras ${TERRA_SWAP_PACKAGES[0]} ${TERRA_SWAP_PACKAGES[1]}
dnf5 -y swap --allowerasing --repo terra-extras ${TERRA_SWAP_PACKAGES[2]} ${TERRA_SWAP_PACKAGES[3]}

dnf5 -y install \
    --allowerasing \
    --repo terra-extras \
    "${TERRA_BLUEZ_PACKAGES[@]}"

dnf5 versionlock add "${VERSIONLOCK_PACKAGES[@]}"

dnf5 -y install "${EXTRA_PACKAGES[@]}"

dnf5 -y install --allowerasing "${OPENH264_PACKAGES[@]}"

dnf5 -y install --skip-unavailable "${GAMING_PACKAGES[@]}"

dnf5 -y --setopt=install_weak_deps=False install --skip-unavailable "${LAUNCHER_PACKAGES[@]}" || \
    echo "WARN: steam/lutris not installed (package source unavailable in current repos)"

dnf5 -y install "${PACKAGES[@]}"

IMAGE_NAME=workstation /tmp/akmods-rpms/ublue-os/nvidia-install.sh

KERNEL_VERSION="$(rpm -q --queryformat='%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
export DRACUT_NO_XATTR=1
dracut --no-hostonly --kver "$KERNEL_VERSION" --reproducible --add ostree \
    -f "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"
chmod 0600 "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"

# Flatpak slop
install -d -m0755 /etc/flatpak/remotes.d

# Pinned SHA256 guards for remote .flatpakrepo contents (not Renovate-trackable).
# If CI/check-flatpak-remotes fails, refresh: curl -fsSL <url> | sha256sum
FLATHUB_REPO_SHA256=3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a # https://dl.flathub.org/repo/flathub.flatpakrepo
flathub_tmp="$(mktemp)"
curl --fail --retry 3 --silent --show-error \
	--output "${flathub_tmp}" \
	https://dl.flathub.org/repo/flathub.flatpakrepo
echo "${FLATHUB_REPO_SHA256}  ${flathub_tmp}" | sha256sum --check --strict
install -m0644 "${flathub_tmp}" /etc/flatpak/remotes.d/flathub.flatpakrepo
rm -f "${flathub_tmp}"

FLATPARK_REPO_SHA256=077584e3b75b5fe2ed77213c95f32df3437b4cf8a90686884c37d005072199f9 # https://dl.flatpark.org/flatpark.flatpakrepo
flatpark_tmp="$(mktemp)"
curl --fail --retry 3 --silent --show-error \
	--output "${flatpark_tmp}" \
	https://dl.flatpark.org/flatpark.flatpakrepo
echo "${FLATPARK_REPO_SHA256}  ${flatpark_tmp}" | sha256sum --check --strict
install -m0644 "${flatpark_tmp}" /etc/flatpak/remotes.d/flatpark.flatpakrepo
rm -f "${flatpark_tmp}"

# Services
systemctl set-default graphical.target
systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable firewalld.service
systemctl enable podman.service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /run/systemd/generator/tailscaled.service /etc/systemd/system/multi-user.target.wants/tailscaled.service

# Ensure brew/wrappers and gaming session helpers are executable and on PATH
chmod +x /usr/local/bin/brew /usr/local/bin/tailscale 2>/dev/null || true
chmod +x /usr/bin/gamescope-session /usr/bin/steamos-session-select 2>/dev/null || true
chmod +x /usr/bin/steamos-polkit-helpers/* 2>/dev/null || true
ln -sf /usr/local/bin/brew /usr/bin/brew
