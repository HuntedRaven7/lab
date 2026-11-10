#!/bin/bash
set -ouex pipefail

NODE="${1:?usage: build-homelab-node.sh <node-id>}"

# Copy node-specific system files (k0s config, homelab.conf, role units).
if [[ -d "/ctx/system_files" ]]; then
    cp -avf "/ctx/system_files"/. /
fi

mkdir -p /etc/k0s /var/lib/k0s /etc/homelab /etc/homelab/secrets /var/lib/homelab

# Open ports needed by k0s, Cilium, and the homelab token service.
# firewall-offline-cmd works in image builds without a running firewalld.
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --add-service=ssh || true          # remote administration
    firewall-offline-cmd --add-service=mdns || true         # .local / mDNS join
    firewall-offline-cmd --add-port=6443/tcp || true   # kube-apiserver
    firewall-offline-cmd --add-port=9443/tcp || true   # k0s API
    firewall-offline-cmd --add-port=10250/tcp || true  # kubelet
    firewall-offline-cmd --add-port=8132/tcp || true   # konnectivity agent
    firewall-offline-cmd --add-port=8133/tcp || true   # konnectivity admin
    firewall-offline-cmd --add-port=6447/tcp || true   # homelab join token
    firewall-offline-cmd --add-port=8472/udp || true   # VXLAN (Cilium default)
    firewall-offline-cmd --add-port=7946/tcp || true   # MetalLB memberlist
    firewall-offline-cmd --add-port=7946/udp || true   # MetalLB memberlist
    firewall-offline-cmd --add-port=51871/udp || true  # Cilium WireGuard (optional)
    firewall-offline-cmd --add-port=179/tcp || true    # MetalLB BGP (optional)
    firewall-offline-cmd --add-port=4240/tcp || true   # Cilium health
    firewall-offline-cmd --add-port=4244/tcp || true   # Hubble server
    firewall-offline-cmd --add-port=4245/tcp || true   # Hubble relay
    firewall-offline-cmd --add-masquerade || true
    # Trust the Tailscale interface if/when it appears.
    firewall-offline-cmd --zone=trusted --add-interface=tailscale0 || true
fi

# Both k0s units are shipped in the base image and gated by
# ConditionPathExists on /etc/k0s/token (controller when absent, worker when
# present). Enable the appropriate role per node.
if [[ "$NODE" == "0" ]]; then
    # homelab-0: control plane. Runs k0s controller (with --enable-worker in
    # K0S_CONTROLLER_ARGS). Serves the worker join token. Cilium/MetalLB/
    # KubeStellar are installed manually (see docs/kubestellar-manual-setup.md).
    systemctl enable k0scontroller.service
    systemctl disable k0sworker.service || true
    systemctl enable homelab-k0s-token.service
    systemctl disable homelab-k0s-join.service || true
    # Daily etcd/PKI backup (single control plane = single recovery path).
    systemctl enable homelab-etcd-backup.timer
else
    # homelab-1/2: worker nodes. They fetch the join token from homelab-0 and
    # start as k0s workers.
    systemctl disable k0scontroller.service || true
    systemctl enable k0sworker.service
    systemctl enable homelab-k0s-join.service
    systemctl disable homelab-k0s-token.service || true
    systemctl disable homelab-etcd-backup.timer || true
fi

# [IM]MUTABLE /opt
rm -rf /opt && mkdir /opt

