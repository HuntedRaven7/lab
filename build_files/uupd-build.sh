#!/bin/bash

# Install build deps
dnf5 -y install go

# Clone and build main uupd 
rm -rf /root 
git clone https://github.com/ublue-os/uupd.git 
cd uupd
go build && go install
