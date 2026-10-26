#!/usr/bin/env bash

set -euo pipefail

AKMODS_FLAVOR="${AKMODS_FLAVOR:-main}"
AKMODS_TAG="${AKMODS_FLAVOR}-$(rpm -E %fedora)-$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 install -y skopeo jq

AKMODS_IMAGE="ghcr.io/ublue-os/akmods-nvidia-open"
mkdir -p /tmp/akmods-policy/registries.d
cat >/tmp/akmods-policy/policy.json <<EOF
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "${AKMODS_IMAGE}": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/ctx/build/akmods-cosign.pub",
          "signedIdentity": {"type": "matchRepository"}
        }
      ]
    }
  }
}
EOF
cat >/tmp/akmods-policy/registries.d/ghcr.yaml <<'EOF'
docker:
  ghcr.io:
    use-sigstore-attachments: true
EOF
skopeo --policy /tmp/akmods-policy/policy.json \
	--registries.d /tmp/akmods-policy/registries.d \
	copy --retry-times 3 \
	"docker://${AKMODS_IMAGE}:${AKMODS_TAG}" dir:/tmp/akmods-rpms

tarball="$(jq -r '.layers[0].digest' /tmp/akmods-rpms/manifest.json | cut -d: -f2)"
tar -xzf "/tmp/akmods-rpms/${tarball}" -C /tmp
mv /tmp/rpms/* /tmp/akmods-rpms/

dnf5 config-manager setopt excludepkgs=golang-github-nvidia-container-toolkit

rpm --import "https://download.copr.fedorainfracloud.org/results/ublue-os/staging/pubkey.gpg"
IMAGE_NAME="${BASE_IMAGE_NAME:-workstation}" \
	AKMODNV_PATH=/tmp/akmods-rpms \
	MULTILIB=0 \
	/tmp/akmods-rpms/ublue-os/nvidia-install.sh

rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json
ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so

cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1", "initcall_blacklist=simpledrm_platform_driver_init"]
EOF

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
	-o /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf5 install -y nvidia-container-toolkit-base
nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo

for package in libnvidia-container-tools kmod-nvidia nvidia-driver-cuda; do
	rpm -q "${package}" >/dev/null || {
		echo "Missing NVIDIA package: ${package}" >&2
		exit 1
	}
done
