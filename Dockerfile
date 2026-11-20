ARG UBUNTU_VER=26.04
FROM ubuntu:${UBUNTU_VER}
COPY build_rocm_docker.sh /
RUN bash /build_rocm_docker.sh
