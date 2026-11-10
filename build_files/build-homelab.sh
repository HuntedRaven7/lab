#!/bin/bash

set -ouex pipefail

# Copy shared homelab system files (k0s units, token services, configs).
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
	iproute \
	hostname \
	python3 \
	openssh-server \
	policycoreutils-python-utils \
	iscsi-initiator-utils \
	nfs-utils \
	cifs-utils \
	device-mapper \
	cryptsetup \
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
mkdir -p /etc/k0s /var/lib/k0s /etc/homelab /etc/homelab/secrets /var/lib/homelab \
    /var/lib/cni/bin /etc/cni/net.d /var/lib/homelab/local-path /var/lib/kubelet /var/backups/k0s

# tmpfiles rules for runtime dirs (bootc: /var stateful, root immutable).
# CNI binaries live under /var because /opt/cni/bin is read-only on bootc;
# the paths are set in /etc/k0s/containerd.d/10-cni-paths.toml.
install -d -m 0755 /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/homelab.conf <<'EOF'
d /etc/homelab 0755 root root -
d /etc/homelab/secrets 0700 root root -
d /var/lib/homelab 0755 root root -
d /var/lib/homelab/helm 0700 root root -
d /var/lib/homelab/local-path 0755 root root -
d /var/lib/cni 0755 root root -
d /var/lib/cni/bin 0755 root root -
d /etc/cni 0755 root root -
d /etc/cni/net.d 0755 root root -
d /var/lib/kubelet 0755 root root -
d /var/backups/k0s 0700 root root -
# Restore SELinux labels for hostPath dirs written by pods/CSI on an enforcing
# bootc host (Cilium CNI install, local-path helper pods). The default context
# for these paths is set with semanage fcontext below; Z restores it at boot.
Z /var/lib/cni/bin - - - -
Z /etc/cni/net.d - - - -
# Only the top-level local-path dir: relabelling entire PVC trees on every
# boot is slow. New files inherit container_file_t from the parent directory.
z /var/lib/homelab/local-path - - - -
EOF

# Label the hostPath dirs as container_file_t so pod writes are allowed under
# SELinux enforcing. The tmpfiles Z rules above re-apply these at boot.
if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t container_file_t '/var/lib/cni/bin(/.*)?' || true
    semanage fcontext -a -t container_file_t '/etc/cni/net.d(/.*)?' || true
    semanage fcontext -a -t container_file_t '/var/lib/homelab/local-path(/.*)?' || true
    restorecon -RF /var/lib/cni/bin /etc/cni/net.d /var/lib/homelab/local-path || true
fi

# Make homelab helper scripts executable.
chmod +x /usr/libexec/homelab-k0s-token \
         /usr/libexec/homelab-k0s-token-server \
         /usr/libexec/homelab-k0s-join \
         /usr/libexec/homelab-kubelet-mount-propagation \
         /usr/libexec/homelab-tailscale-auth \
         /usr/libexec/homelab-etcd-backup

# Base services: firewalld for node security; podman.socket kept for debugging.
systemctl enable firewalld.service
systemctl enable podman.socket
systemctl enable sshd.service

# CSI volume propagation + optional Tailscale first-boot auth.
systemctl enable homelab-kubelet-mount-propagation.service
systemctl enable homelab-tailscale-auth.service

# Kubernetes nodes do not want zram swap; the zram-generator config also
# disables it, mask the unit as a belt-and-braces measure.
systemctl mask systemd-zram-setup@zram0.service || true
   
# [IM]MUTABLE /opt
rm -rf /opt && mkdir /opt
