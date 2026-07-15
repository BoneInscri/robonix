#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# MuJoCo sim primitive build — codegen + venv with mujoco/robosuite deps.
set -euo pipefail
PKG="${RBNX_PACKAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PKG"

BUILD="rbnx-build"
VENV="$BUILD/venv"

: "${UV_INDEX_URL:=https://pypi.tuna.tsinghua.edu.cn/simple}"
: "${PIP_INDEX_URL:=https://pypi.tuna.tsinghua.edu.cn/simple}"
export UV_INDEX_URL PIP_INDEX_URL

CLEAN="${RBNX_BUILD_CLEAN:-}"
if [[ "$CLEAN" == "1" ]]; then
    echo "[mujoco_sim/build] clean: removing $BUILD"
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD/data"

# 1. uv venv
if ! command -v uv >/dev/null 2>&1; then
    echo "[mujoco_sim/build] error: 'uv' not found" >&2
    exit 1
fi

if [[ ! -d "$VENV" ]]; then
    echo "[mujoco_sim/build] uv venv → $VENV"
    uv venv "$VENV"
fi

# 2. Install deps
echo "[mujoco_sim/build] installing mujoco + robosuite into venv"
VIRTUAL_ENV="$PKG/$VENV" uv pip install --active \
    "mujoco>=3.3.0" \
    robosuite \
    numpy Pillow \
    "grpcio>=1.78.0" "protobuf>=6.30,<7" \
    mcp "fastmcp>=3" \
    2>/dev/null || \
"$VENV/bin/pip" install --no-cache-dir \
    "mujoco>=3.3.0" \
    robosuite \
    numpy Pillow \
    "grpcio>=1.78.0" "protobuf>=6.30,<7" \
    mcp "fastmcp>=3"

# 3. Codegen
FLAGS=(--mcp)
[[ "$CLEAN" == "1" ]] && FLAGS+=(--clean)
echo "[mujoco_sim/build] rbnx codegen ${FLAGS[*]}"
rbnx codegen -p "$PKG" "${FLAGS[@]}"

echo "[mujoco_sim/build] done."
