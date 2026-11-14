#!/bin/bash
set -ouex pipefail

NODE="${1:?usage: build-homelab-node.sh <node-id>}"

# Copy node-specific system files (hostname, node.env).
if [[ -d "/ctx/system_files" ]]; then
    cp -avf "/ctx/system_files"/. /
fi

mkdir -p /etc/kubernetes /var/lib/etcd /var/backups/etcd

# Open ports needed by Kubernetes, Cilium, and (control-plane only) join server.
# firewall-offline-cmd works in image builds without a running firewalld.
# Rules target --zone=public explicitly and set it as default so they apply
# consistently to LAN interfaces regardless of runtime default-zone drift.
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    FW_ZONE="public"
    fw() { firewall-offline-cmd --zone="${FW_ZONE}" "$@" || true; }

    firewall-offline-cmd --set-default-zone="${FW_ZONE}" || true
    fw --add-service=ssh    # remote administration
    fw --add-service=mdns   # .local / mDNS

    # Kubernetes API / kubelet (apiserver -> kubelet logs/exec/metrics on all nodes)
    fw --add-port=6443/tcp    # kube-apiserver
    fw --add-port=10250/tcp   # kubelet API

    # Cilium / CNI
    fw --add-port=8472/udp    # VXLAN (Cilium default overlay)
    fw --add-port=51871/udp   # Cilium WireGuard (optional)
    fw --add-port=4240/tcp    # Cilium health
    fw --add-port=4244/tcp    # Hubble server
    fw --add-port=4245/tcp    # Hubble relay

    # MetalLB / L2-BGP (optional but kept consistent)
    fw --add-port=7946/tcp    # MetalLB memberlist
    fw --add-port=7946/udp    # MetalLB memberlist
    fw --add-port=179/tcp     # MetalLB BGP

    # NodePort Services (broad compatibility for host-firewalled nodes)
    fw --add-port=30000-32767/tcp
    fw --add-port=30000-32767/udp

    if [[ "$NODE" == "0" ]]; then
        # Control-plane-only components and join endpoint
        fw --add-port=2379/tcp    # etcd client (local/HA)
        fw --add-port=2380/tcp    # etcd peer (HA)
        fw --add-port=10257/tcp   # controller-manager
        fw --add-port=10259/tcp   # scheduler
        fw --add-port=6447/tcp    # join command server (restrict source at runtime if needed)
    fi

    fw --add-masquerade
    # Tailscale interface remains fully trusted when present
    firewall-offline-cmd --zone=trusted --add-interface=tailscale0 || true
fi

if [[ "$NODE" == "0" ]]; then
    # homelab-0: control plane. Initializes with kubeadm and serves join command.
    systemctl enable k8s-control-plane-init.service
    systemctl enable k8s-join-server.service
    systemctl enable k8s-etcd-backup.timer
    systemctl enable k8s-approve-node-csrs.timer
    systemctl disable k8s-worker-join.service || true
else
    # homelab-1/2: worker nodes. Fetch join command from homelab-0 and join.
    systemctl enable k8s-worker-join.service
    systemctl disable k8s-control-plane-init.service || true
    systemctl disable k8s-join-server.service || true
    systemctl disable k8s-etcd-backup.timer || true
    systemctl disable k8s-approve-node-csrs.timer || true
fi

# [IM]MUTABLE /opt
rm -rf /opt && mkdir /opt

