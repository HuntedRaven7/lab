#!/usr/bin/env bash

set -euo pipefail

dnf5 -y install tailscale
systemctl enable tailscaled
