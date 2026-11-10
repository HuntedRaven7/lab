# Manual KubeStellar setup (homelab-0)

KubeStellar (core chart + Console) is installed manually with Helm on homelab-0.
This repo does **not** auto-download/bootstrap Cilium/MetalLB/KubeStellar on
boot. `homelab-k0s-token.service` is still used to generate/serve a worker join
token for homelab-1/2.

**No secrets in the repo or image.** Keep non-secret config in
`/etc/homelab/homelab.conf` and generate runtime secrets/tokens under
`/etc/homelab/secrets/` (mode `0700`, never committed).

## Prerequisites

- `homelab-0` booted with k0s controller and CNI paths configured for bootc.
  The path lives in the containerd drop-in
  `system_files/homelab/etc/k0s/containerd.d/10-cni-paths.toml`
  (`bin_dir=/var/lib/cni/bin`, `conf_dir=/etc/cni/net.d`) because `/opt` is
  immutable. Do **not** put `cniBinDir`/`cniConfDir` in `workerProfiles`:
  those are KubeletConfiguration fields and the CNI path is a containerd
  setting (k0s 1.34 uses containerd 1.x; convert the drop-in to the v3 CRI
  path if you move to containerd 2 / k0s >= 1.36).
- Each node must have a unique hostname. `homelab-0`, `homelab-1` and
  `homelab-2` are baked into their per-node images (`/etc/hostname`), which
  also makes `<hostname>.local` resolvable via systemd-resolved mDNS. Prefer
  static IPs or DHCP reservations for the control plane anyway.
- The image removes zram swap and ships sysctl/modules tuning in
  `/etc/sysctl.d/90-kubernetes.conf` and
  `/etc/modules-load.d/kubernetes.conf` (forwarding, inotify, conntrack,
  `br_netfilter`, `vxlan`, ...). Reboot after switching to a new image so
  those apply before k0s starts.
- Binaries available on the node: `/usr/local/bin/k0s`, `/usr/local/bin/kubectl`,
  `/usr/local/bin/helm` (installed by the image build, `build_files/k0s.sh`).
- k0s controller running and API reachable:
  ```bash
  sudo /usr/local/bin/k0s status
  sudo /usr/local/bin/k0s kubectl get --raw='/readyz?verbose'
  ```
- `network.provider: custom` and kube-proxy disabled in k0s config means **no CNI
  until you install one**; nodes/pods will not be Ready until Cilium is installed.
- On bootc `/root` may be read-only; point Helm at writable dirs and load the
  pinned chart versions from the node config:
  ```bash
  # HOMELAB_CILIUM_VERSION, HOMELAB_KUBESTELLAR_VERSION, HOMELAB_CONSOLE_VERSION
  set -a
  . /etc/homelab/homelab.conf
  set +a

  export KUBECONFIG=/var/lib/k0s/pki/admin.conf
  export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
  export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
  export HELM_DATA_HOME=/var/lib/homelab/helm/data
  sudo mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
  ```

## Install Cilium (CNI + kube-proxy replacement)

Use a Cilium version compatible with your kernel/k0s (tested: `1.20.4` on
`7.2.15-300.fc45.x86_64`, k0s `v1.34.5+k0s.0` in this repo's environment).

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data
CILIUM_VERSION="${HOMELAB_CILIUM_VERSION:-1.20.4}"
API_ADDR="${HOMELAB_API_ADDRESS:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }}')}"

sudo mkdir -p /var/lib/cni/bin /etc/cni/net.d
sudo -E /usr/local/bin/helm repo add cilium https://helm.cilium.io/ || true
sudo -E /usr/local/bin/helm repo update cilium
sudo -E /usr/local/bin/helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${API_ADDR}" \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set cni.binPath=/var/lib/cni/bin \
  --set cni.confPath=/etc/cni/net.d \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --wait --timeout 10m

sudo /usr/local/bin/k0s kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o wide
sudo /usr/local/bin/k0s kubectl get nodes -o wide
```

## Install MetalLB (LoadBalancer)

Optional but recommended for `LoadBalancer` Services. Use a **free LAN range/CIDR**
outside DHCP that does not include node IPs.

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
sudo -E /usr/local/bin/helm repo add metallb https://metallb.github.io/metallb || true
sudo -E /usr/local/bin/helm repo update metallb
sudo -E /usr/local/bin/helm upgrade --install metallb metallb/metallb \
  -n metallb-system --create-namespace --wait --timeout 5m

sudo /usr/local/bin/k0s kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: homelab-pool, namespace: metallb-system}
spec:
  addresses: ["192.168.0.100-192.168.0.150"] # REPLACE with a free range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: homelab-l2, namespace: metallb-system}
spec:
  ipAddressPools: [homelab-pool]
EOF
```

## Install KubeStellar core (Helm)

- Chart: `oci://ghcr.io/kubestellar/kubestellar/core-chart`
- Suggested version: `${KUBESTELLAR_VERSION:-0.30.1}`
- ITS: `its1`, WDS: `wds1` (KubeFlex-hosted control planes + Postgres)

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data
KUBESTELLAR_VERSION="${HOMELAB_KUBESTELLAR_VERSION:-0.30.1}"

sudo -E /usr/local/bin/helm upgrade --install ks-core \
  oci://ghcr.io/kubestellar/kubestellar/core-chart \
  --version "${KUBESTELLAR_VERSION}" \
  --set-json='ITSes=[{"name":"its1"}]' \
  --set-json='WDSes=[{"name":"wds1"}]' \
  --set-json='verbosity.default=5' \
  --set-json='kubeflex-operator.verbosity=5' \
  --timeout 24h --wait
```

This can take a long time while KubeFlex, Postgres, PostCreateHooks, and ITS/WDS
control planes become Ready.

**Monitor:**
```bash
sudo -E /usr/local/bin/helm status ks-core -n default
sudo -E /usr/local/bin/helm history ks-core -n default
sudo /usr/local/bin/k0s kubectl get pods -A
sudo /usr/local/bin/k0s kubectl get ns | egrep 'kubeflex|its1|wds1|wds|its' || true
sudo /usr/local/bin/k0s kubectl -n kubeflex-system get pods -o wide
```
If it appears stuck, check events and non-running pods:
```bash
sudo /usr/local/bin/k0s kubectl get pods -A | egrep -v 'Running|Completed' || true
sudo /usr/local/bin/k0s kubectl get events -A --sort-by=.lastTimestamp | tail -n 60
```

### Recovery: stuck `ks-core` install / missing Postgres (KubeFlex)

Symptoms: `helm status ks-core -n default` shows `pending-install` (or
`failed`), `helm upgrade --install` fails with `Error: UPGRADE FAILED: "ks-core"
has no deployed releases`, and/or `kubeflex-controller-manager` is stuck
`Init:0/1` in `wait-postgresql` waiting for pod `postgres-postgresql-0` in
`kubeflex-system` that never appears. (The init wait loop logs to the container,
not Kubernetes Events, so events may look idle.)

**Diagnose:**
```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data

sudo -E /usr/local/bin/helm list -n default -a
sudo -E /usr/local/bin/helm status ks-core -n default
sudo -E /usr/local/bin/helm history ks-core -n default
sudo /usr/local/bin/k0s kubectl get sc,pvc -A
sudo /usr/local/bin/k0s kubectl get all,pvc,job,cm,secret -n kubeflex-system -o wide
sudo /usr/local/bin/k0s kubectl logs -n kubeflex-system job/ks-core --all-containers --tail=300 2>&1 || true
sudo /usr/local/bin/k0s kubectl logs -n kubeflex-system deploy/kubeflex-controller-manager -c wait-postgresql --tail=50 2>&1 || true
# confirm whether a Postgres StatefulSet/Pod is rendered at all
sudo -E /usr/local/bin/helm get manifest ks-core -n default | egrep -n '^kind: (StatefulSet|PersistentVolumeClaim)|postgres-postgresql|helm.sh/hook'
```

**Cleanup a stuck/broken release** (stop any running `helm ... --wait` first):
```bash
sudo pkill -f "/usr/local/bin/helm upgrade --install ks-core" || true
sudo -E /usr/local/bin/helm uninstall ks-core -n default || true
sudo /usr/local/bin/k0s kubectl delete controlplanes.tenancy.kflex.kubestellar.org --all -A --ignore-not-found
sudo /usr/local/bin/k0s kubectl delete postcreatehooks.tenancy.kflex.kubestellar.org --all -A --ignore-not-found
sudo /usr/local/bin/k0s kubectl delete ns kubeflex-system --ignore-not-found --wait=true --timeout=180s
# if kubeflex-system is stuck Terminating, clear finalizers:
# sudo /usr/local/bin/k0s kubectl get ns kubeflex-system -o json | sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' | \
#   sudo /usr/local/bin/k0s kubectl replace --raw "/api/v1/namespaces/kubeflex-system/finalize" -f -
sudo -E /usr/local/bin/helm list -A -a
sudo /usr/local/bin/k0s kubectl get ns kubeflex-system controlplanes.tenancy.kflex.kubestellar.org -A 2>&1 || true
```

**Ensure storage before installing core (k0s ships no default StorageClass):**
KubeFlex/Postgres needs a bindable PVC. Use the vendored manifest, which is
already patched for bootc: storage lives under `/var/lib/homelab/local-path`
(the upstream default `/opt/local-path-provisioner` is on the immutable root)
and the StorageClass is marked as the cluster default.
```bash
sudo /usr/local/bin/k0s kubectl apply -f manifests/local-path-storage.yaml
sudo /usr/local/bin/k0s kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
sudo /usr/local/bin/k0s kubectl get sc,pods -n local-path-storage
```
The directory is created and labelled `container_file_t` by
`/usr/lib/tmpfiles.d/homelab.conf`; if you change the path, update that
tmpfiles rule too or the helper pod will be denied by SELinux.
If a Postgres PVC is already `Pending` with `storageClass: local-path` but there
is no working provisioner, the pod will stay `Pending` (`kubectl describe pvc -n
kubeflex-system <pvc>` / `kubectl describe pod -n kubeflex-system ...` will show
why). Install/fix the provisioner, then delete/recreate the pending PVC/pod (or
reinstall) so it can bind.

**Retry core install** after cleanup + storage (use chart-managed Postgres path):
```bash
sudo -E /usr/local/bin/helm upgrade --install ks-core \
  oci://ghcr.io/kubestellar/kubestellar/core-chart \
  --version "${KUBESTELLAR_VERSION:-0.30.1}" \
  --set-json='ITSes=[{"name":"its1"}]' \
  --set-json='WDSes=[{"name":"wds1"}]' \
  --set-json='verbosity.default=5' \
  --set-json='kubeflex-operator.verbosity=5' \
  --timeout 24h --wait
```

**If Postgres still never appears** (controller keeps waiting for
`postgres-postgresql-0` in `kubeflex-system`), the release did not create a
matching Postgres workload (e.g. not rendered/installed for this chart version,
or missing storage/prereqs). Inspect and prefer fixing chart values/flow for the
pinned version:
```bash
sudo -E /usr/local/bin/helm show values oci://ghcr.io/kubestellar/kubestellar/core-chart --version "${KUBESTELLAR_VERSION:-0.30.1}" \
  | egrep -n 'postgres|postgresql|installPostgreSQL|persistence|storage|database'
sudo -E /usr/local/bin/helm template ks-core oci://ghcr.io/kubestellar/kubestellar/core-chart --version "${KUBESTELLAR_VERSION:-0.30.1}" \
  --set-json='ITSes=[{"name":"its1"}]' --set-json='WDSes=[{"name":"wds1"}]' \
  | egrep -n '^kind: (StatefulSet|PersistentVolumeClaim|Job)|postgres-postgresql|helm.sh/hook'
```

**Manual PostgreSQL (last resort / unblock):** install a Postgres instance that
satisfies the KubeFlex wait (`pod postgres-postgresql-0` Ready in
`kubeflex-system`). Name, service, and credentials **must match what KubeFlex
expects** for this chart version; an ad-hoc DB with wrong auth/DB names can let
the init container pass but break KubeFlex/ControlPlanes. Prefer fixing chart
values/storage and reinstalling `ks-core` so chart-managed Postgres/secrets stay
consistent.

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config HELM_CACHE_HOME=/var/lib/homelab/helm/cache HELM_DATA_HOME=/var/lib/homelab/helm/data

# confirm expected names/auth/storage from the release/chart before applying
sudo -E /usr/local/bin/helm get manifest ks-core -n default 2>&1 | egrep -n 'postgres-postgresql|kind: (StatefulSet|Service|Secret|PersistentVolumeClaim)|POSTGRES|database|user|password'
sudo -E /usr/local/bin/helm get values ks-core -n default -a 2>&1 | egrep -n 'postgres|database|auth|persistence|storage'
sudo -E /usr/local/bin/helm show values oci://ghcr.io/kubestellar/kubestellar/core-chart --version "${KUBESTELLAR_VERSION:-0.30.1}" \
  | egrep -n 'postgres|database|auth|password|user|secret|persistence|storage' | head -160

# example only — adjust image/chart version, auth keys, DB/user names, secret refs,
# and service/fullname to match KubeFlex expectations for your ks-core version.
sudo -E /usr/local/bin/helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
sudo -E /usr/local/bin/helm repo update
sudo -E /usr/local/bin/helm upgrade --install postgres oci://registry-1.docker.io/bitnamicharts/postgresql \
  -n kubeflex-system --create-namespace \
  --set fullnameOverride=postgres-postgresql \
  --set auth.postgresPassword='CHANGE-ME' \
  --set primary.persistence.enabled=true \
  --set primary.persistence.size=8Gi \
  --wait --timeout 10m

# if it times out / pod Pending, check storage and events (common: PVC Pending, no provisioner)
sudo /usr/local/bin/k0s kubectl get pods,pvc,svc -n kubeflex-system -o wide
sudo /usr/local/bin/k0s kubectl describe pod -n kubeflex-system postgres-postgresql-0 2>&1 | tail -n 80
sudo /usr/local/bin/k0s kubectl describe pvc -n kubeflex-system 2>&1 | tail -n 120
sudo /usr/local/bin/k0s kubectl get sc,pods -n local-path-storage 2>&1 || true
```

If you install Postgres manually into a broken `pending-install` state, prefer
to clean up and reinstall `ks-core` cleanly once storage/values are correct so
chart-managed resources and secrets stay consistent. If the manual chart release
must be removed: `helm uninstall postgres -n kubeflex-system` and delete its PVCs
if you need a clean retry.

If you install Postgres manually into a broken `pending-install` state, prefer
to clean up and reinstall `ks-core` cleanly once storage/values are correct so
chart-managed resources and secrets stay consistent.

## Install KubeStellar Console (Helm)

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data
CONSOLE_VERSION="${HOMELAB_CONSOLE_VERSION:-0.3.43}"

sudo -E /usr/local/bin/helm repo add kubestellar-console https://kubestellar.github.io/console || true
sudo -E /usr/local/bin/helm repo update kubestellar-console
sudo -E /usr/local/bin/helm upgrade --install kc kubestellar-console/kubestellar-console \
  --namespace kubestellar-console --create-namespace \
  --version "${CONSOLE_VERSION}" \
  --wait --timeout 10m
```

Optional GitHub OAuth (values come from operator-supplied config, never commit
secrets): add `--set github.clientId=... --set github.clientSecret=...` and any
`auth.allowedGitHubLogins` / `auth.adminGitHubLogins` flags as needed.

**Access (port-forward):**
```bash
sudo /usr/local/bin/k0s kubectl -n kubestellar-console port-forward svc/kc-kubestellar-console 8080:8080
```

## Worker join token (homelab-1/2)

`homelab-k0s-token.service` (homelab-0) runs `/usr/libexec/homelab-k0s-token` to
create `/etc/homelab/secrets/k0s-worker-token` if missing, then serves it over
HTTP (`GET /token`, port 6447). `homelab-k0s-join.service` on workers fetches it
using `HOMELAB_CONTROL_PLANE` from `/etc/homelab/homelab.conf`.

- **Manual token generation (if needed):**
  ```bash
  sudo mkdir -p /etc/homelab/secrets && sudo chmod 0700 /etc/homelab/secrets
  API_ADDR="${HOMELAB_API_ADDRESS:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }}')}"
  RAW=$(/usr/local/bin/k0s token create --role=worker --expiry=8760h)
  printf '%s' "$RAW" | base64 -d 2>/dev/null \
    | sed "s|https://127.0.0.1:6443|https://${API_ADDR}:6443|g; s|https://localhost:6443|https://${API_ADDR}:6443|g" \
    | base64 -w0 | sudo tee /etc/homelab/secrets/k0s-worker-token >/dev/null
  sudo chmod 0600 /etc/homelab/secrets/k0s-worker-token
  sudo systemctl restart homelab-k0s-token.service
  ```
- **Verify:** `curl -fsS http://<control-plane>:6447/token | head -c 20`
- Tokens/secrets live in `/etc/homelab/secrets/` (never commit). After a hard
  reset workers must rejoin with a fresh token.

## Hard reset (start over without reinstalling the OS)

Use this to wipe k0s/cluster state and homelab runtime artifacts on **homelab-0**
and bootstrap again. **Destructive to cluster state** (etcd, workloads, Helm
releases, PVCs/data in k0s dirs, generated tokens). It keeps the OS image and
`/etc/homelab/homelab.conf` (non-secret). Re-image from a rebuilt image if you
need updated baked-in files (units, scripts, configs).

```bash
sudo -i
set -euo pipefail

# 1) stop services and k0s
systemctl stop homelab-k0s-token.service 2>/dev/null || true
systemctl stop k0sworker.service k0scontroller.service 2>/dev/null || true

# 2) reset k0s (best effort) and remove state
/usr/local/bin/k0s reset --debug 2>/dev/null || true
rm -rf /var/lib/k0s /run/k0s /var/lib/kubelet
rm -rf /var/lib/cni /etc/cni /var/run/cilium
rm -rf /sys/fs/bpf/cilium* /sys/fs/bpf/tc 2>/dev/null || true

# 3) remove homelab runtime artifacts (keeps /etc/homelab/homelab.conf)
rm -rf /var/lib/homelab/helm /var/lib/homelab/local-path
rm -rf /etc/homelab/secrets/*
mkdir -p /etc/homelab/secrets
chmod 0700 /etc/homelab/secrets

# Recreate runtime dirs and SELinux labels (container_file_t) in one step.
systemd-tmpfiles --create /usr/lib/tmpfiles.d/homelab.conf

# 4) reinstall controller with intended config/args
#    CNI paths live in /etc/k0s/containerd.d/10-cni-paths.toml. Do not use
#    cniBinDir/cniConfDir in workerProfiles (invalid KubeletConfiguration).
/usr/local/bin/k0s install controller -c /etc/k0s/k0s.yaml \
  --enable-worker --no-taints --kubelet-root-dir=/var/lib/kubelet \
  --disable-components=helm,autopilot,kube-proxy --force
systemctl daemon-reload
systemctl restart homelab-kubelet-mount-propagation.service
systemctl enable --now k0scontroller.service

# 5) wait for API (will not be fully Ready until CNI installed)
until /usr/local/bin/k0s kubectl get --raw='/readyz' >/dev/null 2>&1; do sleep 5; done
/usr/local/bin/k0s kubectl get --raw='/readyz?verbose'
/usr/local/bin/k0s kubectl get nodes -o wide
```

Then install Cilium, (optional) MetalLB, KubeStellar core, and Console via the
Helm commands above. `homelab-k0s-token.service` can be started/enabled to
(regen if missing and) serve the worker token for homelab-1/2.

Workers (`homelab-1/2`) must re-fetch a new join token after reset; if they were
joined, reset/rejoin them as needed.

## Troubleshooting quick checks

```bash
sudo /usr/local/bin/k0s status
sudo /usr/local/bin/k0s kubectl get nodes -o wide
sudo /usr/local/bin/k0s kubectl get pods -A -o wide
sudo /usr/local/bin/k0s kubectl describe node homelab-0
sudo /usr/local/bin/k0s kubectl get events -A --sort-by=.lastTimestamp | tail -n 60
sudo -E /usr/local/bin/helm list -A
sudo journalctl -u k0scontroller.service -u homelab-k0s-token.service -b --no-pager -n 200
```

**Common bootc/k0s/Cilium notes:**
- CNI paths live in the containerd drop-in
  `/etc/k0s/containerd.d/10-cni-paths.toml` (`bin_dir=/var/lib/cni/bin`,
  `conf_dir=/etc/cni/net.d`). `/opt/cni/bin` is read-only on bootc.
  `workerProfiles` accepts only KubeletConfiguration fields, so do not put
  `cniBinDir`/`cniConfDir` there; the CNI path is a containerd setting.
- kubelet root is `/var/lib/kubelet` on both controller and workers, so CSI
  drivers see the standard path. `homelab-kubelet-mount-propagation.service`
  bind-mounts it rshared before k0s starts.
- Keep `HOMELAB_API_ADDRESS`/Cilium `k8sServiceHost` on the LAN IP, not
  Tailscale. Set it explicitly on multi-homed nodes.
- firewalld must allow Cilium VXLAN **8472/udp** (not Flannel's 4789) and
  MetalLB memberlist 7946 tcp/udp. The image opens these ports offline.
- The join-token endpoint is plain HTTP and unauthenticated. Restrict
  6447/tcp to worker addresses if your LAN is not trusted.

## Backups and restore (single control plane)

homelab-0 runs `homelab-etcd-backup.timer` daily; archives go to
`/var/backups/k0s` (newest 7 kept). `k0s backup` includes etcd, the PKI,
`k0s.yaml`, manifests and Helm state — **not** PersistentVolumes.

```bash
sudo systemctl list-timers homelab-etcd-backup.timer
sudo systemctl start homelab-etcd-backup.service
sudo ls -lh /var/backups/k0s
```

Restore on a controller with a compatible k0s version:

```bash
sudo systemctl stop k0scontroller.service
sudo /usr/local/bin/k0s restore /var/backups/k0s/k0s_backup_<timestamp>.tar.gz
sudo systemctl start k0scontroller.service
```

If the replacement node has a different IP, adjust or remove
`spec.storage.etcd.peerAddress` in the restored config before starting.
`k0s restore` refuses to overwrite an existing data dir; reset or use a fresh
install. Copy `/var/lib/homelab/local-path` separately if you need PVC data.

## High availability

This repo is deliberately a single control plane (homelab-0) with workers,
which is a SPOF: losing homelab-0 loses the cluster until you restore a
backup. To make it HA, turn homelab-1/2 into controllers in a 3-node k0s
cluster, set `spec.api.externalAddress` to a VIP/LB, and open etcd
2379/2380 between controllers. Test the restore procedure before relying on it.

## Platform add-ons

Cilium, MetalLB and KubeStellar are intentionally manual. See
[`platform-addons.md`](platform-addons.md) for storage, metrics-server,
cert-manager, Envoy Gateway, GitOps, secrets, observability, registry mirrors
and KubeFlex prerequisites.
