# Platform add-ons and node operations

The image provides host prerequisites (containerd, kubeadm/kubelet, CNI paths,
kernel/sysctl tuning). Cilium, MetalLB and KubeStellar are installed manually
with Helm or GitOps after the node is healthy. Pin versions in your own GitOps
repo.

## Storage

`manifests/local-path-storage.yaml` is a bootc-patched local-path-provisioner:
the volume root is `/var/lib/homelab/local-path` (not `/opt`) and the
StorageClass is default.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E kubectl apply -f manifests/local-path-storage.yaml
sudo -E kubectl get sc,pods -n local-path-storage
```

local-path is node-local and not replicated. For durable/shared storage
(Longhorn, NFS, Rook/Ceph) the image already includes `iscsi-initiator-utils`,
`nfs-utils`, `cifs-utils`, `device-mapper` and `cryptsetup`, and kubelet runs
with `/var/lib/kubelet` rshared via
`homelab-kubelet-mount-propagation.service`.

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

## KubeFlex / KubeStellar prerequisites

KubeFlex-hosted control planes need a working default StorageClass before
installing `ks-core`, ability to run privileged pods/mount host paths, and
enough CPU/memory for nested control planes + Postgres. If you enable Pod
Security Admission, exempt `kubeflex-system`/`its*`/`wds*` namespaces as needed.

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

## Bootc updates on cluster nodes

Treat node updates as maintenance (one node at a time):

```bash
# on homelab-0 before a controller update
sudo systemctl start k8s-etcd-backup.service

sudo kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo bootc upgrade
sudo systemctl reboot
sudo kubectl uncordon <node>
```

Back up the control plane before upgrades that change Kubernetes versions.
