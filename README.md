# lab

Bootc image builds for homelab and workstation.

## Homelab images

The homelab build is split into a shared base and node-specific images:

- `homelab` — base image (OS + k0s + kubectl/helm/clusteradm + common homelab setup)
- `homelab-0` — control plane (k0s controller, Cilium CNI, KubeStellar core + Console)
- `homelab-1`, `homelab-2` — worker nodes (join the homelab-0 k0s cluster)

The design mirrors the [Bluefin Server homelab profile](https://github.com/projectbluefin/server/blob/main/docs/skills/homelab-profile.md):
k0s provides the Kubernetes runtime, Cilium replaces kube-proxy and provides the
CNI, and a first-boot `homelab-setup` service installs KubeStellar on the
control plane. **No secrets in the repo or image**: runtime material (GitHub
OAuth, join tokens, etc.) is generated at first boot and stored under
`/etc/homelab/secrets/` (mode 0600), never committed.

### KubeStellar (homelab-0)

On first boot, `homelab-setup.service` (idempotent, runs once) installs:

- **Cilium** (CNI + kube-proxy replacement)
- **MetalLB** (LoadBalancer; pool from `HOMELAB_METALLB_ADDRESSES`)
- **KubeStellar core** chart (KubeFlex + ITS `its1` + WDS `wds1` + Postgres)
- **KubeStellar Console** (demo/admin sign-in by default; GitHub OAuth optional)

Configuration lives in `/etc/homelab/homelab.conf` (copied from the image
template on first boot; later edits survive OS updates). See
`system_files/homelab/etc/homelab/homelab.conf.template`.

### Worker join (homelab-1/2)

homelab-0 runs `homelab-k0s-token.service`, which ensures a k0s worker join
token exists and serves it over HTTP on port 6447 (`GET /token`). homelab-1/2
run `homelab-k0s-join.service`, which fetches that token (using
`HOMELAB_CONTROL_PLANE` from `/etc/homelab/homelab.conf`), writes
`/etc/k0s/token`, and starts `k0sworker.service`. The token is never committed.

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
