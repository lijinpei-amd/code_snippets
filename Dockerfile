ARG UBUNTU_VER=26.04
FROM ubuntu:${UBUNTU_VER}
# Re-declare: an ARG before FROM is out of scope inside the build stage.
ARG UBUNTU_VER
# System packages and uv, baked once as its own layer. ROCm is deliberately
# NOT installed into the image: it is set up per-user at runtime into a venv via
# setup_rocm_venv_local.sh (or setup_rocm_venv.sh for a root/system install).
COPY resolve_python.sh build_uv_docker.sh /
RUN bash /build_uv_docker.sh "$UBUNTU_VER"
