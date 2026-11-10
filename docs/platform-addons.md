# Platform add-ons and node operations

This repo keeps Cilium, MetalLB and KubeStellar manual on purpose. The image
provides the host prerequisites; cluster add-ons are installed with Helm or
GitOps after the node is healthy. The commands below are starting points —
pin versions in your own GitOps repo.

## Storage

`manifests/local-path-storage.yaml` is a bootc-patched local-path-provisioner:
the volume root is `/var/lib/homelab/local-path` (not `/opt`) and the
StorageClass is default.

```bash
sudo k0s kubectl apply -f manifests/local-path-storage.yaml
sudo k0s kubectl get sc,pods -n local-path-storage
```

local-path is node-local and not replicated. For durable/shared storage
(Longhorn, NFS, Rook/Ceph) the image already includes `iscsi-initiator-utils`,
`nfs-utils`, `cifs-utils`, `device-mapper` and `cryptsetup`, and kubelet runs
with `/var/lib/kubelet` rshared via
`homelab-kubelet-mount-propagation.service`. Longhorn still needs its own
`open-iscsi`/`iscsid` deployment checks; read its prereqs before installing.

## Metrics server

k0s bundles metrics-server by default (the image only disables `helm` and
`autopilot`). Verify:

```bash
sudo k0s kubectl -n kube-system get deploy,pods | grep metrics-server
sudo k0s kubectl top nodes
```

If you disabled it, either re-enable the k0s component or install upstream:

```bash
sudo k0s kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

k0s maps kubelet serving CSRs automatically, so the common
`--kubelet-insecure-tls` workaround should not be needed.

## Ingress / Gateway + TLS

The image references `argo.`, `mcp.` and `kubestellar.<domain>` HTTPRoutes but
does not install a gateway. One path:

```bash
# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true

# Envoy Gateway (pin a version you have tested)
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  -n envoy-gateway-system --create-namespace
```

Then create a `Gateway` with a MetalLB `LoadBalancer` service (or an existing
address from `HOMELAB_METALLB_ADDRESSES`) and HTTPRoutes for the apps. A
ClusterIssuer (ACME or a local CA) signs the listener certificate.

## GitOps

```bash
# Argo CD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace
```

or Flux (`flux bootstrap ...`). Point it at a repo containing Cilium/MetalLB/
KubeStellar values and the platform add-ons so the cluster stops depending on
manual `helm upgrade` commands. Runtime secrets stay in the cluster, not in the
image and not in Git.

## Secrets

- Keep `/etc/homelab/secrets/` for node-local material only (join token,
  Tailscale auth key).
- Use SOPS+age or Sealed Secrets for Git, or External Secrets Operator backed
  by a real secret store.
- Consider encrypting etcd at rest (`spec.api.extraArgs` /
  `--encryption-provider-config`) if the node disks are not encrypted.

## Observability

`kube-prometheus-stack` is the usual all-in-one:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

Keep an eye on etcd size, kubelet/containerd disk usage and node pressure — the
default disk is deliberately small.

## KubeFlex / KubeStellar prerequisites

KubeFlex-hosted control planes run a nested k3s inside pods. They need:

- a working default StorageClass **before** installing `ks-core`,
- the ability to run privileged pods and mount host paths,
- enough CPU/memory for the nested control plane + Postgres.

k0s does not enforce Pod Security Admission by default. If you enable it,
exempt the `kubeflex-system`/`its*`/`wds*` namespaces (or label them
`pod-security.kubernetes.io/enforce=privileged`). On SELinux-enforcing hosts,
nested containers may need the `unconfined`/`spc_t` label; verify this on
`fedora-bootc` before committing to the setup.

## Registry mirrors

Docker Hub rate limits will eventually bite (Bitnami Postgres, etc.). For k0s
1.34/containerd 1.x, use a drop-in:

`/etc/k0s/containerd.d/cri-registry.toml`
```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/k0s/containerd.d/certs.d"
```

`/etc/k0s/containerd.d/certs.d/docker.io/hosts.toml`
```toml
server = "https://registry-1.docker.io"

[host."https://mirror.gcr.io"]
  capabilities = ["pull", "resolve"]
```

k0s reloads containerd when drop-ins change. Convert to the
`io.containerd.cri.v1.images` v3 path if you move to k0s >= 1.36.

## Node access and first boot

- `sshd` is installed and enabled. Add keys at install time
  (`bootc install --root-ssh-authorized-keys=...`) or a provisioning step; do
  not bake private keys into the image.
- Optional Tailscale: put a reusable auth key at
  `/etc/homelab/secrets/tailscale-authkey` (mode 0600) and
  `homelab-tailscale-auth.service` runs `tailscale up` on boot. The key is not
  baked into the image.
- Hostnames `homelab-0/1/2` are baked per node image and systemd-resolved mDNS
  is enabled, so `homelab-0.local` works on a normal LAN. Prefer static
  IPs/DHCP reservations; AP/client isolation breaks mDNS, ARP-based MetalLB and
  VXLAN.

## Bootc updates on cluster nodes

`uupd` does not auto-reboot, but treat node updates as maintenance:

```bash
# on homelab-0 before a controller update
sudo systemctl start homelab-etcd-backup.service

# one node at a time
sudo k0s kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo bootc upgrade    # or image switch
sudo systemctl reboot
sudo k0s kubectl uncordon <node>
```

Never update all nodes at once, and back up the control plane before changing
the k0s version (k0s is baked into the image, so an OS update is also a k0s
upgrade).
