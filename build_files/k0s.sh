#!/usr/bin/env bash

# Install k0s, kubectl, helm and the OCM CLI (clusteradm) used to register
# Workload Execution Clusters with KubeStellar's ITS.
#
# k0s is delivered as a static binary + systemd units (mirroring the Bluefin
# Server k0s-sysext pattern). The role is chosen by the presence of
# /etc/k0s/token: absent -> controller, present -> worker.
#
# clusteradm is pinned to v0.10.1: newer OCM releases (v0.11+) renamed a
# ServiceAccount and break KubeStellar's OCM integration.

set -euo pipefail

K0S_VERSION="v1.34.5+k0s.0" # renovate: datasource=github-releases depName=k0sproject/k0s
CLUSTERADM_VERSION="0.10.1" # renovate: datasource=github-releases depName=open-cluster-management-io/clusteradm extractVersion=^v(?<version>.*)$

# Single static binary (not a tarball). The release asset is named
# k0s-<version>-<arch>; the "+" in the version is URL-encoded as %2B.
K0S_ARCH="$(uname -m)"
case "${K0S_ARCH}" in
    x86_64|amd64) K0S_ARCH="amd64" ;;
    aarch64|arm64) K0S_ARCH="arm64" ;;
esac
K0S_TAG="${K0S_VERSION//+/%2B}"
curl --proto '=https' --tlsv1.2 -sSfL \
    "https://github.com/k0sproject/k0s/releases/download/${K0S_TAG}/k0s-${K0S_VERSION}-${K0S_ARCH}" \
    -o /usr/local/bin/k0s
chmod +x /usr/local/bin/k0s

K8S_MINOR="${K0S_VERSION#v}"
K8S_MINOR="${K8S_MINOR%%+*}"
curl -fsSL "https://dl.k8s.io/release/v${K8S_MINOR}/bin/linux/${K0S_ARCH}/kubectl" -o /tmp/kubectl
install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION=v3.18.0 bash # renovate: datasource=github-releases depName=helm/helm

curl -fsSL "https://github.com/open-cluster-management-io/clusteradm/releases/download/v${CLUSTERADM_VERSION}/clusteradm_linux_${K0S_ARCH}.tar.gz" \
    -o /tmp/clusteradm.tar.gz
tar -xzf /tmp/clusteradm.tar.gz -C /usr/local/bin clusteradm
rm -f /tmp/clusteradm.tar.gz
