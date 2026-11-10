# Manual KubeStellar setup (homelab-0)

KubeStellar (core chart + Console) is installed manually with Helm on homelab-0.
This repo does **not** auto-download/bootstrap Cilium/MetalLB/KubeStellar on
boot. `homelab-k0s-token.service` is still used to generate/serve a worker join
token for homelab-1/2.

**No secrets in the repo or image.** Keep non-secret config in
`/etc/homelab/homelab.conf` and generate runtime secrets/tokens under
`/etc/homelab/secrets/` (mode `0700`, never committed).

## Prerequisites

- `homelab-0` booted with k0s controller and kubelet CNI paths configured for
  bootc (see `system_files/homelab/etc/k0s/k0s.yaml`:
  `workerProfiles.default.values.cniBinDir=/var/lib/cni/bin`,
  `cniConfDir=/etc/cni/net.d`; containerd CRI must match if customized).
- Binaries available on the node: `/usr/local/bin/k0s`, `/usr/local/bin/kubectl`,
  `/usr/local/bin/helm` (installed by the image build, `build_files/k0s.sh`).
- k0s controller running and API reachable:
  ```bash
  sudo /usr/local/bin/k0s status
  sudo /usr/local/bin/k0s kubectl get --raw='/readyz?verbose'
  ```
- `network.provider: custom` and kube-proxy disabled in k0s config means **no CNI
  until you install one**; nodes/pods will not be Ready until Cilium is installed.
- On bootc `/root` may be read-only; point Helm at writable dirs:
  ```bash
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
CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
API_ADDR="${HOMELAB_API_ADDRESS:-$(hostname -I | awk '{print $1}')}"

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
KUBESTELLAR_VERSION="${KUBESTELLAR_VERSION:-0.30.1}"

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

**Ensure storage before retry (k0s ships no default StorageClass):**
```bash
sudo /usr/local/bin/k0s kubectl get sc
# if none/default missing, install local-path-provisioner (review before applying):
sudo /usr/local/bin/k0s kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.32/deploy/local-path-storage.yaml
sudo /usr/local/bin/k0s kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
sudo /usr/local/bin/k0s kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
sudo /usr/local/bin/k0s kubectl get sc
```

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
the init container pass but break KubeFlex/ControlPlanes. Check chart
values/secrets first, then install (example only — adjust auth/db/service/size
to match chart expectations):

```bash
# confirm expected names/auth from chart manifests/values/secrets before applying
sudo -E /usr/local/bin/helm show values oci://ghcr.io/kubestellar/kubestellar/core-chart --version "${KUBESTELLAR_VERSION:-0.30.1}" \
  | egrep -n 'postgres|database|auth|password|user|secret' | head -120

# example Bitnami chart; change password/params to match KubeFlex expectations
sudo -E /usr/local/bin/helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
sudo -E /usr/local/bin/helm repo update
sudo -E /usr/local/bin/helm upgrade --install postgres oci://registry-1.docker.io/bitnamicharts/postgresql \
  -n kubeflex-system --create-namespace \
  --set fullnameOverride=postgres-postgresql \
  --set auth.postgresPassword='CHANGE-ME' \
  --set primary.persistence.enabled=true \
  --set primary.persistence.size=8Gi \
  --wait --timeout 10m

sudo /usr/local/bin/k0s kubectl get pods,pvc,svc -n kubeflex-system -o wide
```

If you install Postgres manually into a broken `pending-install` state, prefer
to clean up and reinstall `ks-core` cleanly once storage/values are correct so
chart-managed resources and secrets stay consistent.

## Install KubeStellar Console (Helm)

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data
CONSOLE_VERSION="${CONSOLE_VERSION:-0.3.43}"

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
  API_ADDR="${HOMELAB_API_ADDRESS:-$(hostname -I | awk '{print $1}')}"
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
rm -rf /var/lib/homelab/helm
rm -rf /etc/homelab/secrets/*
mkdir -p /etc/homelab/secrets /var/lib/homelab /var/lib/homelab/helm/{config,cache,data} /var/lib/cni/bin /etc/cni/net.d
chmod 0700 /etc/homelab/secrets

# 4) reinstall controller with intended config/args
#    Ensure /etc/k0s/k0s.yaml matches this repo (network.provider: custom,
#    kubeProxy.disabled: true, workerProfiles cniBinDir=/var/lib/cni/bin).
/usr/local/bin/k0s install controller -c /etc/k0s/k0s.yaml \
  --enable-worker --no-taints --disable-components=helm,autopilot,kube-proxy --force
systemctl daemon-reload
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
- CNI plugins must be installed to a writable path (e.g. `/var/lib/cni/bin`) and
  kubelet/containerd CRI configured to match; `/opt/cni/bin` is read-only on
  bootc. Fix requires correct `/etc/k0s/k0s.yaml` (`workerProfiles`) and/or
  containerd CRI `bin_dir`, then restart k0s.
- Do not pass kubelet flags not supported by your k0s/kubelet version (e.g.
  `--cni-bin-dir` as a kubelet extra arg caused crashloops on v1.34.5+k0s.0
  here); prefer k0s-supported config.
- Keep `HOMELAB_API_ADDRESS`/Cilium `k8sServiceHost` consistent with an IP
  reachable by the node and workers when generating tokens/installing Cilium.
