#!/usr/bin/env bash
set -e
set -o pipefail
ROCM_VER="${1:?Usage: build_rocm_docker.sh <rocm_version>}"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata wget gnupg python3 python3-dev python3-venv cmake ninja-build g++ curl lsb-release software-properties-common
ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
dpkg-reconfigure --frontend noninteractive tzdata
mkdir --parents --mode=0755 /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor > /etc/apt/keyrings/rocm.gpg
cat > /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VER} noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/${ROCM_VER}/ubuntu noble main
EOF
cat > /etc/apt/preferences.d/rocm-pin-600 << EOF
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
apt-get update
apt-get install -y rocm
