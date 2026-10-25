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
 
# Download the pinned k0s binary into /opt/k0s/bin
RUN set -eux; \
    mkdir -p /opt/k0s/bin; \
    curl -fsSL -o /opt/k0s/bin/k0s \
      "https://github.com/k0sproject/k0s/releases/download/$(echo "${K0S_VERSION}" | sed 's/+/%2B/')/k0s-${K0S_VERSION}-${TARGETARCH}"; \
    chmod 0755 /opt/k0s/bin/k0s; 

# MODIFICATIONS
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/uupd-build.sh \
    /ctx/build.sh

# INIT
CMD ["/sbin/init"]

# LINTING
RUN bootc container lint
