# Robonix 本地构建与启动教程（无 Docker）

> 本文档介绍如何在**不使用 Docker** 的情况下，在云服务器容器内原生构建并运行 Robonix 的 Webots Tiago 仿真示例。

---

## 0. 目标环境

本教程基于以下实际云服务器环境编写：

| 项目 | 实际值 |
|------|--------|
| 操作系统 | Ubuntu 24.04.4 LTS (Noble Numbat) |
| 架构 | x86_64 |
| CPU | AMD EPYC 9334 32-Core (64 CU) |
| GPU | AMD Radeon Graphics (gfx1100, Device 744b) |
| VRAM | ~48 GB (51,522,830,336 bytes) |
| ROCm | 7.2.1 (`/opt/rocm` + `/opt/rocm-7.2.1`) |
| PyTorch | 2.9.1+gitff65f5b (ROCm 版，GPU 可用) |
| 用户 | root（容器内） |
| Docker | 不可用（容器内环境） |
| 内核 | 6.8.0-79-generic |

**关键适配**：
- Ubuntu 24.04 → ROS2 **Jazzy**（不是 Humble，Humble 仅支持 22.04）
- 已有 ROCm + PyTorch → 跳过 PyTorch 安装，直接装 vLLM
- root 用户 → 不使用 sudo
- 无 Docker → 全部原生构建

---

## 1. 环境检查

```bash
# 确认 OS
cat /etc/os-release | head -5
# PRETTY_NAME="Ubuntu 24.04.4 LTS"
# VERSION_ID="24.04"

# 确认 ROCm
ls -d /opt/rocm*
cat /opt/rocm/.info/version
# 7.2.1

# 确认 GPU
/opt/rocm/bin/rocm-smi
# Device 0, gfx1100, ~48GB VRAM

# 确认 PyTorch
python3 -c "import torch; print(torch.__version__, torch.cuda.is_available())"
# 2.9.1+gitff65f5b True

# 确认 /dev/kfd 和 /dev/dri
ls -la /dev/kfd /dev/dri/
# /dev/kfd ✅
# /dev/dri/card1 ✅
# /dev/dri/renderD128 ✅
```

---

## 2. 一键安装（推荐）

仓库内已提供自动化安装脚本，已针对本服务器环境适配。

```bash
cd /path/to/robonix

# 先检查环境（不安装任何东西）
./scripts/setup_native_env.sh --check

# 完整安装
./scripts/setup_native_env.sh

# 如果环境已装好，只改造 driver 脚本
./scripts/setup_native_env.sh --patch-only

# 额外安装本地 vLLM VLM 服务（利用 48GB VRAM）
./scripts/setup_native_env.sh --with-vlm
```

脚本会自动处理：
- Ubuntu 24.04 → ROS2 Jazzy（不是 Humble）
- root 用户 → 去掉 sudo
- ROCm 环境变量 → 写入 `/etc/profile.d/rocm-env.sh`
- gfx1100 → 设置 `HSA_OVERRIDE_GFX_VERSION=11.0.0`
- driver 脚本 → `docker exec` 改为原生运行

---

## 3. 手动安装系统依赖

> 如果用了第 2 节的一键脚本，可跳到第 6 节。

### 3.1 基础工具

```bash
# root 用户不需要 sudo，非 root 请加 sudo
apt-get update
apt-get install -y \
    curl wget gnupg2 lsb-release ca-certificates \
    build-essential cmake git unzip \
    python3 python3-pip python3-dev python3-venv \
    locales locale-gen \
    xvfb xserver-xorg-core mesa-utils \
    libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev \
    libosmesa6 libglu1-mesa libglfw3 libglfw3-dev \
    libxcb-cursor0 pciutils \
    bash-completion fonts-lmodern \
    alsa-utils software-properties-common

# ROS2 需要 en_US.UTF-8
locale-gen en_US en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
```

### 3.2 安装 ROS2 Jazzy

> **重要**：Ubuntu 24.04 对应 ROS2 Jazzy，不是 Humble。Humble 仅支持 Ubuntu 22.04。

```bash
# 添加 ROS2 仓库
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
    | tee /etc/apt/sources.list.d/ros2.list

# 国内网络换 TUNA 镜像（可选）
sed -i 's|http://packages.ros.org/ros2/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu|g' \
    /etc/apt/sources.list.d/ros2.list

apt-get update
apt-get install -y ros-jazzy-desktop-full
```

### 3.3 安装 ROS2 补充包

```bash
apt-get install -y \
    ros-jazzy-rmw-zenoh-cpp \
    ros-jazzy-rmw-fastrtps-cpp \
    ros-jazzy-nav2-msgs \
    ros-jazzy-nav2-bringup \
    ros-jazzy-webots-ros2 \
    ros-jazzy-webots-ros2-driver \
    ros-jazzy-controller-manager \
    ros-jazzy-diagnostic-updater \
    ros-jazzy-diff-drive-controller \
    ros-jazzy-joint-state-broadcaster \
    ros-jazzy-robot-state-publisher \
    ros-jazzy-tf2-ros \
    ros-jazzy-rviz2 \
    ros-jazzy-test-msgs \
    python3-colcon-common-extensions
```

### 3.4 安装 Webots 仿真器

```bash
# 下载 Webots R2025a（国内用 ghfast.top 镜像加速）
wget -O /tmp/webots.deb \
    "https://ghfast.top/https://github.com/cyberbotics/webots/releases/download/R2025a/webots_2025a_amd64.deb"

apt-get install -y /tmp/webots.deb || {
    dpkg -i /tmp/webots.deb || true
    apt-get install -f -y
}
rm /tmp/webots.deb

# 验证
webots --version
```

### 3.5 安装 Python 驱动依赖

```bash
# Ubuntu 24.04 的 Python 3.12 需要 --break-system-packages
pip3 install --no-cache-dir --break-system-packages \
    "grpcio>=1.78.0" "protobuf>=6.30,<7" mcp "fastmcp>=3" \
    numpy Pillow uvicorn httpx
```

### 3.6 设置 ROCm 环境变量

机器上已有 ROCm 7.2.1 + PyTorch 2.9.1，只需设置环境变量：

```bash
cat > /etc/profile.d/rocm-env.sh <<'EOF'
# ROCm environment
export ROCM_HOME=/opt/rocm
export PATH=$ROCM_HOME/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_HOME/lib:${LD_LIBRARY_PATH:-}
export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-0}
export ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-0}
# gfx1100 需要此变量确保 PyTorch/vLLM 兼容
export HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-11.0.0}
EOF
chmod +x /etc/profile.d/rocm-env.sh
source /etc/profile.d/rocm-env.sh

# 验证
python3 -c "import torch; print('GPU:', torch.cuda.get_device_name(0))"
# GPU: AMD Radeon Graphics
```

---

## 4. 安装 Rust + uv 工具链

### 4.1 Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
rustc --version
```

### 4.2 uv（Python 包管理器）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv --version
```

---

## 5. 构建 Robonix

### 5.1 编译 + 安装 Rust 系统组件

```bash
cd /path/to/robonix
make install
```

安装到 `~/.cargo/bin` 的二进制：
- `rbnx` — 命令行工具
- `robonix-atlas` / `robonix-pilot` / `robonix-executor` / `robonix-liaison` / `robonix-soma` / `robonix-vitals`
- `robonix-codegen`

验证：

```bash
rbnx --version
```

### 5.2 注册仓库源

```bash
rbnx setup /path/to/robonix
```

### 5.3 同步 Python 工作区

```bash
cd /path/to/robonix
uv sync
```

### 5.4 构建 eaios_webots（Webots ROS2 包）

```bash
cd /path/to/robonix/examples/webots/sim/ros_ws
source /opt/ros/jazzy/setup.bash    # 注意是 jazzy，不是 humble
colcon build --symlink-install --packages-select eaios_webots
```

### 5.5 构建 driver 包的 codegen

```bash
cd /path/to/robonix/examples/webots
source /opt/ros/jazzy/setup.bash
source ~/.cargo/env

for pkg in primitives/tiago_chassis primitives/tiago_camera primitives/tiago_lidar; do
    echo "=== 构建 $pkg ==="
    rbnx codegen -p "$pkg" --mcp --ros2
    IDL_DIR="$pkg/rbnx-build/codegen/ros2_idl"
    if [ -d "$IDL_DIR" ]; then
        (cd "$IDL_DIR" && colcon build)
    fi
done
```

---

## 6. 改造 driver 脚本（docker exec → 原生运行）

> 一键脚本已自动完成此步骤。如需手动，运行 `./scripts/setup_native_env.sh --patch-only`。

Robonix 的 driver 包默认通过 `docker exec` 进入 Webots 容器运行。原生模式下改为直接运行。

### 改造内容

| 文件 | 改造 |
|------|------|
| `primitives/tiago_chassis/scripts/start.sh` | `docker exec` → 直接 `python3 -m chassis_driver.driver` |
| `primitives/tiago_chassis/scripts/build.sh` | `docker exec ... colcon` → 直接 `colcon build` |
| `primitives/tiago_chassis/package_manifest.yaml` | stop 段去掉 `docker exec "$SIM_CT"` |
| `primitives/tiago_camera/scripts/*.sh` | 同上，加上静态 TF 发布器 |
| `primitives/tiago_lidar/scripts/*.sh` | 同上，加上 `scan_normalize.py` |

改造后的 `start.sh` 模板（以 tiago_chassis 为例）：

```bash
#!/usr/bin/env bash
set -euo pipefail

source /opt/ros/jazzy/setup.bash 2>/dev/null || true  # jazzy 不是 humble

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OVL="$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
[ -f "$OVL" ] && source "$OVL" 2>/dev/null || true

export ROBONIX_ATLAS="${ROBONIX_ATLAS:-127.0.0.1:50051}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export PYTHONPATH="$(rbnx path robonix-api):$PKG_DIR/rbnx-build/codegen/proto_gen:${PYTHONPATH:-}"

cd "$PKG_DIR"
exec python3 -m chassis_driver.driver
```

---

## 7. 启动运行

需要**两到三个终端**。

### 7.1 终端 1：启动 Webots 仿真

云服务器无物理显示器，使用**无头流式模式**，通过浏览器查看 3D 仿真：

```bash
cd /path/to/robonix

# 方式 A：用生成的脚本（推荐，自动处理 AMD GPU Xorg 加速）
WEBOTS_STREAM=1 bash scripts/native/start_sim.sh

# 方式 B：手动启动
source /etc/profile.d/rocm-env.sh
source /opt/ros/jazzy/setup.bash
source examples/webots/sim/ros_ws/install/setup.bash

# 启动 Xvfb 虚拟显示（或用 AMD GPU 加速的 Xorg :48）
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
export DISPLAY=:99
sleep 1

# 启动 Zenoh router
/opt/ros/jazzy/lib/rmw_zenoh_cpp/rmw_zenohd &
sleep 2

# 启动 Webots viewer HTTP 服务（端口 8080）
WEBOTS_VIEWER_DIR="/usr/local/webots/resources/web/streaming_viewer"
(cd "$WEBOTS_VIEWER_DIR" && python3 -m http.server 8080 --bind 0.0.0.0) &

# 启动仿真
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROBONIX_WEBOTS_WORLD=office.wbt
export WEBOTS_STREAM=1
ros2 launch eaios_webots robot_launch.py \
    use_sim_time:=true \
    world:=office.wbt \
    robot:=tiago_webots.urdf
```

然后在**本地电脑浏览器**打开：

```
http://<服务器IP>:8080/
```

点击 Connect 查看 Webots 3D 仿真画面。

> **端口放通**：确保服务器防火墙放通 `8080`（viewer 网页）和 `1234`（WS 流）。

**AMD GPU 加速 Xorg（可选，比 Xvfb 快很多）**：

`start_sim.sh` 会自动尝试用 AMD GPU 启动 Xorg :48（`modesetting` 驱动 + `kmsdev`）。如果成功，Webots 3D 渲染走 GPU 而非 CPU 软渲染，速度提升 10-100 倍。

> **重要**：`WEBOTS_STREAM=1` 流式模式下**必须**用 GPU Xorg，不能用 Xvfb。Xvfb 不支持 Webots stream 模式需要的 OpenGL 上下文，会导致世界永远加载不完（`/tmp/webots/.../loading` 文件不删除，controller 连接超时）。脚本会自动检测 `/dev/dri/card*` 并启动 Xorg :48。

### 7.2 终端 2（可选）：启动本地 VLM

利用 48GB VRAM 的 AMD GPU 跑本地 VLM，不依赖远程 API：

```bash
cd /path/to/robonix

# 如果还没装 vLLM，先装
./scripts/setup_native_env.sh --with-vlm

# 启动 VLM 服务
bash scripts/native/start_vlm.sh
# 等待 30-90 秒模型加载
# 服务就绪后监听 http://127.0.0.1:8000/v1
```

或手动启动：

```bash
source /etc/profile.d/rocm-env.sh
export HF_ENDPOINT=https://hf-mirror.com

python3 -m vllm.entrypoints.openai.api_server \
    --host 0.0.0.0 --port 8000 \
    --model Qwen/Qwen2.5-VL-7B-Instruct \
    --served-model-name Qwen/Qwen2.5-VL-7B-Instruct \
    --trust-remote-code \
    --dtype bfloat16 \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.85
```

> 48GB VRAM 足够跑 7B 模型（需要 ~14GB），还可以跑更大的 72B 模型（需要 ~145GB，需要 MI300X）。

### 7.3 终端 3：启动 Robonix

等待终端 1 的 Webots 出现 ROS2 话题后（`ros2 topic list` 能看到 `/scanner`、`/odom` 等）：

```bash
cd /path/to/robonix

source /etc/profile.d/rocm-env.sh
source /opt/ros/jazzy/setup.bash
source ~/.cargo/env
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# VLM 设置（二选一）

# 选项 1：本地 vLLM（如果终端 2 已启动）
export VLM_BASE_URL=http://127.0.0.1:8000/v1
export VLM_API_KEY=dummy-key
export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct

# 选项 2：远程 OpenAI 兼容 API
# export VLM_BASE_URL=https://api.openai.com/v1
# export VLM_API_KEY=sk-你的key
# export VLM_MODEL=gpt-5.5

# scene 包用 Jazzy 构建（适配 Ubuntu 24.04）
export ROBONIX_SCENE_ROS_DISTRO=jazzy

# 场景地图 ID
export SCENE_MAP_ID=webots_lab

# 启动
cd examples/webots
rbnx boot
```

或用生成的脚本：

```bash
export VLM_BASE_URL=http://127.0.0.1:8000/v1
export VLM_API_KEY=dummy-key
export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct
bash scripts/native/start_robonix.sh
```

### 7.4 终端 4：交互

```bash
rbnx caps    # 查看已注册的能力和接口
rbnx chat    # 与 pilot 对话（TUI 界面）
```

### 7.5 停止

```bash
bash scripts/native/stop_all.sh
```

---

## 8. 可选世界（仿真场景）

```bash
export ROBONIX_WEBOTS_WORLD=office.wbt          # 默认，办公室（推荐首次使用）
export ROBONIX_WEBOTS_WORLD=apartment.wbt        # 公寓
export ROBONIX_WEBOTS_WORLD=complete_apartment.wbt
export ROBONIX_WEBOTS_WORLD=break_room.wbt
export ROBONIX_WEBOTS_WORLD=kitchen.wbt
```

非 `office.wbt` 的世界首次使用需要下载 Webots 官方离线资源包：

```bash
export ROBONIX_WEBOTS_DOWNLOAD_ALL_ASSETS=1
```

---

## 9. 常见问题

### Q1：`rbnx: command not found`

```bash
source ~/.cargo/env
export PATH="$HOME/.cargo/bin:$PATH"
```

### Q2：Webots 启动报 `cannot connect to X server`

云服务器无物理显示器。用流式模式：

```bash
WEBOTS_STREAM=1 bash scripts/native/start_sim.sh
```

脚本会自动启动 Xvfb 或 AMD GPU Xorg。

### Q3：Webots 3D 渲染太慢

检查是否用了 AMD GPU Xorg 加速（而非 Xvfb 软渲染）：

```bash
# 查看启动日志
cat /tmp/Xorg.48.log | tail -5
# 如果有 "AMD" 字样说明 GPU 加速成功

# 或检查渲染器
DISPLAY=:48 glxinfo -B | grep "OpenGL renderer"
# 应该显示 "AMD Radeon..."，如果显示 "llvmpipe" 则是软渲染
```

如果 GPU 加速失败，确保：
- `/dev/dri/card1` 和 `/dev/dri/renderD128` 存在
- `amdgpu` 内核模块已加载（`lsmod | grep amdgpu`）
- Xorg 用 `modesetting` 驱动（系统通常没装 `amdgpu` Xorg 驱动，`start_sim.sh` 已自动用 `modesetting` + `kmsdev`）
- 检查 `/tmp/Xorg.48.log` 是否有 `no screens found` 错误

### Q4：`ros2 topic list` 为空

Zenoh router 没启动：

```bash
/opt/ros/jazzy/lib/rmw_zenoh_cpp/rmw_zenohd &
sleep 2
ros2 topic list
```

或切换到 FastRTPS：

```bash
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
```

### Q5：PyTorch 报 GPU 相关错误

```bash
# 确认环境变量
source /etc/profile.d/rocm-env.sh

# 确认 HSA_OVERRIDE_GFX_VERSION
echo $HSA_OVERRIDE_GFX_VERSION
# 应该是 11.0.0

# 测试 GPU
python3 -c "import torch; x = torch.randn(100,100, device='cuda'); print('OK', torch.mm(x,x).sum())"
```

### Q6：vLLM 启动失败

```bash
# 确认 vLLM 是 ROCm 版（不是 CUDA 版）
python3 -c "import vllm; print(vllm.__version__)"

# 如果装了 CUDA 版，卸载重装
pip3 uninstall vllm -y
pip3 install --no-cache-dir --break-system-packages \
    "vllm==0.18.0+rocm700" \
    --extra-index-url "https://wheels.vllm.ai/rocm/0.18.0/rocm700"
```

### Q7：`rbnx boot` 时 mapping/nav2 克隆失败

网络问题。手动克隆：

```bash
cd /path/to/robonix/examples/webots/rbnx-boot/cache/
git clone https://github.com/syswonder/service-map-rbnx mapping_rbnx
git clone https://github.com/syswonder/service-navigation-rbnx nav2_rbnx
git clone https://github.com/syswonder/skill-explore-rbnx explore_rbnx
```

### Q8：ROS2 包找不到

确保 source 了 Jazzy 环境（不是 Humble）：

```bash
source /opt/ros/jazzy/setup.bash
echo $ROS_DISTRO   # 应该输出 jazzy
```

### Q9：scene 包构建报 ROS distro 错误

```bash
export ROBONIX_SCENE_ROS_DISTRO=jazzy
rbnx build -p system/scene
```

---

## 10. 文件速查

| 文件 | 作用 |
|------|------|
| `scripts/setup_native_env.sh` | 一键安装脚本（已适配 Ubuntu 24.04 + ROCm） |
| `scripts/native/start_sim.sh` | 启动 Webots 仿真（支持 AMD GPU Xorg 加速） |
| `scripts/native/start_robonix.sh` | 启动 Robonix 栈 |
| `scripts/native/build_drivers.sh` | 构建所有 driver 包 |
| `scripts/native/start_vlm.sh` | 启动本地 vLLM VLM 服务 |
| `scripts/native/stop_all.sh` | 停止所有进程 |
| `/etc/profile.d/rocm-env.sh` | ROCm 环境变量（脚本自动创建） |
| `examples/webots/robonix_manifest.yaml` | 部署清单 |
| `examples/webots/sim/ros_ws/src/eaios_webots/` | Webots ROS2 包源码 |

---

## 11. 环境变量速查

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ROS_DISTRO` | `jazzy` | ROS2 发行版（Ubuntu 24.04 用 Jazzy） |
| `RMW_IMPLEMENTATION` | `rmw_zenoh_cpp` | ROS2 中间件 |
| `ROCM_HOME` | `/opt/rocm` | ROCm 安装路径 |
| `HSA_OVERRIDE_GFX_VERSION` | `11.0.0` | gfx1100 兼容版本 |
| `HIP_VISIBLE_DEVICES` | `0` | 使用的 GPU 编号 |
| `VLM_BASE_URL` | 远程 API | VLM 服务地址 |
| `VLM_API_KEY` | - | VLM API 密钥 |
| `VLM_MODEL` | `gpt-5.5` 或 `Qwen/Qwen2.5-VL-7B-Instruct` | VLM 模型名 |
| `ROBONIX_SCENE_ROS_DISTRO` | `jazzy` | scene 包构建用的 ROS distro |
| `ROBONIX_WEBOTS_WORLD` | `office.wbt` | Webots 仿真世界 |
| `WEBOTS_STREAM` | `0` | 是否启用浏览器流式查看 |
| `DISPLAY` | `:99` 或 `:48` | X11 显示器（Xvfb 或 AMD GPU Xorg） |

---

## 12. 快速启动流程（TL;DR）

```bash
# 0. 一键安装（首次）
cd /path/to/robonix
./scripts/setup_native_env.sh --check         # 检查环境
./scripts/setup_native_env.sh                 # 完整安装
./scripts/setup_native_env.sh --with-vlm      # 装本地 VLM（可选）

# 1. 终端 1：启动仿真
WEBOTS_STREAM=1 bash scripts/native/start_sim.sh
# → 浏览器打开 http://<服务器IP>:8080/

# 2. 终端 2：启动 VLM（如果用本地）
bash scripts/native/start_vlm.sh

# 3. 终端 3：启动 Robonix
bash scripts/native/build_drivers.sh          # 首次需要
export VLM_BASE_URL=http://127.0.0.1:8000/v1  # 用本地 VLM
export VLM_API_KEY=dummy-key
export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct
bash scripts/native/start_robonix.sh

# 4. 终端 4：交互
rbnx chat

# 停止
bash scripts/native/stop_all.sh
```
