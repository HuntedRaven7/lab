# lab

Bootc image builds for homelab and workstation.

## Homelab images

The homelab build is split into a shared base and node-specific images:

- `homelab` — base image (OS + k0s + kubectl/helm/clusteradm + common homelab setup)
- `homelab-0` — control plane (k0s controller, Cilium CNI, KubeStellar core + Console)
- `homelab-1`, `homelab-2` — worker nodes (join the homelab-0 k0s cluster)

The design mirrors the [Bluefin Server homelab profile](https://github.com/projectbluefin/server/blob/main/docs/skills/homelab-profile.md):
k0s provides the Kubernetes runtime, Cilium replaces kube-proxy and provides the
CNI. **No secrets in the repo or image**: runtime material (join tokens, optional
OAuth, Tailscale auth keys, etc.) is generated at runtime and stored under
`/etc/homelab/secrets/` (mode 0600), never committed.

### Host prerequisites baked into the images

- Per-node hostname (`homelab-0/1/2`) plus systemd-resolved mDNS, so
  `homelab-0.local` resolves on a normal LAN. Static IPs/DHCP reservations are
  still recommended.
- Kubernetes sysctls (`/etc/sysctl.d/90-kubernetes.conf`) and kernel modules
  (`/etc/modules-load.d/kubernetes.conf`): forwarding, bridged traffic,
  inotify, conntrack, VXLAN.
- CNI paths for bootc via
  `/etc/k0s/containerd.d/10-cni-paths.toml` (`/var/lib/cni/bin`,
  `/etc/cni/net.d`) because `/opt` is immutable.
- kubelet root `/var/lib/kubelet`, made rshared by
  `homelab-kubelet-mount-propagation.service` for CSI drivers.
- kubelet reservations/eviction and container log rotation via
  `workerProfiles` in `/etc/k0s/k0s.yaml`.
- journald caps, zram swap disabled, `sshd` enabled, optional Tailscale
  first-boot auth, and daily etcd/PKI backups on homelab-0.
- firewalld opens k0s, Cilium (VXLAN **8472/udp**), Hubble and MetalLB
  memberlist ports.

### KubeStellar (homelab-0)

KubeStellar (core chart + Console) is installed **manually** via Helm (no
auto-download/bootstrap on boot). See
[`docs/kubestellar-manual-setup.md`](docs/kubestellar-manual-setup.md) for
prerequisites, Cilium/MetalLB/KubeStellar/Console Helm commands, token handling,
and a full reset procedure.

`homelab-k0s-token.service` on homelab-0 ensures a worker join token exists and
serves it for homelab-1/2 (`GET http://<control-plane>:6447/token`); Cilium,
MetalLB, and KubeStellar are not auto-installed.

### Worker join (homelab-1/2)

homelab-0 runs `homelab-k0s-token.service`, which ensures a k0s worker join
token exists and serves it over HTTP on port 6447 (`GET /token`). homelab-1/2
run `homelab-k0s-join.service`, which fetches that token (using
`HOMELAB_CONTROL_PLANE` from `/etc/homelab/homelab.conf`), writes
`/etc/k0s/token`, and starts `k0sworker.service`. The token is never committed.

The image hostnames are `homelab-0/1/2` and mDNS is enabled, so the default
`HOMELAB_CONTROL_PLANE=homelab-0.local` works on a normal LAN. Set it to a
static IP if your AP/VLAN blocks multicast. The token endpoint is
unauthenticated plain HTTP; restrict 6447/tcp to worker addresses on untrusted
networks.

### Storage and platform add-ons

`manifests/local-path-storage.yaml` is a bootc-patched default StorageClass
(storage under `/var/lib/homelab/local-path`). Apply it before KubeStellar:

```bash
sudo k0s kubectl apply -f manifests/local-path-storage.yaml
```

Metrics-server is provided by k0s. See
[`docs/platform-addons.md`](docs/platform-addons.md) for cert-manager, Envoy
Gateway, GitOps, secrets, observability, registry mirrors, KubeFlex
prerequisites and node maintenance.

### First boot

- `sshd` is enabled; provide authorized keys at install/provisioning time.
- Optional Tailscale: drop a reusable auth key at
  `/etc/homelab/secrets/tailscale-authkey` (0600) and the
  `homelab-tailscale-auth.service` unit runs `tailscale up` on boot.
- homelab-0 backs up k0s/etcd daily to `/var/backups/k0s` (keep 7). See the
  backup/restore section in the manual setup doc.

### Apps

The previous Podman quadlet apps (Beszel, Vaultwarden, FreshRSS, SearXNG,
Haptic, Karakeep, Glance) have been removed. Applications will be deployed
later via KubeStellar BindingPolicies.

### Building

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

## Workstation

```bash
just build workstation
```
