# lab

Bootc image builds for homelab and workstation.

## Homelab images

The homelab build is split into a shared base and node-specific images:

- `homelab` — base image (OS + containerd + kubeadm/kubelet/kubectl/helm/clusteradm + common homelab setup)
- `homelab-0` — control plane (kubeadm-initialized Kubernetes control plane, serves worker join command)
- `homelab-1`, `homelab-2` — worker nodes (join the homelab-0 cluster)

Kubernetes runtime is standard upstream Kubernetes (kubeadm) with containerd.
Cilium replaces kube-proxy and provides the CNI. Cilium, MetalLB, and
KubeStellar (core + Console) are installed manually (see
[`docs/kubestellar-manual-setup.md`](docs/kubestellar-manual-setup.md)).
**No secrets are baked into the image**; runtime material (cluster PKI/state,
join command, Tailscale auth key, etc.) lives on-node under `/etc/kubernetes`,
`/var/lib/etcd`, `/etc/tailscale`, etc.

### Host prerequisites baked into the images

- Per-node hostname (`homelab-0/1/2`) plus systemd-resolved mDNS, so
  `homelab-0.local` resolves on a normal LAN. Static IPs/DHCP reservations are
  recommended for the control plane.
- Kubernetes sysctls (`/etc/sysctl.d/90-kubernetes.conf`) and kernel modules
  (`/etc/modules-load.d/kubernetes.conf`): forwarding, bridged traffic,
  inotify, conntrack, VXLAN.
- containerd configured for systemd cgroups with CNI paths on `/var`
  (`/var/lib/cni/bin`, `/etc/cni/net.d`) because `/opt` is immutable on bootc.
- kubelet root `/var/lib/kubelet`, made rshared by
  `homelab-kubelet-mount-propagation.service` for CSI drivers.
- journald caps, zram swap disabled, `sshd`/`firewalld`/`containerd`/`kubelet`
  enabled, optional Tailscale first-boot auth, and daily etcd snapshot backups
  on homelab-0.
- firewalld opens Kubernetes, Cilium (VXLAN **8472/udp**), Hubble and MetalLB
  memberlist ports.

### Control plane and worker join

- `homelab-0` runs `k8s-control-plane-init.service` on first boot to execute
  `kubeadm init` (if `/etc/kubernetes/admin.conf` is absent), writes a worker
  join command to `/etc/kubernetes/join-command`, and serves it via
  `k8s-join-server.service` (`GET http://<control-plane>:6447/join`).
- `homelab-1/2` read `/etc/kubernetes/node.env` (`CONTROL_PLANE`, `TOKEN_PORT`,
  optional `JOIN_TOKEN`) and run `k8s-worker-join.service` to fetch and execute
  the join command (if `/etc/kubernetes/kubelet.conf` is absent). Default
  control plane is `homelab-0.local`; prefer a static IP for `CONTROL_PLANE`.
- `6447/tcp` is opened on node 0 image builds only. Optional hardening (runtime):
  set `JOIN_TOKEN` in `/etc/kubernetes/join-server.env` (and optionally
  `JOIN_BIND_ADDR`) on homelab-0 and provide the same token to workers via
  `/etc/kubernetes/join-server.token` or `JOIN_TOKEN` in `node.env`; restrict
  `6447/tcp` to known worker sources.
- `k8s-approve-node-csrs.timer` on homelab-0 auto-approves pending kubelet client
  CSRs for `system:node:homelab-0|1|2` (or names in
  `/etc/kubernetes/csr-allowed-nodes`). Keep node time in sync (NTP) on all nodes.

### Storage and platform add-ons

`manifests/local-path-storage.yaml` is a bootc-patched default StorageClass
(storage under `/var/lib/homelab/local-path`). Apply it before KubeStellar:

```bash
sudo kubectl apply -f manifests/local-path-storage.yaml
```

See [`docs/platform-addons.md`](docs/platform-addons.md) for metrics-server,
cert-manager, Envoy Gateway, GitOps, secrets, observability, registry mirrors,
KubeFlex prerequisites and node maintenance.

### First boot

- `sshd` is enabled; provide authorized keys at install/provisioning time.
- Optional Tailscale: drop a reusable auth key at `/etc/tailscale/authkey`
  (0600). `tailscaled.service` runs Tailscale as a Podman Quadlet container and
  `homelab-tailscale-auth.service` performs `tailscale up` on boot. Use the
  `tailscale` CLI wrapper on the host.
- homelab-0 backs up etcd snapshots daily to `/var/backups/etcd` (keep 7).

### Apps

Applications are deployed via KubeStellar BindingPolicies (not baked into images).

### Building and updating

```bash
# Build base
just build homelab

# Build node images (consumes local base by default)
just build homelab-0
just build homelab-1
just build homelab-2
```

To consume a published base image instead of the local `localhost/homelab:<tag>`:

```bash
BASE_IMAGE=ghcr.io/huntedraven7/homelab:latest just build homelab-0
```

After rebuilding, roll out with `bootc upgrade`/reboot per node (backup etcd and drain nodes; control-plane changes first). For Kubernetes add-ons, containerized brew/Tailscale, and maintenance details, see [`docs/platform-addons.md`](docs/platform-addons.md).

## Workstation

```bash
just build workstation
```

