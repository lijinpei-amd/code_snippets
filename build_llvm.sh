#!/usr/bin/env bash
set -euo pipefail

: "${1:?Usage: build_llvm.sh <workspace> <build_type>}"
LLVM_BUILD_TYPE="${2:?Usage: build_llvm.sh <workspace> <build_type>}"

DEV_PATH="${HOME}/development"
WORK_SPACE_PATH="${DEV_PATH}/workspace/$1"

build_type_lower="${LLVM_BUILD_TYPE,,}"

LLVM_PROJECT_PATH="${WORK_SPACE_PATH}/llvm-project/"
LLVM_BUILD_PATH="${WORK_SPACE_PATH}/build/llvm-project_${build_type_lower}"
LLVM_INSTALL_PATH="${WORK_SPACE_PATH}/install/llvm-project_${build_type_lower}"

LLVM_PROJECTS="mlir;llvm;lld;clang"
LLVM_TARGETS="all"
LLVM_LINK_LLVM_DYLIB=${LLVM_LINK_LLVM_DYLIB:-ON}

CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE="$LLVM_BUILD_TYPE"
    -DLLVM_CCACHE_BUILD=ON
    -DLLVM_USE_SPLIT_DWARF=ON
    -DLLVM_ENABLE_ASSERTIONS=ON
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DLLVM_ENABLE_LLD=ON
    -DLLVM_OPTIMIZED_TABLEGEN=ON
    -DMLIR_ENABLE_BINDINGS_PYTHON=OFF
    -DLLVM_ENABLE_ZSTD=OFF
    -DLLVM_ENABLE_RTTI=ON
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=1
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS"
    -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL_PATH"
    -DLLVM_LINK_LLVM_DYLIB="$LLVM_LINK_LLVM_DYLIB"
    -B"$LLVM_BUILD_PATH" "$LLVM_PROJECT_PATH/llvm"
)

cmake "${CMAKE_ARGS[@]}"
cmake --build "$LLVM_BUILD_PATH"
cmake --install "$LLVM_BUILD_PATH"
