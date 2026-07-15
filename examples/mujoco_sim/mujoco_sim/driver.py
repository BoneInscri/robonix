# SPDX-License-Identifier: MulanPSL-2.0
"""MuJoCo simulation primitive — robosuite Franka arm environment.

Owns `robonix/primitive/camera/*`, `robonix/primitive/lidar/snapshot`,
and `mujoco_sim/*` capabilities. Runs MuJoCo in-process (no ROS2) and
exposes snapshots/control through robonix MCP contracts.

The simulation uses robosuite's Lift task (Franka Panda arm + cube on
table). The arm is controlled via OSC (Operational Space Controller) —
the LLM specifies end-effector position targets and gripper open/close.

Capabilities exposed:

  robonix/primitive/camera/snapshot       MCP   RGB JPEG
  robonix/primitive/camera/depth_snapshot MCP   depth as 8-bit JPEG
  robonix/primitive/lidar/snapshot        MCP   simulated 2D scan
  mujoco_sim/arm/control                  MCP   end-effector move + grip
  mujoco_sim/arm/get_state                MCP   joint pos + ee pos
  mujoco_sim/scene/reset                  MCP   reset to initial
  mujoco_sim/scene/step                   MCP   step N frames
  mujoco_sim/object/list                  MCP   object names
  mujoco_sim/object/pose                  MCP   object position/rotation
"""
from __future__ import annotations

import io
import json
import math
import os
import threading
import time
from typing import Any

import numpy as np

from robonix_api import Primitive, Ok, Err, Deferred

# ── primitive 注册 ──────────────────────────────────────────────────────────
mujoco_sim = Primitive(id="mujoco_sim", namespace="mujoco_sim")

# ── 仿真状态 ────────────────────────────────────────────────────────────────
_sim_lock = threading.Lock()
_env: Any = None  # robosuite environment
_renderer: Any = None  # offscreen renderer


def _ensure_env():
    """Lazy-init the robosuite environment on first use."""
    global _env, _renderer
    if _env is not None:
        return _env
    with _sim_lock:
        if _env is not None:
            return _env
        import robosuite as suite

        env_name = os.environ.get("MUJOCO_SIM_ENV", "Lift")
        robot_name = os.environ.get("MUJOCO_SIM_ROBOT", "Panda")
        horizon = int(os.environ.get("MUJOCO_SIM_HORIZON", "500"))

        _env = suite.make(
            env_name=env_name,
            robots=[robot_name],
            controller=os.environ.get("MUJOCO_SIM_CONTROLLER", "OSC_POSE"),
            gripper_types=os.environ.get("MUJOCO_SIM_GRIPPER", "Panda"),
            has_renderer=False,  # we do offscreen rendering ourselves
            has_offscreen_renderer=True,
            use_camera_obs=True,
            camera_names=os.environ.get("MUJOCO_SIM_CAMERA", "agentview"),
            camera_heights=int(os.environ.get("MUJOCO_CAM_H", "256")),
            camera_widths=int(os.environ.get("MUJOCO_CAM_W", "256")),
            horizon=horizon,
            ignore_done=True,
            hard_reset=False,
        )
        _env.reset()
        print(f"[mujoco_sim] env={env_name} robot={robot_name} ready", flush=True)
    return _env


# ── 图像工具 ────────────────────────────────────────────────────────────────
def _array_to_jpeg(arr: np.ndarray, is_depth: bool = False) -> bytes:
    """Convert numpy array to JPEG bytes."""
    from PIL import Image as PILImage

    if is_depth:
        # depth is float32 meters — normalize to 0-255
        valid = np.isfinite(arr)
        if valid.any():
            mn, mx = float(arr[valid].min()), float(arr[valid].max())
            norm = np.where(valid, (arr - mn) / max(mx - mn, 1e-6) * 255, 0).astype(np.uint8)
        else:
            norm = np.zeros(arr.shape[:2], dtype=np.uint8)
        arr = np.stack([norm, norm, norm], axis=-1)
    elif arr.dtype != np.uint8:
        arr = (arr * 255).astype(np.uint8) if arr.max() <= 1.0 else arr.astype(np.uint8)
    if arr.ndim == 2:
        arr = np.stack([arr, arr, arr], axis=-1)
    buf = io.BytesIO()
    PILImage.fromarray(np.ascontiguousarray(arr)).save(buf, format="JPEG", quality=85)
    return buf.getvalue()


def _sim_step_and_render() -> dict:
    """Step the sim with zero action (hold position), return latest obs."""
    env = _ensure_env()
    with _sim_lock:
        obs, _, _, _ = env.step(np.zeros(env.action_dim))
    return obs


def _get_camera_obs() -> dict:
    """Get current camera observation without stepping."""
    env = _ensure_env()
    with _sim_lock:
        # robosuite camera obs are in env._observation
        obs = env._get_observations()
    return obs


# ── MCP 工具：相机 ──────────────────────────────────────────────────────────
import builtin_interfaces_mcp  # noqa: E402
import std_msgs_mcp  # noqa: E402
from sensor_msgs_mcp import Image  # noqa: E402
from std_msgs_mcp import Empty  # noqa: E402


def _now_header(frame_id: str) -> std_msgs_mcp.Header:
    now = time.time()
    return std_msgs_mcp.Header(
        stamp=builtin_interfaces_mcp.Time(sec=int(now), nanosec=int((now % 1) * 1e9) % 1_000_000_000),
        frame_id=frame_id,
    )


def _jpeg_to_image_mcp(jpg: bytes, frame_id: str) -> Image:
    from PIL import Image as PILImage
    im = PILImage.open(io.BytesIO(jpg))
    w, h = im.size
    return Image(
        header=_now_header(frame_id),
        height=h, width=w,
        encoding="jpeg",
        is_bigendian=0,
        step=len(jpg),
        data=jpg,
    )


@mujoco_sim.mcp("robonix/primitive/camera/snapshot")
def camera_snapshot(msg: Empty) -> Image:
    """Capture one RGB image from the MuJoCo agentview camera.
    Returns sensor_msgs/Image (JPEG-encoded). Use this to see the
    arm's workspace: table, objects, gripper position.
    Contract: robonix/primitive/camera/snapshot."""
    _ = msg
    obs = _get_camera_obs()
    cam_key = os.environ.get("MUJOCO_SIM_CAMERA", "agentview")
    rgb_key = f"{cam_key}_image"
    if rgb_key not in obs:
        # try common alternatives
        for k in obs:
            if "image" in k and "depth" not in k:
                rgb_key = k
                break
    arr = obs[rgb_key]
    jpg = _array_to_jpeg(arr, is_depth=False)
    return _jpeg_to_image_mcp(jpg, "mujoco_camera_rgb")


@mujoco_sim.mcp("robonix/primitive/camera/depth_snapshot")
def camera_depth_snapshot(msg: Empty) -> Image:
    """Capture one depth image from the MuJoCo camera. Depth is in meters,
    normalized to grayscale JPEG for transport. Use to gauge distance
    to objects on the table.
    Contract: robonix/primitive/camera/depth_snapshot."""
    _ = msg
    obs = _get_camera_obs()
    cam_key = os.environ.get("MUJOCO_SIM_CAMERA", "agentview")
    depth_key = f"{cam_key}_depth"
    if depth_key not in obs:
        for k in obs:
            if "depth" in k:
                depth_key = k
                break
    arr = obs[depth_key]
    jpg = _array_to_jpeg(arr, is_depth=True)
    return _jpeg_to_image_mcp(jpg, "mujoco_camera_depth")


# ── MCP 工具：激光雷达模拟 ─────────────────────────────────────────────────
@mujoco_sim.mcp("robonix/primitive/lidar/snapshot")
def lidar_snapshot(msg: Empty) -> Any:
    """Simulated 2D laser scan of the table surface. Casts rays in the
    horizontal plane from the arm base and returns distances.
    Returns sensor_msgs/LaserScan. Useful for detecting table edges
    and object silhouettes.
    Contract: robonix/primitive/lidar/snapshot."""
    _ = msg
    from sensor_msgs_mcp import LaserScan

    env = _ensure_env()
    # Simple simulated scan: sample the depth image's middle row
    obs = _get_camera_obs()
    cam_key = os.environ.get("MUJOCO_SIM_CAMERA", "agentview")
    depth_key = f"{cam_key}_depth"
    if depth_key not in obs:
        for k in obs:
            if "depth" in k:
                depth_key = k
                break

    depth = obs[depth_key]
    h = depth.shape[0]
    mid_row = depth[h // 2]  # middle row = roughly table plane
    valid = np.isfinite(mid_row) & (mid_row > 0)
    ranges = []
    for v in mid_row:
        if np.isfinite(v) and v > 0:
            ranges.append(float(v))
        else:
            ranges.append(float("inf"))

    n = len(ranges)
    return LaserScan(
        header=_now_header("mujoco_lidar"),
        angle_min=-math.pi / 2,
        angle_max=math.pi / 2,
        angle_increment=math.pi / max(n - 1, 1),
        time_increment=0.0,
        scan_time=0.1,
        range_min=0.1,
        range_max=5.0,
        ranges=ranges,
        intensities=[],
    )


# ── MCP 工具：机械臂控制 ───────────────────────────────────────────────────
@mujoco_sim.mcp("mujoco_sim/arm/control")
def arm_control(msg: Any) -> Any:
    """Control the Franka arm. Specify a target end-effector position
    [x, y, z] (in world frame, meters) and gripper action.

    Parameters (pass as JSON in the request):
      x, y, z: target end-effector position (default: current)
      grip: gripper action, -1 (close) to +1 (open) (default: 0 = hold)
      steps: number of sim steps to execute (default: 20)
      threshold: position convergence threshold in meters (default: 0.02)

    Returns JSON ack with final ee position and success status.
    Contract: mujoco_sim/arm/control."""
    import json as _json

    env = _ensure_env()
    # Parse target from msg (MCP dataclass or dict)
    target_x = float(getattr(msg, "x", 0.0))
    target_y = float(getattr(msg, "y", 0.0))
    target_z = float(getattr(msg, "z", 0.0))
    grip = float(getattr(msg, "grip", 0.0))
    steps = int(getattr(msg, "steps", 20))
    threshold = float(getattr(msg, "threshold", 0.02))

    action = np.zeros(env.action_dim)
    # OSC_POSE: first 3 = delta xyz, next 3 = delta rotation, last 1 = gripper
    if env.action_dim >= 7:
        # compute delta from current to target
        obs = env._get_observations()
        ee_pos = obs.get("robot0_eef_pos", np.zeros(3))
        delta = np.array([target_x, target_y, target_z]) - ee_pos
        # clip delta to reasonable range
        delta = np.clip(delta, -0.1, 0.1)
        action[:3] = delta
        action[6] = grip
    elif env.action_dim >= 4:
        # simpler arm: 3 position + 1 gripper
        action[0] = target_x
        action[1] = target_y
        action[2] = target_z
        action[3] = grip

    with _sim_lock:
        for _ in range(steps):
            obs, _, done, info = env.step(action)
            # check convergence
            ee_pos = obs.get("robot0_eef_pos", None)
            if ee_pos is not None:
                dist = np.linalg.norm(ee_pos - np.array([target_x, target_y, target_z]))
                if dist < threshold:
                    break

    ee_pos = obs.get("robot0_eef_pos", [0, 0, 0])
    result = {
        "status": "done",
        "ee_pos": [float(ee_pos[0]), float(ee_pos[1]), float(ee_pos[2])],
        "grip": grip,
        "steps_executed": steps,
    }
    # Return as string ack (MCP tools return dataclass or simple type)
    from std_msgs_mcp import String
    return String(data=_json.dumps(result))


@mujoco_sim.mcp("mujoco_sim/arm/get_state")
def arm_get_state(msg: Empty) -> Any:
    """Get current arm state: joint positions, end-effector position,
    and gripper state.
    Contract: mujoco_sim/arm/get_state."""
    _ = msg
    env = _ensure_env()
    with _sim_lock:
        obs = env._get_observations()

    import json as _json
    from std_msgs_mcp import String

    joint_pos = obs.get("robot0_joint_pos", [])
    ee_pos = obs.get("robot0_eef_pos", [0, 0, 0])
    ee_quat = obs.get("robot0_eef_quat", [1, 0, 0, 0])
    gripper_qpos = obs.get("robot0_gripper_qpos", [0, 0])

    result = {
        "joint_pos": [float(x) for x in joint_pos],
        "ee_pos": [float(x) for x in ee_pos],
        "ee_quat": [float(x) for x in ee_quat],
        "gripper_qpos": [float(x) for x in gripper_qpos],
        "gripper_open": float(abs(gripper_qpos[0] - gripper_qpos[1])) > 0.01 if len(gripper_qpos) >= 2 else False,
    }
    return String(data=_json.dumps(result))


# ── MCP 工具：场景控制 ─────────────────────────────────────────────────────
@mujoco_sim.mcp("mujoco_sim/scene/reset")
def scene_reset(msg: Empty) -> Any:
    """Reset the MuJoCo simulation to initial state. Objects return to
    their spawn positions, arm goes to home pose.
    Contract: mujoco_sim/scene/reset."""
    _ = msg
    env = _ensure_env()
    with _sim_lock:
        obs = env.reset()
    from std_msgs_mcp import String
    import json as _json
    return String(data=_json.dumps({"status": "reset", "objects": list(obs.keys())}))


@mujoco_sim.mcp("mujoco_sim/scene/step")
def scene_step(msg: Any) -> Any:
    """Step the simulation N frames with zero action (hold position).
    Useful for letting physics settle after an action.
    Parameter: steps (int, default 5).
    Contract: mujoco_sim/scene/step."""
    steps = int(getattr(msg, "steps", 5))
    env = _ensure_env()
    with _sim_lock:
        for _ in range(steps):
            obs, _, _, _ = env.step(np.zeros(env.action_dim))
    from std_msgs_mcp import String
    import json as _json
    return String(data=_json.dumps({"status": "stepped", "steps": steps}))


# ── MCP 工具：物体查询 ─────────────────────────────────────────────────────
@mujoco_sim.mcp("mujoco_sim/object/list")
def object_list(msg: Empty) -> Any:
    """List all objects in the MuJoCo scene (cube, table, etc.).
    Contract: mujoco_sim/object/list."""
    _ = msg
    env = _ensure_env()
    with _sim_lock:
        obs = env._get_observations()

    objects = []
    # robosuite puts object info in obs with specific keys
    for key in obs:
        if key.endswith("_pos") and not key.startswith("robot"):
            name = key.replace("_pos", "")
            objects.append(name)
        elif key == "object":
            objects.append("object")

    # Also check the sim model for named bodies
    if hasattr(env, "sim") and hasattr(env.sim, "model"):
        model = env.sim.model
        for i in range(model.nbody):
            name = model.body(i).name
            if name and not name.startswith("world") and not name.startswith("robot0"):
                if name not in objects:
                    objects.append(name)

    from std_msgs_mcp import String
    import json as _json
    return String(data=_json.dumps({"objects": objects}))


@mujoco_sim.mcp("mujoco_sim/object/pose")
def object_pose(msg: Any) -> Any:
    """Get the 3D position and rotation of a named object in the scene.
    Parameter: name (str) — object name from object_list.
    Returns JSON with position [x,y,z] and rotation [w,x,y,z].
    Contract: mujoco_sim/object/pose."""
    name = str(getattr(msg, "name", "object"))
    env = _ensure_env()
    with _sim_lock:
        obs = env._get_observations()

    import json as _json
    from std_msgs_mcp import String

    pos = None
    quat = None

    # Try obs keys
    pos_key = f"{name}_pos"
    quat_key = f"{name}_quat"
    if pos_key in obs:
        pos = obs[pos_key]
    if quat_key in obs:
        quat = obs[quat_key]

    # Fallback: query MuJoCo sim directly
    if pos is None and hasattr(env, "sim"):
        model = env.sim.model
        for i in range(model.nbody):
            if model.body(i).name == name:
                pos = env.sim.data.body(i).xpos.copy()
                quat = env.sim.data.body(i).xquat.copy()
                break

    if pos is None:
        return String(data=_json.dumps({"error": f"object '{name}' not found"}))

    result = {
        "name": name,
        "position": [float(pos[0]), float(pos[1]), float(pos[2])],
        "rotation": [float(quat[0]), float(quat[1]), float(quat[2]), float(quat[3])] if quat is not None else None,
    }
    return String(data=_json.dumps(result))


# ── 生命周期 ────────────────────────────────────────────────────────────────
@mujoco_sim.on_init
def init(cfg):
    """Initialize MuJoCo environment. Called by rbnx boot after registration."""
    cfg = cfg or {}
    # Override env from config if provided
    if cfg.get("env"):
        os.environ["MUJOCO_SIM_ENV"] = cfg["env"]
    if cfg.get("robot"):
        os.environ["MUJOCO_SIM_ROBOT"] = cfg["robot"]

    try:
        _ensure_env()
        print("[mujoco_sim] environment initialized successfully", flush=True)
        return Ok()
    except Exception as e:
        print(f"[mujoco_sim] init failed: {e}", flush=True)
        return Err(f"MuJoCo env init failed: {e}")


@mujoco_sim.on_shutdown
def shutdown():
    global _env
    if _env is not None:
        try:
            _env.close()
        except Exception:
            pass
        _env = None
    print("[mujoco_sim] shutdown", flush=True)
    return Ok()


if __name__ == "__main__":
    mujoco_sim.run()
