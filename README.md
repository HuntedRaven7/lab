# lab

Bootc image builds for homelab and workstation.

## Homelab images

The homelab build is split into a shared base and node-specific images:

- `homelab` — base image (OS + k0s + common homelab setup)
- `homelab-0`, `homelab-1`, `homelab-2` — node images that `FROM` the base `homelab` image and layer in Podman quadlets

### Quadlets & services

Node-specific Podman Quadlets live under `system_files/homelab-<n>/etc/containers/systemd/` and are copied into each node image. Services run as per-service pods with a **Tailscale sidecar** container (own identity/state via `/etc/homelab/<service>-ts.env`).

- `homelab-0`: Beszel hub, Vaultwarden (+ Caddy in-pod for HTTPS, proxies to Vaultwarden), FreshRSS, SearXNG
- `homelab-1`: Beszel agent, Haptic, Karakeep (web + chrome + meilisearch)
- `homelab-2`: Beszel agent, Glance

Runtime config is provided via env/config files (quadlets use `EnvironmentFile=-/etc/homelab/*.env`). The repo ships **example-only** files (no real secrets) under `system_files/homelab-<n>/etc/homelab/examples/` (and example configs like `caddy/Caddyfile`, `glance/glance.yml`) — copy them to `/etc/homelab/` on the host and edit before use.

Container images in quadlets are pinned as `image:tag@sha256:...`; Renovate (`.github/renovate.json5`) manages quadlet image tags/digests.

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
