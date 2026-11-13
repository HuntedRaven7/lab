#!/bin/bash
set -ouex pipefail

cp -avf "/ctx/repos/terra.repo" /etc/yum.repos.d/terra.repo
cp -avf "/ctx/repos/fedora-multimedia.repo" /etc/yum.repos.d/fedora-multimedia.repo

dnf makecache --refresh
dnf5 distro-sync --skip-unavailable -y --repo='fedora-multimedia'
dnf5 distro-sync --skip-unavailable -y --repo='terra'
