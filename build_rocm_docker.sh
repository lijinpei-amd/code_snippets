#!/usr/bin/env bash
set -euo pipefail

PINNED_ROCM_VERSION="7.2"
ROCM_VER="${1:-$PINNED_ROCM_VERSION}"
ROCM_KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
ROCM_KEY_SHA256="2de99e2354646a90d9903e2a669fc4e36b02c1bbff7075c481e12d7edab2c88b"
ROCM_KEY_FINGERPRINT="CA8BB4727A47B4D09B4EE8969386B48A1A693C5C"

if [ "$ROCM_VER" != "$PINNED_ROCM_VERSION" ]; then
    echo "error: this image is pinned to ROCm $PINNED_ROCM_VERSION, got $ROCM_VER" >&2
    exit 2
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata wget gnupg python3 python3-dev python3-venv cmake ninja-build g++ curl lsb-release software-properties-common
ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
dpkg-reconfigure --frontend noninteractive tzdata
install -d -m 0755 /etc/apt/keyrings

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

curl -fSL --retry 3 -o "$tmpdir/rocm.gpg.key" "$ROCM_KEY_URL"
actual_sha256=$(sha256sum "$tmpdir/rocm.gpg.key" | awk '{print $1}')
if [ "$actual_sha256" != "$ROCM_KEY_SHA256" ]; then
    echo "error: ROCm signing-key SHA-256 mismatch" >&2
    exit 1
fi

mkdir "$tmpdir/gnupg"
chmod 700 "$tmpdir/gnupg"
actual_fingerprint=$(
    GNUPGHOME="$tmpdir/gnupg" gpg --batch --show-keys --with-colons "$tmpdir/rocm.gpg.key" 2>/dev/null \
        | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; exit }'
)
if [ "$actual_fingerprint" != "$ROCM_KEY_FINGERPRINT" ]; then
    echo "error: unexpected ROCm signing-key fingerprint: $actual_fingerprint" >&2
    exit 1
fi

GNUPGHOME="$tmpdir/gnupg" gpg --batch --yes --dearmor \
    --output "$tmpdir/rocm.gpg" "$tmpdir/rocm.gpg.key"
install -m 0644 "$tmpdir/rocm.gpg" /etc/apt/keyrings/rocm.gpg
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
