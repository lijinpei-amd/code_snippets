#!/bin/bash
#
# Build nginx 1.29.8 as a fully static binary with high optimizations.
# Installs to ~/proot/nginx
#
# nginx's configure can build PCRE2, zlib, and OpenSSL from source
# when given their source directories via --with-pcre/--with-zlib/--with-openssl.
#
set -euo pipefail

NGINX_VERSION="1.29.8"
NGINX_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
INSTALL_PREFIX="$HOME/proot/nginx"

# Dependency versions (built inline by nginx's configure)
PCRE2_VERSION="10.44"
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.4.1"

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

echo "============================================"
echo " Static nginx ${NGINX_VERSION} build"
echo " Install prefix: ${INSTALL_PREFIX}"
echo " Build dir:      ${BUILD_DIR}"
echo " Parallelism:    ${NPROC} jobs"
echo "============================================"

cd "${BUILD_DIR}"

# --- Download all sources ---
echo "[1/4] Downloading sources..."
curl -fSL --retry 3 -o "nginx-${NGINX_VERSION}.tar.gz"     "${NGINX_URL}" &
curl -fSL --retry 3 -o "pcre2-${PCRE2_VERSION}.tar.gz"     "${PCRE2_URL}" &
curl -fSL --retry 3 -o "zlib-${ZLIB_VERSION}.tar.gz"       "${ZLIB_URL}" &
curl -fSL --retry 3 -o "openssl-${OPENSSL_VERSION}.tar.gz" "${OPENSSL_URL}" &
wait

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

# Verify static linking
echo ""
echo "Verifying static build:"
file "${INSTALL_PREFIX}/sbin/nginx"
ldd "${INSTALL_PREFIX}/sbin/nginx" 2>&1 || true

echo ""
ls -lh "${INSTALL_PREFIX}/sbin/nginx"

echo ""
"${INSTALL_PREFIX}/sbin/nginx" -V
