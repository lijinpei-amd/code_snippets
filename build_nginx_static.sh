#!/bin/bash
#
# Build nginx 1.30.3 as a fully static binary with high optimizations.
# Installs to ~/proot/nginx
#
# nginx's configure can build PCRE2, zlib, and OpenSSL from source
# when given their source directories via --with-pcre/--with-zlib/--with-openssl.
#
set -euo pipefail

NGINX_VERSION="1.30.3"
NGINX_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
NGINX_SHA256="e5823dc6f45610993def93ebf6cfce68264af4958c77e874b7d20f3709001b8f"
INSTALL_PREFIX="$HOME/proot/nginx"

# Dependency versions (built inline by nginx's configure)
PCRE2_VERSION="10.47"
ZLIB_VERSION="1.3.2"
OPENSSL_VERSION="3.5.7"

PCRE2_SHA256="c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
OPENSSL_SHA256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"

PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

NPROC=$(nproc)
BUILD_DIR="$(mktemp -d /tmp/nginx-static-build.XXXXXX)"

# Aggressive optimization flags for x86_64
OPT_CFLAGS="-O3 -march=native -mtune=native -flto -fomit-frame-pointer -pipe -DNDEBUG"
OPT_LDFLAGS="-static -O3 -flto -s"

on_exit() {
    echo "Build directory kept at: ${BUILD_DIR}"
    echo "Remove it manually with: rm -rf ${BUILD_DIR}"
}
trap on_exit EXIT

download_verified() {
    local output="$1" url="$2" expected_sha256="$3" actual_sha256

    curl -fSL --retry 3 -o "$output" "$url"
    actual_sha256=$(sha256sum "$output" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "error: SHA-256 mismatch for $output" >&2
        echo "       expected: $expected_sha256" >&2
        echo "       actual:   $actual_sha256" >&2
        rm -f "$output"
        return 1
    fi
}

echo "============================================"
echo " Static nginx ${NGINX_VERSION} build"
echo " Install prefix: ${INSTALL_PREFIX}"
echo " Build dir:      ${BUILD_DIR}"
echo " Parallelism:    ${NPROC} jobs"
echo "============================================"

cd "${BUILD_DIR}"

# --- Download all sources ---
echo "[1/4] Downloading sources..."
download_verified "nginx-${NGINX_VERSION}.tar.gz" "${NGINX_URL}" "${NGINX_SHA256}" &
pids=($!)
download_verified "pcre2-${PCRE2_VERSION}.tar.gz" "${PCRE2_URL}" "${PCRE2_SHA256}" &
pids+=($!)
download_verified "zlib-${ZLIB_VERSION}.tar.gz" "${ZLIB_URL}" "${ZLIB_SHA256}" &
pids+=($!)
download_verified "openssl-${OPENSSL_VERSION}.tar.gz" "${OPENSSL_URL}" "${OPENSSL_SHA256}" &
pids+=($!)

download_failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || download_failed=1
done
[ "$download_failed" -eq 0 ] || exit 1

echo "[2/4] Extracting sources..."
tar xzf "nginx-${NGINX_VERSION}.tar.gz"
tar xzf "pcre2-${PCRE2_VERSION}.tar.gz"
tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"

# --- Configure nginx (it builds PCRE2, zlib, OpenSSL from source) ---
echo "[3/4] Configuring nginx ${NGINX_VERSION}..."
cd "nginx-${NGINX_VERSION}"
./configure \
    --prefix="${INSTALL_PREFIX}" \
    --sbin-path="${INSTALL_PREFIX}/sbin/nginx" \
    --modules-path="${INSTALL_PREFIX}/modules" \
    --conf-path="${INSTALL_PREFIX}/conf/nginx.conf" \
    --error-log-path="${INSTALL_PREFIX}/logs/error.log" \
    --http-log-path="${INSTALL_PREFIX}/logs/access.log" \
    --pid-path="${INSTALL_PREFIX}/logs/nginx.pid" \
    --lock-path="${INSTALL_PREFIX}/logs/nginx.lock" \
    \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_gunzip_module \
    --with-http_secure_link_module \
    --with-threads \
    --with-file-aio \
    \
    --without-http_autoindex_module \
    --without-http_ssi_module \
    --without-http_geo_module \
    --without-http_split_clients_module \
    --without-http_uwsgi_module \
    --without-http_scgi_module \
    --without-http_grpc_module \
    --without-http_memcached_module \
    --without-http_empty_gif_module \
    --without-http_browser_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    \
    --with-pcre="${BUILD_DIR}/pcre2-${PCRE2_VERSION}" \
    --with-pcre-jit \
    --with-zlib="${BUILD_DIR}/zlib-${ZLIB_VERSION}" \
    --with-openssl="${BUILD_DIR}/openssl-${OPENSSL_VERSION}" \
    --with-openssl-opt="no-shared no-tests" \
    \
    --with-cc-opt="${OPT_CFLAGS}" \
    --with-ld-opt="${OPT_LDFLAGS}"

# --- Build and install ---
echo "[4/4] Building and installing nginx..."
make -j"${NPROC}"
make install

echo ""
echo "============================================"
echo " Build complete!"
echo " Binary:  ${INSTALL_PREFIX}/sbin/nginx"
echo "============================================"

# Verify static linking. `ldd` output is not a reliable assertion: its wording
# varies by platform and ignoring its exit status also lets dynamically linked
# binaries pass. A fully static ELF has neither a program interpreter nor any
# DT_NEEDED entries.
echo ""
echo "Verifying static build:"
NGINX_BINARY="${INSTALL_PREFIX}/sbin/nginx"
file "${NGINX_BINARY}"

if ! command -v readelf >/dev/null 2>&1; then
    echo "error: readelf is required to verify that nginx is fully static" >&2
    exit 1
fi

PROGRAM_HEADERS=$(readelf --wide --program-headers "${NGINX_BINARY}")
DYNAMIC_SECTION=$(readelf --wide --dynamic "${NGINX_BINARY}")

if grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)' <<<"${PROGRAM_HEADERS}"; then
    echo "error: ${NGINX_BINARY} has a program interpreter and is dynamically linked" >&2
    exit 1
fi

if grep -Fq '(NEEDED)' <<<"${DYNAMIC_SECTION}"; then
    echo "error: ${NGINX_BINARY} has DT_NEEDED entries and is dynamically linked" >&2
    exit 1
fi

echo "Verified: no ELF interpreter or DT_NEEDED dependencies"

echo ""
ls -lh "${NGINX_BINARY}"

echo ""
"${NGINX_BINARY}" -V
