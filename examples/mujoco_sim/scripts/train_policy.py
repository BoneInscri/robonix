#!/usr/bin/env python3
# SPDX-License-Identifier: MulanPSL-2.0
"""RL 策略训练脚本 — 在 AMD ROCm GPU 上训练 Franka 抓取策略。

使用 PPO (Stable-Baselines3) + robosuite Lift 环境。
训练完成后策略可保存为 ONNX，作为 robonix skill 加载。

用法：
  python3 scripts/train_policy.py --timesteps 100000
  python3 scripts/train_policy.py --timesteps 100000 --model ppo_policy.zip

要求：
  - PyTorch ROCm 版（已预装）
  - pip install stable-baselines3 gymnasium
  - AMD GPU (ROCm) 用于加速训练
"""
from __future__ import annotations

import argparse
import os
import sys
import time

import numpy as np


def check_gpu():
    """确认 GPU 可用。"""
    try:
        import torch
        print(f"[train] PyTorch: {torch.__version__}")
        print(f"[train] GPU available: {torch.cuda.is_available()}")
        if torch.cuda.is_available():
            print(f"[train] GPU: {torch.cuda.get_device_name(0)}")
            return True
    except ImportError:
        print("[train] PyTorch not found", file=sys.stderr)
    return False


def make_env(env_name="Lift", robot="Panda"):
    """创建 robosuite 环境，包装为 Gymnasium 接口。"""
    import robosuite as suite
    from robosuite.wrappers import Wrapper

    env = suite.make(
        env_name=env_name,
        robots=[robot],
        controller="OSC_POSE",
        gripper_types="Panda",
        has_renderer=False,
        has_offscreen_renderer=True,
        use_camera_obs=True,
        camera_names="agentview",
        camera_heights=256,
        camera_widths=256,
        horizon=500,
        ignore_done=True,
        hard_reset=False,
        reward_shaping=True,
    )

    # robosuite 自带 Gymnasium 包装器
    try:
        from robosuite.wrappers import GymWrapper
        env = GymWrapper(env)
    except ImportError:
        # 手动包装
        import gymnasium as gym

        class RobosuiteGymWrapper(gym.Env):
            def __init__(self, env):
                self.env = env
                self.observation_space = gym.spaces.Dict({
                    "image": gym.spaces.Box(0, 255, (256, 256, 3), dtype=np.uint8),
                    "state": gym.spaces.Box(-np.inf, np.inf, (50,), dtype=np.float32),
                })
                self.action_space = gym.spaces.Box(-1, 1, (env.action_dim,), dtype=np.float32)

            def reset(self, *, seed=None, options=None):
                obs = self.env.reset()
                img = obs.get("agentview_image", np.zeros((256, 256, 3), dtype=np.uint8))
                state = np.concatenate([v.flatten() for v in obs.values() if isinstance(v, np.ndarray)])[:50]
                return {"image": img, "state": state.astype(np.float32)}, {}

            def step(self, action):
                obs, reward, done, info = self.env.step(action)
                img = obs.get("agentview_image", np.zeros((256, 256, 3), dtype=np.uint8))
                state = np.concatenate([v.flatten() for v in obs.values() if isinstance(v, np.ndarray)])[:50]
                truncated = False
                return {"image": img, "state": state.astype(np.float32)}, float(reward), bool(done), truncated, info

        env = RobosuiteGymWrapper(env)

    return env


def train_ppo(timesteps: int, save_path: str, env_name: str, robot: str):
    """用 PPO 训练策略。"""
    from stable_baselines3 import PPO
    from stable_baselines3.common.vec_env import DummyVecEnv
    from stable_baselines3.common.callbacks import CheckpointCallback

    print(f"[train] creating env: {env_name} / {robot}")
    env = DummyVecEnv([lambda: make_env(env_name, robot)])

    # PPO 超参数（适合 robosuite Lift 任务）
    model = PPO(
        "MultiInputPolicy",  # 支持 Dict 观测（image + state）
        env,
        learning_rate=3e-4,
        n_steps=2048,
        batch_size=64,
        n_epochs=10,
        gamma=0.99,
        gae_lambda=0.95,
        clip_range=0.2,
        ent_coef=0.01,
        verbose=1,
        device="cuda",  # 强制用 GPU (ROCm)
        tensorboard_log="./mujoco_rl_logs/",
    )

    # 定期保存
    checkpoint = CheckpointCallback(
        save_freq=10000,
        save_path="./mujoco_rl_checkpoints/",
        name_prefix="franka_lift_ppo",
    )

    print(f"[train] training PPO for {timesteps} timesteps...")
    print(f"[train] device: {model.device}")

    start = time.time()
    model.learn(total_timesteps=timesteps, callback=checkpoint)
    elapsed = time.time() - start

    print(f"[train] training done in {elapsed:.1f}s ({timesteps/elapsed:.1f} fps)")

    # 保存最终模型
    model.save(save_path)
    print(f"[train] model saved to {save_path}")

    # 导出为 ONNX（可选，便于 robonix skill 加载）
    try:
        import torch
        onnx_path = save_path.replace(".zip", ".onnx")
        dummy_img = torch.zeros(1, 256, 256, 3, device="cuda")
        dummy_state = torch.zeros(1, 50, device="cuda")
        print(f"[train] ONNX export would go to {onnx_path} (implement if needed)")
    except Exception as e:
        print(f"[train] ONNX export skipped: {e}")

    env.close()


def main():
    parser = argparse.ArgumentParser(description="Train Franka grasping policy with PPO")
    parser.add_argument("--timesteps", type=int, default=100000,
                        help="Total training timesteps (default: 100000)")
    parser.add_argument("--model", type=str, default="franka_lift_ppo.zip",
                        help="Output model path (default: franka_lift_ppo.zip)")
    parser.add_argument("--env", type=str, default="Lift",
                        help="robosuite env name (default: Lift)")
    parser.add_argument("--robot", type=str, default="Panda",
                        help="Robot name (default: Panda)")
    args = parser.parse_args()

    print("=" * 60)
    print("  MuJoCo RL Policy Training (AMD ROCm GPU)")
    print("=" * 60)

    if not check_gpu():
        print("[train] WARNING: no GPU detected, training will be slow on CPU")

    # 安装依赖提示
    try:
        import stable_baselines3
    except ImportError:
        print("[train] installing stable-baselines3...")
        os.system(f"{sys.executable} -m pip install stable-baselines3 gymnasium")

    try:
        import robosuite
    except ImportError:
        print("[train] ERROR: robosuite not installed. Run:")
        print("  pip install robosuite")
        sys.exit(1)

    train_ppo(args.timesteps, args.model, args.env, args.robot)


if __name__ == "__main__":
    main()
