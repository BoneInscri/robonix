#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# MuJoCo sim primitive start — runs on host directly (no Docker, no ROS2).
set -euo pipefail

PKG="${RBNX_PACKAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PKG"
ROBONIX_ROOT="$(cd "$PKG/../.." && pwd)"

export ROBONIX_ATLAS="${ROBONIX_ATLAS:-127.0.0.1:50051}"
export PYTHONPATH="$PKG:$ROBONIX_ROOT/pylib/robonix-api:$PKG/rbnx-build/codegen/proto_gen:$PKG/rbnx-build/codegen/robonix_mcp_types:${PYTHONPATH:-}"

# ROCm 环境（如果在 AMD GPU 机器上）
source /etc/profile.d/rocm-env.sh 2>/dev/null || true

exec rbnx-build/venv/bin/python -m mujoco_sim.driver
