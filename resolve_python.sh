# Resolves the Python interpreter for an Ubuntu release, as tabulated in the AMD
# install docs. The ROCm wheels themselves are py3-none-linux_x86_64, so any of
# these work. Sourced by build_uv_docker.sh and setup_rocm_venv.sh so the two
# can't drift; expects UBUNTU_VER to be set and sets PYTHON.
case "$UBUNTU_VER" in
    26.04) PYTHON="python3.14" ;;
    24.04) PYTHON="python3.12" ;;
    22.04) PYTHON="python3.11" ;;
    *)
        echo "error: unsupported Ubuntu release '$UBUNTU_VER'" >&2
        echo "       expected one of: 26.04, 24.04, 22.04" >&2
        exit 2
        ;;
esac
