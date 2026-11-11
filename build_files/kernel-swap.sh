#!/bin/bash

set ${CI:+-x} -euo pipefail

dnf5 -y install 'dnf-command(versionlock)'

KERNEL_NAME="kernel"

PKGS=( "${KERNEL_NAME}" "${KERNEL_NAME}-core" "${KERNEL_NAME}-modules" "${KERNEL_NAME}-modules-core" "${KERNEL_NAME}-modules-extra" "${KERNEL_NAME}-uki-virt" )
for pkg in "${PKGS[@]}"; do
  rpm --erase "$pkg" --nodeps || true
done

find /tmp/kernel-rpms

CACHED_VERSION=$(cd /tmp/kernel-rpms && ls kernel-[0-9]*.rpm 2>/dev/null | head -1 | sed -E 's/^kernel-//;s/\.rpm$//')

if [[ -z "$CACHED_VERSION" ]]; then
  echo "ERROR: Could not detect kernel version from /tmp/kernel-rpms"
  ls -la /tmp/kernel-rpms/
  exit 1
fi

INSTALL_PKGS=( "${KERNEL_NAME}" "${KERNEL_NAME}-core" "${KERNEL_NAME}-modules" "${KERNEL_NAME}-modules-core" "${KERNEL_NAME}-modules-extra" "${KERNEL_NAME}-uki-virt" "${KERNEL_NAME}-devel" "${KERNEL_NAME}-devel-matched" )

RPM_NAMES=()
for pkg in "${INSTALL_PKGS[@]}"; do
  RPM_NAMES+=("/tmp/kernel-rpms/$pkg-$CACHED_VERSION.rpm")
done

mkdir -p /etc/dracut.conf.d
echo 'tmpdir="/boot"' > /etc/dracut.conf.d/01-tmpdir.conf

dnf5 -y install --setopt=tsflags=noscripts "${RPM_NAMES[@]}"

depmod -a "${CACHED_VERSION}"

if [[ "${CACHED_VERSION}" == *.fc* ]]; then
  echo 'omit_dracutmodules+=" microcode_ctl microcode_ctl-fw_dir_override "' > /etc/dracut.conf.d/02-omit-unsupported-microcode.conf
fi
dracut --no-hostonly --kver "${CACHED_VERSION}" --reproducible --tmpdir /boot --zstd -v --add ostree -f "/lib/modules/${CACHED_VERSION}/initramfs.img"

echo "Installing common akmods for HWE CoreOS kernel..."

KERNEL_VERSION=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')
echo "Detected kernel version: ${KERNEL_VERSION}"

AKMODS_FLAVOR="coreos-stable"
FEDORA_VERSION=$(echo "${KERNEL_VERSION}" | grep -oP 'fc\K[0-9]+')
if [[ -z "${FEDORA_VERSION}" ]]; then
  FEDORA_VERSION="${FEDORA_AKMODS_VERSION:-43}"
fi

COMMON_AKMODS_DIR="/run/common-akmods"
mkdir -p "$COMMON_AKMODS_DIR"

skopeo copy --retry-times 3 \
  docker://ghcr.io/ublue-os/akmods:"${AKMODS_FLAVOR}"-"${FEDORA_VERSION}"-"${KERNEL_VERSION}" \
  dir:"$COMMON_AKMODS_DIR"/akmods-container

AKMODS_TARGZ=$(jq -r '.layers[].digest' <"$COMMON_AKMODS_DIR"/akmods-container/manifest.json | cut -d : -f 2)
tar -xzf "$COMMON_AKMODS_DIR"/akmods-container/"$AKMODS_TARGZ" -C "$COMMON_AKMODS_DIR"

if [[ -d "$COMMON_AKMODS_DIR"/rpms ]]; then
  echo "Available common akmods packages:"
  ls -lh "$COMMON_AKMODS_DIR"/rpms/ || true
  ls -lh "$COMMON_AKMODS_DIR"/rpms/kmods/ || true

  echo "Installing common akmods with dependencies..."
  dnf -y install \
    "$COMMON_AKMODS_DIR"/rpms/*xone*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/*openrazer*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/*framework-laptop*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/*v4l2loopback*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/kmods/*xone*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/kmods/*openrazer*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/kmods/*framework-laptop*.rpm \
    "$COMMON_AKMODS_DIR"/rpms/kmods/*v4l2loopback*.rpm \
    || echo "Warning: Some common akmods failed to install (non-critical)"
else
  echo "Warning: No rpms directory found in common akmods container"
fi
echo "Installed common akmods packages:"
rpm -qa | grep -E 'xone|openrazer|framework|v4l2loopback' || true
rm -rf "$COMMON_AKMODS_DIR"

rm -f /etc/dracut.conf.d/01-tmpdir.conf

dnf versionlock add \
  "$KERNEL_NAME" \
  "$KERNEL_NAME"-core \
  "$KERNEL_NAME"-modules \
  "$KERNEL_NAME"-modules-core \
  "$KERNEL_NAME"-modules-extra
