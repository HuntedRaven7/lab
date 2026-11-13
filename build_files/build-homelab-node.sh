#!/bin/bash
set -ouex pipefail

NODE="${1:?usage: build-homelab-node.sh <node-id>}"

# Copy node-specific system files (hostname, node.env).
if [[ -d "/ctx/system_files" ]]; then
    cp -avf "/ctx/system_files"/. /
fi

mkdir -p /etc/kubernetes /var/lib/etcd /var/backups/etcd

# Open ports needed by Kubernetes, Cilium, and the join server.
# firewall-offline-cmd works in image builds without a running firewalld.
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --add-service=ssh || true          # remote administration
    firewall-offline-cmd --add-service=mdns || true         # .local / mDNS
    firewall-offline-cmd --add-port=6443/tcp || true   # kube-apiserver
    firewall-offline-cmd --add-port=2379/tcp || true   # etcd client (local/HA)
    firewall-offline-cmd --add-port=2380/tcp || true   # etcd peer (HA)
    firewall-offline-cmd --add-port=10250/tcp || true  # kubelet
    firewall-offline-cmd --add-port=10257/tcp || true  # controller-manager
    firewall-offline-cmd --add-port=10259/tcp || true  # scheduler
    firewall-offline-cmd --add-port=6447/tcp || true   # join command server
    firewall-offline-cmd --add-port=8472/udp || true   # VXLAN (Cilium default)
    firewall-offline-cmd --add-port=7946/tcp || true   # MetalLB memberlist
    firewall-offline-cmd --add-port=7946/udp || true   # MetalLB memberlist
    firewall-offline-cmd --add-port=51871/udp || true  # Cilium WireGuard (optional)
    firewall-offline-cmd --add-port=179/tcp || true    # MetalLB BGP (optional)
    firewall-offline-cmd --add-port=4240/tcp || true   # Cilium health
    firewall-offline-cmd --add-port=4244/tcp || true   # Hubble server
    firewall-offline-cmd --add-port=4245/tcp || true   # Hubble relay
    firewall-offline-cmd --add-masquerade || true
    firewall-offline-cmd --zone=trusted --add-interface=tailscale0 || true
fi

if [[ "$NODE" == "0" ]]; then
    # homelab-0: control plane. Initializes with kubeadm and serves join command.
    systemctl enable k8s-control-plane-init.service
    systemctl enable k8s-join-server.service
    systemctl enable k8s-etcd-backup.timer
    systemctl disable k8s-worker-join.service || true
else
    # homelab-1/2: worker nodes. Fetch join command from homelab-0 and join.
    systemctl enable k8s-worker-join.service
    systemctl disable k8s-control-plane-init.service || true
    systemctl disable k8s-join-server.service || true
    systemctl disable k8s-etcd-backup.timer || true
fi

# [IM]MUTABLE /opt
rm -rf /opt && mkdir /opt

