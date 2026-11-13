#!/bin/bash

set -ouex pipefail

# Copy shared homelab system files (k8s units, configs, helpers).
cp -avf "/ctx/system_files"/. /

# Fedora stack: base tools. Podman is kept for ad-hoc debugging, but all
# workloads run on Kubernetes. containerd is the CRI runtime.
dnf5 install -y tmux \
	git \
	firewalld \
        zstd \
	fwupd-efi \
        podman \
	vim \
	curl \
	jq \
	iproute \
	hostname \
	python3 \
	openssh-server \
	policycoreutils-python-utils \
	iscsi-initiator-utils \
	nfs-utils \
	cifs-utils \
	wireguard-tools \
	NetworkManager-wifi \
	container-selinux \
        atheros-firmware \
        brcmfmac-firmware \
	realtek-firmware \
	iwlegacy-firmware \
        iwlwifi-dvm-firmware \
        iwlwifi-mvm-firmware

dnf5 install -y 'dnf5-command(config-manager)'

# Ensure runtime directories exist (bootc: /var is stateful; tmpfiles recreates).
mkdir -p /etc/kubernetes /etc/kubernetes/manifests /etc/containerd /etc/tailscale \
    /var/lib/etcd /var/lib/kubelet /var/lib/kubelet/volumeplugins /var/lib/containerd /var/lib/tailscale \
    /var/lib/homebrew /var/lib/homebrew-state \
    /var/lib/cni/bin /etc/cni/net.d /var/lib/homelab /var/lib/homelab/local-path \
    /var/lib/homelab/helm /var/backups/etcd

# Flexvolume plugin dir must be writable on bootc (root is immutable). Symlink the
# default path used by kube-controller-manager to state under /var.
mkdir -p /usr/libexec/kubernetes/kubelet-plugins/volume
rm -rf /usr/libexec/kubernetes/kubelet-plugins/volume/exec
ln -s /var/lib/kubelet/volumeplugins /usr/libexec/kubernetes/kubelet-plugins/volume/exec

# tmpfiles rules for runtime dirs (bootc: root immutable).
# CNI binaries live under /var because /opt/cni/bin is read-only on bootc.
install -d -m 0755 /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/kubernetes-node.conf <<'EOF'
d /etc/kubernetes 0755 root root -
d /etc/kubernetes/manifests 0755 root root -
d /etc/containerd 0755 root root -
d /etc/tailscale 0700 root root -
d /var/lib/tailscale 0700 root root -
d /var/lib/etcd 0700 root root -
d /var/lib/kubelet 0755 root root -
d /var/lib/kubelet/volumeplugins 0755 root root -
d /var/lib/containerd 0755 root root -
d /var/lib/homebrew 0755 root root -
d /var/lib/homebrew-state 0755 root root -
d /var/lib/homelab 0755 root root -
d /var/lib/homelab/helm 0700 root root -
d /var/lib/homelab/local-path 0755 root root -
d /var/lib/cni 0755 root root -
d /var/lib/cni/bin 0755 root root -
d /etc/cni 0755 root root -
d /etc/cni/net.d 0755 root root -
d /var/backups/etcd 0700 root root -
# Restore SELinux labels for hostPath dirs written by pods/CSI on enforcing hosts.
Z /var/lib/cni/bin - - - -
Z /etc/cni/net.d - - - -
z /var/lib/homelab/local-path - - - -
EOF

# Label hostPath dirs as container_file_t for SELinux enforcing.
if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t container_file_t '/var/lib/cni/bin(/.*)?' || true
    semanage fcontext -a -t container_file_t '/etc/cni/net.d(/.*)?' || true
    semanage fcontext -a -t container_file_t '/var/lib/homelab/local-path(/.*)?' || true
    restorecon -RF /var/lib/cni/bin /etc/cni/net.d /var/lib/homelab/local-path || true
fi

# Make helper scripts executable.
chmod +x /usr/libexec/k8s-control-plane-init \
         /usr/libexec/k8s-worker-join \
         /usr/libexec/k8s-join-server \
         /usr/libexec/k8s-etcd-backup \
         /usr/libexec/homelab-kubelet-mount-propagation \
         /usr/libexec/homelab-tailscale-auth
chmod +x /usr/local/bin/brew /usr/local/bin/tailscale 2>/dev/null || true
ln -sf /usr/local/bin/brew /usr/bin/brew

# Base services.
systemctl enable firewalld.service
systemctl disable podman.socket
systemctl enable sshd.service
systemctl enable containerd.service
systemctl enable kubelet.service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /run/systemd/generator/tailscaled.service /etc/systemd/system/multi-user.target.wants/tailscaled.service

# CSI volume propagation + optional Tailscale first-boot auth.
systemctl enable homelab-kubelet-mount-propagation.service
systemctl enable homelab-tailscale-auth.service

# Kubernetes nodes do not want zram swap.
systemctl mask systemd-zram-setup@zram0.service || true

# Remove unneeded VM guest, desktop/UX, and audio/misc packages (if present).
mapfile -t INSTALLED_REMOVE < <(rpm -qa --qf '%{NAME}\n' | grep -E '^(qemu-guest-agent|spice-vdagent|spice-webdavd|open-vm-tools|open-vm-tools-desktop|virtualbox-guest-additions|hyperv-daemons|hypervfcopyd|hypervkvpd|hypervvssd|WALinuxAgent|plymouth|plymouth-.*|PackageKit.*|cockpit.*|realmd|adcli|teamd|ModemManager|alsa-firmware|alsa-sof-firmware|alsa-utils|pipewire.*|pulseaudio.*|wireplumber.*)$' || true)
if ((${#INSTALLED_REMOVE[@]})); then
    dnf5 remove -y "${INSTALLED_REMOVE[@]}"
fi

# [IM]MUTABLE /opt
rm -rf /opt && mkdir /opt
