---
description: MuJoCo Franka arm simulation — camera, lidar, arm control, and scene query tools for grasping tasks.
---

# MuJoCo Sim (`mujoco_sim`)

A simulated Franka Panda arm on a table with objects (robosuite Lift task).
No ROS2 — all tools are direct MCP calls to the in-process MuJoCo simulator.

## Tools

### `camera_snapshot` — `robonix/primitive/camera/snapshot`
- input: none
- returns: `sensor_msgs/Image` (JPEG-encoded RGB from agentview camera).
- Use this to see the workspace: table surface, objects, gripper position.

### `camera_depth_snapshot` — `robonix/primitive/camera/depth_snapshot`
- input: none
- returns: depth image (meters, normalized to grayscale JPEG).
- Use to gauge distance to objects.

### `lidar_snapshot` — `robonix/primitive/lidar/snapshot`
- input: none
- returns: `sensor_msgs/LaserScan` (simulated horizontal plane scan).
- Use to detect table edges and object silhouettes.

### `arm_control` — `mujoco_sim/arm/control`
- input: `x, y, z` (target end-effector position in meters), `grip` (-1 close to +1 open), `steps` (default 20)
- returns: JSON `{status, ee_pos, grip, steps_executed}`
- The arm uses OSC (Operational Space Control). Specify where you want the
  gripper to go, then close the gripper to grasp.

### `arm_get_state` — `mujoco_sim/arm/get_state`
- input: none
- returns: JSON `{joint_pos, ee_pos, ee_quat, gripper_qpos, gripper_open}`
- Call before and after arm_control to verify position.

### `scene_reset` — `mujoco_sim/scene/reset`
- input: none
- returns: JSON `{status: "reset"}`
- Resets all objects to initial positions. Call if the scene gets messy.

### `scene_step` — `mujoco_sim/scene/step`
- input: `steps` (int, default 5)
- returns: JSON `{status: "stepped", steps: N}`
- Advance simulation with zero action (let physics settle).

### `object_list` — `mujoco_sim/object/list`
- input: none
- returns: JSON `{objects: ["cube", "table", ...]}`

### `object_pose` — `mujoco_sim/object/pose`
- input: `name` (string, from object_list)
- returns: JSON `{name, position: [x,y,z], rotation: [w,x,y,z]}`

## Reasoning loop for grasping

1. `camera_snapshot` — see the scene
2. `object_list` + `object_pose` — find target object position
3. `arm_get_state` — check current arm position
4. `arm_control` — move gripper above object (z + 0.1m)
5. `camera_snapshot` — verify alignment
6. `arm_control` — lower to object (target z)
7. `arm_control` — close gripper (grip = -1)
8. `arm_control` — lift (z + 0.2m)
9. `camera_snapshot` — confirm object is grasped
