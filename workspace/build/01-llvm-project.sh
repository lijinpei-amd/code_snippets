#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <llvm-project-path>" >&2
    echo "  builds into <llvm-project-path>/build (in-tree, required for" >&2
    echo "  cross-worktree ccache sharing — see ccache.conf base_dir)" >&2
    exit 2
fi

LLVM_PROJECT_PATH="$1"
# Build in-tree at <worktree>/build. Keeping the build dir inside the worktree
# is what makes ccache's base_dir cancel the workspace/NN prefix, so identical
# sources hit across worktrees instead of each worktree being its own silo.
LLVM_BUILD_PATH="$LLVM_PROJECT_PATH/build"

LLVM_BUILD_TYPE=Debug

LLVM_PROJECTS="mlir;llvm;lld;clang"
LLVM_TARGETS="all"
LLVM_DEFAULT_TARGET_TRIPLE=${LLVM_DEFAULT_TARGET_TRIPLE:-x86_64-unknown-linux-gnu}

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
    -DLLVM_DEFAULT_TARGET_TRIPLE="$LLVM_DEFAULT_TARGET_TRIPLE"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=1
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS"
    # BUILD_SHARED_LIBS: each component is its own .so, so editing one file
    # relinks one small lib instead of a giant dylib/static tools. Mutually
    # exclusive with LLVM_LINK_LLVM_DYLIB (llvm/CMakeLists.txt FATAL_ERRORs if
    # both are set), so the dylib option is dropped in favour of this.
    -DBUILD_SHARED_LIBS=ON
    # Trim the build graph: skip examples/benchmarks/docs we never use.
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    # Don't embed the git revision: avoids relinking tools every time HEAD
    # changes when switching commits across worktrees.
    -DLLVM_APPEND_VC_REV=OFF
    # Emit directory-neutral debug/__FILE__ paths so ccache can reuse the .o
    # across worktrees. Source root -> /llvm-project/ (trailing slash is
    # required: the cmake rule maps "${source_root}/" so a bare "/llvm-project"
    # would yield "/llvm-projectllvm/..."). ~/.config/gdb/gdbinit reverses this.
    -DLLVM_USE_RELATIVE_PATHS_IN_FILES=ON
    -DLLVM_SOURCE_PREFIX=/llvm-project/
    -B"$LLVM_BUILD_PATH" "$LLVM_PROJECT_PATH/llvm"
)

cmake "${CMAKE_ARGS[@]}"
cmake --build "$LLVM_BUILD_PATH"

LLVM_BUILD_PATH_YAML=${LLVM_BUILD_PATH//\'/\'\'}
cat > "$LLVM_PROJECT_PATH/.clangd" <<EOF
CompileFlags:
  CompilationDatabase: '$LLVM_BUILD_PATH_YAML'
EOF

# Project-scoped Claude config: keep the Co-Authored-By / "Generated with
# Claude Code" trailer out of commits made from this LLVM worktree, without
# touching the global ~/.claude settings. settings.local.json is the personal,
# git-excluded tier, so it can't accidentally land in an LLVM commit.
mkdir -p "$LLVM_PROJECT_PATH/.claude"
cat > "$LLVM_PROJECT_PATH/.claude/settings.local.json" <<EOF
{
  "includeCoAuthoredBy": false
}
EOF
