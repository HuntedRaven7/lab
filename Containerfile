# Homelab image

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
FROM quay.io/fedora/fedora-bootc:44

# [IM]MUTABLE /opt
RUN rm -rf /opt && mkdir /opt

# Pinned k3s version (note the "+k3sN" suffix used in k3s release tags)
ARG K3S_VERSION=v1.37.1+k3s1
ARG TARGETARCH=amd64

# Download the pinned k3s binary into /usr/bin
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) K3S_BIN="k3s" ;; \
      arm64) K3S_BIN="k3s-arm64" ;; \
      arm)   K3S_BIN="k3s-armhf" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/bin/k3s \
      "https://github.com/k3s-io/k3s/releases/download/$(echo "${K3S_VERSION}" | sed 's/+/%2B/')/${K3S_BIN}"; \
    chmod 0755 /usr/bin/k3s

# Laptop suspend off when lid closed 
RUN systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target && \
    mkdir -p /etc/systemd/logind.conf.d && \
    printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\nIdleAction=ignore\n' \
      > /etc/systemd/logind.conf.d/50-no-suspend.conf

# UUPD
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/uupd-build.sh 

# BUILD
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build-homelab.sh

# INIT
CMD ["/sbin/init"]

# LINTING
RUN bootc container lint
