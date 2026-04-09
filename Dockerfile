FROM ubuntu:24.04
ARG ROCM_VER=7.2
COPY build_rocm_docker.sh /
RUN bash /build_rocm_docker.sh "$ROCM_VER"
