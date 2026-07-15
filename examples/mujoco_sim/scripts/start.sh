#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# MuJoCo sim primitive start — runs on host directly (no Docker, no ROS2).
set -eo pipefail

PKG_ROOT="${RBNX_PACKAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PKG_ROOT"

export PYTHONPATH="$(rbnx path robonix-api 2>/dev/null || echo "$PKG_ROOT/../../pylib/robonix-api"):$PKG_ROOT/rbnx-build/codegen/proto_gen:$PKG_ROOT/rbnx-build/codegen/robonix_mcp_types:${PYTHONPATH:-}"

# ROCm 环境（如果在 AMD GPU 机器上）
source /etc/profile.d/rocm-env.sh 2>/dev/null || true

exec rbnx-build/venv/bin/python -m mujoco_sim.driver
