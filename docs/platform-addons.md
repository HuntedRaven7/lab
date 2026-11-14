# Platform add-ons and node operations

The image provides host prerequisites (containerd, kubeadm/kubelet, CNI paths,
kernel/sysctl tuning). Cilium, MetalLB and KubeStellar are installed manually
with Helm or GitOps after the node is healthy. Pin versions in your own GitOps
repo.

## Storage

`manifests/local-path-storage.yaml` is a bootc-patched local-path-provisioner:
the volume root is `/var/lib/homelab/local-path` (not `/opt`) and the
StorageClass is default. The image also ships it at
`/usr/share/homelab/manifests/local-path-storage.yaml`; `k8s-control-plane-init.service`
best-effort applies bundled manifests after API readiness.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E kubectl apply -f manifests/local-path-storage.yaml
sudo -E kubectl get sc,pods -n local-path-storage
```


local-path is node-local and not replicated. For durable/shared storage
(Longhorn, NFS, Rook/Ceph) the image already includes `iscsi-initiator-utils`,
`nfs-utils`, `cifs-utils`, `device-mapper` and `cryptsetup`, and kubelet runs
with `/var/lib/kubelet` rshared via
`homelab-kubelet-mount-propagation.service`. Host path `/var/lib/homelab/local-path`
is created with tmpfiles/SELinux labeling by the image build; if provisioning
fails, verify the directory exists, is writable, and has the expected
`container_file_t` context on the target node.

## Metrics server

Install metrics-server after CNI is healthy:

```bash
sudo -E kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
sudo -E kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
sudo -E kubectl top nodes
```

## Ingress / Gateway + TLS

The cluster does not include an ingress/gateway by default. Typical path:

```bash
# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true

# Envoy Gateway (pin a tested version)
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  -n envoy-gateway-system --create-namespace
```

Then create a `Gateway` with a MetalLB `LoadBalancer` address and HTTPRoutes as
needed.

## GitOps

```bash
# Argo CD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace
```

Or use Flux. Keep runtime secrets in-cluster/secret store, not in Git or images.

## Secrets

- Node-local material (e.g. Tailscale auth key) lives on-node (e.g.
  `/etc/tailscale/authkey`, 0600) and is never committed/baked in.
- Use SOPS+age, Sealed Secrets, or External Secrets Operator for cluster secrets.

## Control-plane self-healing hardening (image)

- `kubelet.service` runs `/usr/libexec/k8s-kubelet-migrate` via `ExecStartPre`
  to strip deprecated flags (e.g. `--pod-infra-container-image`) from
  `/var/lib/kubelet/kubeadm-flags.env` and regenerate missing control-plane
  `/etc/kubernetes/kubelet.conf` when admin state exists.
- `k8s-control-plane-init.service` reconciles on each boot: patches controller-manager
  flexvolume hostPath, refreshes kubeconfig/join command, and best-effort applies
  bundled manifests from `/usr/share/homelab/manifests` after API readiness.
- `k8s-approve-node-csrs.timer` auto-approves pending kubelet client CSRs only for
  `system:node:homelab-0|1|2` (or nodes listed in `/etc/kubernetes/csr-allowed-nodes`);
  it does not approve generic bootstrap identities.
- `/etc/crictl.yaml` points `crictl` at containerd by default.
- Optional join-server auth: `JOIN_TOKEN`/`/etc/kubernetes/join-server.token` on
  control-plane and workers, and `JOIN_BIND_ADDR` in `/etc/kubernetes/join-server.env`.
  Workers remain firewall-scoped; restrict 6447/tcp to known worker sources.


## Node firewall / required ports

Host firewall rules are image-managed in `build_files/build-homelab-node.sh`
(`firewall-offline-cmd`, persistent in the image; applied with `bootc
upgrade`/reboot). Rules are set as firewalld default zone **public** and added
to `--zone=public` so cluster traffic is allowed consistently:

- **All nodes:** 6443/tcp (apiserver client), 10250/tcp (kubelet API, required
  for control-plane/apiserver → kubelet logs/exec/metrics and some volume ops),
  8472/udp (Cilium VXLAN), 51871/udp (Cilium WireGuard, optional), 4240/tcp
  (Cilium health), 4244/tcp (Hubble server), 4245/tcp (Hubble relay), 7946/tcp+udp
  (MetalLB memberlist), 179/tcp (MetalLB BGP, optional), 30000-32767/tcp+udp
  (NodePort), ssh/mdns, masquerade.
- **Control plane (homelab-0) only:** 2379-2380/tcp (etcd), 10257/tcp
  (controller-manager), 10259/tcp (scheduler), 6447/tcp (join server; restrict
  source in production-like environments).
- **Tailscale:** `tailscale0` is added to the `trusted` zone when present.

If kubelet/API traffic is unreachable, verify the node’s active LAN interface is
in a zone that includes these ports (or in `public`), and check for conflicting
runtime firewalld/nft/iptables rules. From the control plane, kubelet health
should respond with auth required (not timeout/refused/no route), e.g.
`curl -sk --max-time 3 https://<worker-ip>:10250/healthz` → `Unauthorized`/401.

## Registry mirrors

For Docker Hub rate limits, configure containerd registry mirrors in
`/etc/containerd/certs.d/` and ensure `config_path` is set in
`/etc/containerd/config.toml`, then restart containerd.

## Tailscale (optional VPN)

Tailscale runs as a Podman Quadlet container (`tailscaled.service`, image
`docker.io/tailscale/tailscale:stable`, host network, state in
`/var/lib/tailscale`). No auth keys are baked into images.

1. Create the auth key file on the node (never commit it):
   ```bash
   sudo mkdir -p /etc/tailscale
   echo -n "tskey-..." | sudo tee /etc/tailscale/authkey > /dev/null
   sudo chmod 600 /etc/tailscale/authkey
   ```
2. `tailscaled.service` (Quadlet) runs the container; `homelab-tailscale-auth.service`
   performs `tailscale up` on boot when the key exists and the node is not already
   authenticated. Manual: `sudo systemctl start homelab-tailscale-auth.service`.
   A `tailscale` wrapper at `/usr/local/bin/tailscale` execs into the container.

On multi-homed nodes (LAN + `tailscale0`), pin Kubernetes API/Cilium addresses
to the intended LAN IP and verify pod egress/DNS. See Cilium notes in the
manual setup doc.

## Updates and maintenance

### Image and node OS updates (bootc)

Rebuild images when repo files change (Containerfiles, `build_files/`, `system_files/`, manifests/scripts), then roll out one node at a time:

```bash
# from repo
just build homelab
just build homelab-0  # and homelab-1/homelab-2 as needed
# or consume published base: BASE_IMAGE=ghcr.io/huntedraven7/homelab:latest just build homelab-0
```

On each node (control plane first only for control-plane-only changes; otherwise drain/upgrade carefully):

```bash
# on homelab-0 before a control-plane update
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo systemctl start k8s-etcd-backup.service

sudo -E kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo bootc upgrade            # or bootc switch <image-ref> to change image
sudo systemctl reboot
# after reboot, verify services and cluster state
sudo -E kubectl uncordon <node>
sudo -E kubectl get nodes,pods -A -o wide
```

- Back up/verify `/var/backups/etcd` before Kubernetes-version or control-plane changes.
- `k8s-control-plane-init.service` reconciles on boot (flexvolume patch, missing `kubelet.conf` repair, join command, bundled manifests in `/usr/share/homelab/manifests`). `kubelet` runs `k8s-kubelet-migrate` at start to strip deprecated flags from `/var/lib/kubelet/kubeadm-flags.env`.
- Runtime state under `/etc/kubernetes`, `/var/lib/etcd`, `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/tailscale`, etc. persists across upgrades; image-managed files under `/usr` are replaced.
- Keep node clocks in sync (NTP) on all nodes.

### Kubernetes and add-on updates

- **Cilium:** pin/test a version, then `helm repo update cilium && helm upgrade cilium cilium/cilium -n kube-system --version <ver> --reuse-values --wait --timeout 10m`. Reconcile after interrupted installs with `helm -n kube-system status cilium`.
- **CoreDNS:** if missing or after bootstrap issues, `sudo kubeadm init phase addon coredns --kubeconfig=/etc/kubernetes/admin.conf`; for version-aligned upgrades follow your Kubernetes upgrade procedure.
- **local-path-provisioner:** bundled manifest is reapplied on control-plane reconcile; to force-update apply `manifests/local-path-storage.yaml` (or image-bundled copy) manually.
- **MetalLB, metrics-server, cert-manager, Gateway, GitOps, KubeStellar/Console:** update via their pinned Helm charts/manifests (`helm repo update`, `helm upgrade --install ... --version <ver>`), verify CRDs/compatibility before Kubernetes minor upgrades.
- **Kubernetes minor upgrades:** plan separately (kubeadm upgrade flow, drain/backup, control-plane then workers), then rebuild/redeploy images with matching `K8S_MINOR` in `build_files/k8s.sh` and re-test node join/recovery.

### Containerized tools and services

- **Brew:** `brew` runs via Podman wrapper (`ghcr.io/homebrew/brew:latest` by default). Update packages with `brew update && brew upgrade` (persistent prefix/state under `/var/lib/homebrew` and `/var/lib/homebrew-state`). Wrapper/env fixes require an image rebuild+redeploy.
- **Tailscale:** runs as Quadlet container `docker.io/tailscale/tailscale:stable`. To pick up a newer image: `sudo podman pull docker.io/tailscale/tailscale:stable && sudo systemctl restart tailscaled.service` (state persists in `/var/lib/tailscale`; re-auth only if needed). Wrapper/auth-helper fixes require image rebuild+redeploy.
