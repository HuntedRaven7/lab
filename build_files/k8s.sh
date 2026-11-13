#!/usr/bin/env bash

# Install containerd, kubeadm, kubelet, kubectl, etcdctl, helm and the OCM CLI
# (clusteradm) for a standard Kubernetes (kubeadm) homelab cluster.
#
# clusteradm is pinned to v0.10.1: newer OCM releases (v0.11+) renamed a
# ServiceAccount and break KubeStellar's OCM integration.

set -euo pipefail

K8S_MINOR="1.34" # renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>\d+\.\d+)\.\d+$
ETCD_VERSION="v3.7.3" # renovate: datasource=github-releases depName=etcd-io/etcd
CLUSTERADM_VERSION="0.10.1" # renovate: datasource=github-releases depName=open-cluster-management-io/clusteradm extractVersion=^v(?<version>.*)$

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
esac

# Kubernetes upstream packages (kubeadm/kubelet/kubectl/cri-tools).
cat > /etc/yum.repos.d/kubernetes.repo <<REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
REPO

dnf5 install -y containerd kubelet kubeadm kubectl cri-tools
rm -f /etc/yum.repos.d/kubernetes.repo

# containerd config (systemd cgroups, CNI paths on /var for bootc).
mkdir -p /etc/containerd /var/lib/cni/bin /etc/cni/net.d
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's|bin_dir = "/opt/cni/bin"|bin_dir = "/var/lib/cni/bin"|' /etc/containerd/config.toml
sed -i 's|conf_dir = "/etc/cni/net.d"|conf_dir = "/etc/cni/net.d"|' /etc/containerd/config.toml

# etcdctl for local stacked-etcd snapshot backups on the control plane.
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/etcd.tar.gz
tar -xzf /tmp/etcd.tar.gz -C /tmp "etcd-${ETCD_VERSION}-linux-${ARCH}/etcdctl"
install -m 0755 "/tmp/etcd-${ETCD_VERSION}-linux-${ARCH}/etcdctl" /usr/local/bin/etcdctl
rm -rf /tmp/etcd.tar.gz "/tmp/etcd-${ETCD_VERSION}-linux-${ARCH}"

# Helm (standalone binary, used for Cilium/MetalLB/KubeStellar installs).
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION=v4.3.2 bash # renovate: datasource=github-releases depName=helm/helm

# OCM CLI for KubeStellar WEC registration.
curl -fsSL "https://github.com/open-cluster-management-io/clusteradm/releases/download/v${CLUSTERADM_VERSION}/clusteradm_linux_${ARCH}.tar.gz" \
    -o /tmp/clusteradm.tar.gz
tar -xzf /tmp/clusteradm.tar.gz -C /usr/local/bin clusteradm
rm -f /tmp/clusteradm.tar.gz
