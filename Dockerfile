ARG UBUNTU_VER=26.04
FROM ubuntu:${UBUNTU_VER}
# Re-declare: an ARG before FROM is out of scope inside the build stage.
ARG UBUNTU_VER
ARG ROCM_VER=7.14.0
# Comma-separated device extras, e.g. "device-gfx950,device-gfx942" or
# "device-all". Each device wheel is ~1.6 GiB, so "device-all" is ~40 GiB.
ARG ROCM_DEVICE_TARGETS=device-gfx950
# System packages and uv, baked once as its own layer.
COPY resolve_python.sh build_uv_docker.sh /
RUN bash /build_uv_docker.sh "$UBUNTU_VER"
# ROCm virtualenv, the layer that gets rebuilt when versions/targets change.
COPY setup_rocm_venv.sh /
RUN bash /setup_rocm_venv.sh "$ROCM_VER" "$ROCM_DEVICE_TARGETS" "$UBUNTU_VER"
# /opt/rocm is a symlink the script points at the resolved SDK root;
# /opt/rocm-venv must match ROCM_VENV in setup_rocm_venv.sh.
ENV ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    PATH=/opt/rocm-venv/bin:/opt/rocm/bin:$PATH
