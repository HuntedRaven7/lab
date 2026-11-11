#!/bin/bash

# Install build deps
dnf -y install go

# Clone and build main uupd 
rm -rf /root 
git clone https://github.com/ublue-os/uupd.git
cd uupd && make build && make install

systemctl enable uupd.timer
