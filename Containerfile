# Homelab image

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
FROM quay.io/fedora/fedora-bootc:44

# [IM]MUTABLE /opt
RUN rm -rf /opt && mkdir /opt

# Pinned k0s version (note the "+k0s.N" suffix used in k0s release tags)
ARG K0S_VERSION=v1.34.1+k0s.0
ARG TARGETARCH=amd64
 
# Download the pinned k0s binary into /usr/bin
RUN set -eux; \
    curl -fsSL -o /usr/bin/k0s \
      "https://github.com/k0sproject/k0s/releases/download/$(echo "${K0S_VERSION}" | sed 's/+/%2B/')/k0s-${K0S_VERSION}-${TARGETARCH}"; \
    chmod 0755 /usr/bin/k0s

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
