# MuJoCo 仿真 primitive — 比赛推荐仿真框架接入

> 将 MuJoCo（题目推荐的仿真框架）作为 robonix primitive 接入，不依赖 ROS2，直接通过 MCP/gRPC 暴露能力。
> 基于 `simulator.md` 方案 C。

## 架构

```
MuJoCo 仿真器 (robosuite Franka/Panda 机械臂)
  ↓ 直接 Python 调用（不走 ROS2）
mujoco_sim primitive (robonix Capability)
  ↓ MCP Contract (camera/snapshot, arm/control, lidar/snapshot)
atlas → pilot → executor → 闭环
```

与 Webots 方案的区别：
- **不需要 ROS2** — MuJoCo 直接在进程内调用，通过 MCP 暴露给 pilot
- **不需要 Docker** — 纯 Python，直接在宿主机跑
- **复用所有系统服务** — pilot/executor/scene/speech 等完全不用改

## 能力暴露

| Contract | 类型 | 说明 |
|----------|------|------|
| `robonix/primitive/camera/snapshot` | MCP | 渲染 MuJoCo 场景一帧 RGB |
| `robonix/primitive/camera/depth_snapshot` | MCP | 渲染深度图 |
| `robonix/primitive/lidar/snapshot` | MCP | 模拟 2D 激光扫描 |
| `mujoco_sim/arm/control` | MCP | 机械臂关节控制（末端位置/关节角度） |
| `mujoco_sim/arm/get_state` | MCP | 获取当前机械臂状态（关节角、末端位置） |
| `mujoco_sim/scene/reset` | MCP | 重置仿真场景 |
| `mujoco_sim/scene/step` | MCP | 手动步进仿真 |
| `mujoco_sim/object/list` | MCP | 列出场景中所有物体 |
| `mujoco_sim/object/pose` | MCP | 获取物体位姿 |

## 使用

```bash
# 构建
cd examples/mujoco_sim
rbnx codegen -p . --mcp
rbnx build -p .

# 启动（不需要先启动 Webots）
rbnx boot   # 用 robonix_manifest_mujoco.yaml
```
