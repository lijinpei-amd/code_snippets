FROM ubuntu:24.04
COPY build_rocm_docker.sh /
RUN bash /build_rocm_docker.sh
