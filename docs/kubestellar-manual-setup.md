# Manual KubeStellar setup (homelab-0)

KubeStellar (core chart + Console) is installed manually with Helm on the
`homelab-0` control plane. The image does **not** auto-bootstrap Cilium/MetalLB/
KubeStellar on boot. `k8s-control-plane-init.service` and `k8s-join-server.service`
handle control-plane initialization and serving the worker join command.

**No secrets in the repo or image.** Runtime material (cluster PKI/state, join
command, Tailscale auth key) lives on-node under `/etc/kubernetes`,
`/var/lib/etcd`, `/etc/tailscale`, etc.

## Prerequisites

- `homelab-0` booted from the homelab-0 image. `kubelet`, `containerd`, and the
  control-plane init services run on boot; first init may take a few minutes.
- Unique hostnames per node (`homelab-0/1/2` baked into images). mDNS
  (`homelab-0.local`) may work on LAN; prefer static/DHCP-reserved IPs for the
  control plane and set `CONTROL_PLANE` in `/etc/kubernetes/node.env` on workers.
- `API_ADVERTISE_ADDRESS` can be set in `/etc/kubernetes/node.env` on homelab-0
  before first init to force a specific API address (recommended on multi-homed
  nodes). Default is the source address of the default route.
- Binaries on-node: `kubeadm`, `kubelet`, `kubectl`, `helm`, `etcdctl`,
  `clusteradm`, `crictl`. Tailscale runs as a Podman Quadlet container
  (`tailscaled.service`) with a `tailscale` CLI wrapper.
- Containerd is configured for systemd cgroups and CNI paths on `/var`
  (`/var/lib/cni/bin`, `/etc/cni/net.d`) because `/opt` is immutable on bootc.
- Check control plane/API:
  ```bash
  sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
  sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz?verbose'
  sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system get pods -l k8s-app=kube-dns -o wide
  ```
  Nodes/pods will not be Ready until a CNI (Cilium) is installed. If CoreDNS is
  missing, install it with `sudo kubeadm init phase addon coredns --kubeconfig=/etc/kubernetes/admin.conf`.
  Ensure node clocks are in sync (NTP) before/after join.

Convenience:
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
export HELM_CONFIG_HOME=/var/lib/homelab/helm/config
export HELM_CACHE_HOME=/var/lib/homelab/helm/cache
export HELM_DATA_HOME=/var/lib/homelab/helm/data
sudo mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
```

## Install Cilium (CNI + kube-proxy replacement)

The cluster is initialized with `kubeadm init --skip-phases=addon/kube-proxy`.
Pin a Cilium version compatible with your kernel/Kubernetes.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
API_ADDR="${API_ADDR:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }}')}"

sudo -E helm repo add cilium https://helm.cilium.io/ || true
sudo -E helm repo update cilium
sudo -E helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${API_ADDR}" \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set cni.binPath=/var/lib/cni/bin \
  --set cni.confPath=/etc/cni/net.d \
  --set operator.replicas=1 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --wait --timeout 10m

sudo kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o wide
sudo kubectl get nodes -o wide
```

If `--wait` fails/times out or is interrupted, Cilium core may still be running;
check `helm -n kube-system status cilium` and pod status. Ensure CoreDNS is
healthy (Hubble relay needs cluster DNS), then reconcile with
`helm upgrade --install cilium cilium/cilium -n kube-system --reuse-values --wait --timeout 10m`.
On single-node clusters you can disable Hubble with
`--set hubble.relay.enabled=false --set hubble.ui.enabled=false` to unblock.
If pods fail with `failed to find plugin ... in path [/opt/cni/bin]`, verify
containerd uses `/var/lib/cni/bin` (`grep bin_dirs /etc/containerd/config.toml`),
fix/restart containerd+kubelet, and recreate stuck pods. Rebuilt images include
this containerd CNI path fix for containerd 2.x.

On multi-homed nodes (LAN + Tailscale), set `API_ADDR`/`k8sServiceHost` to the
reachable LAN API address and verify pod egress/DNS. If needed:
```bash
sudo -E helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
  --version "${CILIUM_VERSION}" --set bpf.masquerade=true \
  --set devices='{<lan-iface>}' --wait --timeout 10m
sudo kubectl run egress --rm -i --restart=Never --image=busybox:1.36 -- ping -c2 -W2 1.1.1.1
sudo kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -- nslookup charts.loft.sh 1.1.1.1
```

## Install MetalLB (LoadBalancer, optional)

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E helm repo add metallb https://metallb.github.io/metallb || true
sudo -E helm repo update metallb
sudo -E helm upgrade --install metallb metallb/metallb \
  -n metallb-system --create-namespace --wait --timeout 5m

# Apply IPAddressPool/L2Advertisement with a free LAN range outside DHCP.
```

## Install KubeStellar core (Helm)

Ensure a default StorageClass exists first (see `manifests/local-path-storage.yaml`).

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
KUBESTELLAR_VERSION="${KUBESTELLAR_VERSION:-0.30.1}"

sudo -E helm upgrade --install ks-core \
  oci://ghcr.io/kubestellar/kubestellar/core-chart \
  --version "${KUBESTELLAR_VERSION}" \
  --set-json='ITSes=[{"name":"its1"}]' \
  --set-json='WDSes=[{"name":"wds1"}]' \
  --set-json='verbosity.default=5' \
  --set-json='kubeflex-operator.verbosity=5' \
  --timeout 24h --wait
```

Monitor with `helm status/history ks-core -n default` and `kubectl get pods -A`.
If stuck pending-install, ensure StorageClass/PVC binding (KubeFlex Postgres)
and clean up/retry as needed.

## Install KubeStellar Console (Helm)

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
CONSOLE_VERSION="${CONSOLE_VERSION:-0.3.43}"

sudo -E helm repo add kubestellar-console https://kubestellar.github.io/console || true
sudo -E helm repo update kubestellar-console
sudo -E helm upgrade --install kc kubestellar-console/kubestellar-console \
  --namespace kubestellar-console --create-namespace \
  --version "${CONSOLE_VERSION}" \
  --wait --timeout 10m
```

Access: `sudo kubectl -n kubestellar-console port-forward svc/kc-kubestellar-console 8080:8080`

## Worker join (homelab-1/2)

- homelab-0: `k8s-control-plane-init.service` creates `/etc/kubernetes/join-command`;
  `k8s-join-server.service` serves it at `GET http://<control-plane>:6447/join`.
- homelab-1/2: set `CONTROL_PLANE` (prefer control-plane LAN IP) and optional
  `TOKEN_PORT`/`JOIN_TOKEN` in `/etc/kubernetes/node.env`, then
  `k8s-worker-join.service` fetches and runs `kubeadm join` (idempotent once
  joined, exits if `/etc/kubernetes/kubelet.conf` exists).
- Hardening knobs (opt-in, runtime files): set `JOIN_TOKEN` in
  `/etc/kubernetes/join-server.env` (control-plane) and provide the same value to
  workers via `/etc/kubernetes/join-server.token` or `JOIN_TOKEN` in
  `/etc/kubernetes/node.env`; optionally set `JOIN_BIND_ADDR` in
  `/etc/kubernetes/join-server.env` to bind a specific interface/IP.
- `6447/tcp` is opened by default only on node 0 image builds, but treat it as
  sensitive: restrict source to known workers (zone/rich rule) and keep join
  tokens/`/etc/kubernetes/join-command` protected (0600). `k8s-approve-node-csrs.timer`
  auto-approves kubelet client CSRs only for `system:node:homelab-0|1|2` (or
  `/etc/kubernetes/csr-allowed-nodes`).
- Pre-join checks from worker: `curl -sv --max-time 5 http://<CONTROL_PLANE>:6447/join`
  and reachability to `<CONTROL_PLANE>:6443`. If join fails with bootstrap/token
  or `cluster-info`/`kubeadm-config` errors, regenerate on homelab-0:
  `kubeadm init phase upload-config all --kubeconfig=/etc/kubernetes/admin.conf`,
  `kubeadm init phase bootstrap-token --kubeconfig=/etc/kubernetes/admin.conf`,
  then `kubeadm token create --print-join-command --kubeconfig=/etc/kubernetes/admin.conf | sudo tee /etc/kubernetes/join-command`.
- Control-plane ↔ worker connectivity: workers must reach the apiserver
  (`6443/tcp`) and the control plane must reach each worker kubelet
  (`10250/tcp`) for logs/exec/metrics and volume workflows. Image firewall
  config (`build_files/build-homelab-node.sh`, default/public zone) opens these
  ports consistently; verify with
  `curl -sk --max-time 3 https://<node-ip>:10250/healthz` from `homelab-0`
  (expected: `Unauthorized`/401, not timeout/refused/no route). If unreachable,
  confirm the active interface/zone and runtime firewall rules, then rebuild and
  `bootc upgrade`/reboot nodes to apply image changes.
- If a worker must rejoin, reset its Kubernetes state (`kubeadm reset -f`,
  remove `/etc/kubernetes/*` except intended node env/token, `/var/lib/kubelet`,
  CNI state as appropriate) and let the join service run again, or re-image.
  Keep node clocks in sync (NTP). After join, nodes become `Ready` once Cilium
  agents are running.

## Backups and reset

- Daily etcd snapshots: `k8s-etcd-backup.timer` on homelab-0 writes to
  `/var/backups/etcd` (keeps 7). Manual: `sudo systemctl start k8s-etcd-backup.service`.
- Full cluster reset/rebuild on homelab-0 is destructive (etcd, workloads, Helm
  releases, join state). Stop services, run `kubeadm reset -f`, remove
  `/etc/kubernetes`, `/var/lib/etcd`, `/var/lib/kubelet`, `/var/lib/cni`,
  `/etc/cni/net.d`, `/var/lib/homelab/helm`, Cilium BPF state as needed, then
  reboot or rerun init. Reinstall CNI/add-ons and have workers rejoin with a
  fresh join command.
