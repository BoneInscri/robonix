#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# =============================================================================
# Robonix 原生环境配置脚本（完全不依赖 Docker）
#
# 适用环境（基于实际云服务器信息）：
#   - Ubuntu 24.04.4 LTS (Noble Numbat) x86_64
#   - AMD ROCm 7.2.1 + gfx1100 (AMD Radeon Graphics, ~48GB VRAM)
#   - PyTorch 2.9.1 ROCm 版已预装
#   - 容器内环境（无 dockerd），以 root 运行
#   - CPU: AMD EPYC 9334 32-Core
#
# 关键适配点：
#   - Ubuntu 24.04 → ROS2 Jazzy（不是 Humble，Humble 仅支持 22.04）
#   - 已有 ROCm + PyTorch → 跳过 PyTorch 安装
#   - root 用户 → 不使用 sudo
#   - 无 Docker → 全部原生构建
#
# 用法：
#   chmod +x scripts/setup_native_env.sh
#   ./scripts/setup_native_env.sh              # 完整安装
#   ./scripts/setup_native_env.sh --check      # 仅检查环境，不安装
#   ./scripts/setup_native_env.sh --patch-only # 只改造 driver 脚本（环境已装好时）
#   ./scripts/setup_native_env.sh --with-vlm   # 额外安装本地 vLLM VLM 服务
#
# 脚本做的事：
#   1. 安装系统依赖（ROS2 Jazzy、Webots、colcon、X11 headless 工具等）
#   2. 安装 Rust 工具链 + uv（Python 包管理器）
#   3. 构建 Robonix 本体（make install）
#   4. 同步 Python 工作区依赖（uv sync）
#   5. 构建 eaios_webots ROS2 包
#   6. 改造所有 driver 的 start.sh / build.sh / package_manifest.yaml，
#      把 docker exec 替换成原生直接运行
#   7. （可选）安装本地 VLM（vLLM on ROCm）
# =============================================================================
set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[err]${NC}   $*" >&2; }
info() { echo -e "${BLUE}[info]${NC}  $*"; }

# ── 定位仓库根目录 ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 解析参数 ──────────────────────────────────────────────────────────────
CHECK_ONLY=0
PATCH_ONLY=0
SKIP_VLM=1   # 默认跳过 VLM（需要 GPU + 大量下载）
for arg in "$@"; do
    case "$arg" in
        --check)      CHECK_ONLY=1 ;;
        --patch-only) PATCH_ONLY=1 ;;
        --with-vlm)   SKIP_VLM=0 ;;
        --help|-h)
            echo "Usage: $0 [--check|--patch-only|--with-vlm]"
            echo "  (无参数)         完整安装 + 改造脚本"
            echo "  --check          仅检查环境"
            echo "  --patch-only     仅改造 driver 脚本（环境已就绪时）"
            echo "  --with-vlm       额外安装本地 vLLM VLM 服务"
            exit 0 ;;
        *) err "未知参数: $arg"; exit 1 ;;
    esac
done

# ── 环境常量（基于 system-info.txt） ──────────────────────────────────────
# Ubuntu 24.04 → ROS2 Jazzy（Humble 不支持 24.04）
ROS_DISTRO="${ROS_DISTRO:-jazzy}"
# ROCm 路径（已预装）
ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
# 是否 root（容器内通常已是 root）
IS_ROOT=0
if [[ "$(id -u)" == "0" ]]; then
    IS_ROOT=1
fi
# sudo 包装：root 时去掉 sudo，非 root 保留
SUDO=""
if [[ "$IS_ROOT" == "0" ]]; then
    SUDO="sudo"
fi

# ===========================================================================
# 阶段 0：环境检查
# ===========================================================================
check_env() {
    log "=== 环境检查 ==="

    # OS 版本
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        info "OS: $PRETTY_NAME"
        if [[ "$ID" != "ubuntu" ]]; then
            warn "本脚本针对 Ubuntu 编写，当前为 $ID。"
        fi
        if [[ "${VERSION_ID:-}" == "24.04" ]]; then
            info "Ubuntu 24.04 → 使用 ROS2 Jazzy"
        elif [[ "${VERSION_ID:-}" == "22.04" ]]; then
            info "Ubuntu 22.04 → 使用 ROS2 Humble"
            ROS_DISTRO="humble"
        else
            warn "版本 ${VERSION_ID:-未知}，尝试用 Jazzy。"
        fi
    else
        err "无法读取 /etc/os-release"
        return 1
    fi

    # 架构
    local arch
    arch="$(uname -m)"
    info "架构: $arch"

    # 内存
    if command -v free &>/dev/null; then
        local mem_gb
        mem_gb=$(( $(free -m | awk '/^Mem:/{print $2}') / 1024 ))
        info "内存: ${mem_gb} GB"
        if (( mem_gb < 8 )); then
            warn "内存 < 8GB，Webots + ROS2 仿真可能 OOM。"
        fi
    fi

    # ROCm GPU 检测
    local rocm_smi="/opt/rocm/bin/rocm-smi"
    if [[ -x "$rocm_smi" ]]; then
        info "GPU: AMD ROCm ($($rocm_smi --showproductname 2>/dev/null | grep -i 'Card series' | head -1 || echo 'detected'))"
        local vram_bytes
        vram_bytes=$($rocm_smi --showmeminfo vram 2>/dev/null | awk '/VRAM Total/{print $6; exit}')
        if [[ -n "$vram_bytes" ]]; then
            local vram_gb=$(( vram_bytes / 1073741824 ))
            info "VRAM: ${vram_gb} GB"
        fi
    elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        info "GPU: NVIDIA"
    elif [[ -e /dev/kfd ]]; then
        info "GPU: AMD (检测到 /dev/kfd)"
    else
        warn "GPU: 未检测到。Webots 将使用 CPU 软渲染（慢但可用）。"
    fi

    # PyTorch 检测
    if python3 -c "import torch" 2>/dev/null; then
        local torch_ver torch_gpu
        torch_ver=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
        torch_gpu=$(python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)
        info "PyTorch: $torch_ver (GPU available: $torch_gpu)"
    else
        warn "PyTorch 未安装。VLM 功能将需要远程 API。"
    fi

    # Docker（仅信息性提示）
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        warn "检测到可用的 Docker。本脚本仍将走原生路线，不使用 Docker。"
    else
        info "Docker 不可用（正常，本脚本就是为无 Docker 环境设计的）。"
    fi

    # 磁盘空间
    local avail_gb
    avail_gb=$(df -BG "$REPO_ROOT" | awk 'NR==2{print $4}' | tr -d 'G')
    info "可用磁盘: ${avail_gb} GB（建议 >= 30GB）"
    if (( avail_gb < 15 )); then
        warn "磁盘空间紧张。"
    fi

    info "ROS2 发行版: $ROS_DISTRO"
    info "用户: $(whoami) (root=$IS_ROOT)"

    log "环境检查完成。"
}

if [[ "$CHECK_ONLY" == "1" ]]; then
    check_env
    exit 0
fi

# ===========================================================================
# 阶段 1：系统依赖安装（ROS2 Jazzy + Webots + 工具链）
# ===========================================================================
install_system_deps() {
    log "=== 阶段 1: 安装系统依赖 (ROS2 $ROS_DISTRO) ==="

    export DEBIAN_FRONTEND=noninteractive

    # 1.1 基础工具
    log "安装基础工具..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
        curl wget gnupg2 lsb-release ca-certificates \
        build-essential cmake git unzip \
        python3 python3-pip python3-dev python3-venv \
        locales locale-gen \
        xvfb xserver-xorg-core mesa-utils \
        libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev \
        libosmesa6 libglu1-mesa libglfw3 libglfw3-dev \
        libxcb-cursor0 pciutils \
        bash-completion fonts-lmodern \
        alsa-utils \
        software-properties-common \
        2>/dev/null

    # 确保有 en_US.UTF-8（ROS2 需要）
    $SUDO locale-gen en_US en_US.UTF-8 2>/dev/null || true
    $SUDO update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 2>/dev/null || true
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    # 1.2 ROS2 Jazzy（Ubuntu 24.04 对应的 ROS2 发行版）
    if ! [[ -d /opt/ros/$ROS_DISTRO ]]; then
        log "安装 ROS2 $ROS_DISTRO..."
        $SUDO curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
            -o /usr/share/keyrings/ros-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
            | $SUDO tee /etc/apt/sources.list.d/ros2.list >/dev/null

        # 国内网络换 TUNA 源
        if curl -sI --max-time 3 https://mirrors.tuna.tsinghua.edu.cn >/dev/null 2>&1; then
            info "检测到国内网络，使用 TUNA ROS2 镜像..."
            $SUDO sed -i 's|http://packages.ros.org/ros2/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu|g' \
                /etc/apt/sources.list.d/ros2.list
        fi

        $SUDO apt-get update -qq
        # Jazzy 的桌面完整包
        $SUDO apt-get install -y -qq ros-${ROS_DISTRO}-desktop-full 2>/dev/null
    else
        info "ROS2 $ROS_DISTRO 已安装，跳过。"
    fi

    # 1.3 ROS2 补充包（Webots 集成 + Nav2 + Zenoh RMW）
    # 注意：Jazzy 的包名前缀是 ros-jazzy-*
    log "安装 ROS2 补充包..."
    $SUDO apt-get install -y -qq \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
        ros-${ROS_DISTRO}-rmw-fastrtps-cpp \
        ros-${ROS_DISTRO}-nav2-msgs \
        ros-${ROS_DISTRO}-nav2-bringup \
        ros-${ROS_DISTRO}-webots-ros2 \
        ros-${ROS_DISTRO}-webots-ros2-driver \
        ros-${ROS_DISTRO}-controller-manager \
        ros-${ROS_DISTRO}-diagnostic-updater \
        ros-${ROS_DISTRO}-diff-drive-controller \
        ros-${ROS_DISTRO}-joint-state-broadcaster \
        ros-${ROS_DISTRO}-robot-state-publisher \
        ros-${ROS_DISTRO}-tf2-ros \
        ros-${ROS_DISTRO}-rviz2 \
        ros-${ROS_DISTRO}-test-msgs \
        python3-colcon-common-extensions \
        2>/dev/null

    # 1.4 Webots 仿真器
    if ! command -v webots &>/dev/null; then
        log "安装 Webots R2025a..."
        local webots_deb_url="https://github.com/cyberbotics/webots/releases/download/R2025a/webots_2025a_amd64.deb"
        local webots_mirror="https://ghfast.top/"
        local fetch_url="${webots_mirror}${webots_deb_url}"

        # 尝试镜像，失败则直连
        if ! wget -q --show-progress -O /tmp/webots.deb "$fetch_url"; then
            warn "镜像下载失败，尝试直连 GitHub..."
            wget -q --show-progress -O /tmp/webots.deb "$webots_deb_url"
        fi
        $SUDO apt-get install -y -qq /tmp/webots.deb 2>/dev/null || {
            # 如果 apt 安装依赖失败，用 dpkg 强装后修依赖
            $SUDO dpkg -i /tmp/webots.deb || true
            $SUDO apt-get install -f -y -qq 2>/dev/null
        }
        rm -f /tmp/webots.deb
    else
        info "Webots 已安装 ($(webots --version 2>/dev/null || echo 'unknown'))，跳过。"
    fi

    # 1.5 Python 驱动依赖（driver 进程需要的库）
    # 注意：Ubuntu 24.04 的 Python 是 3.12，需要 --break-system-packages
    log "安装 Python 驱动依赖..."
    python3 -m pip install --no-cache-dir --break-system-packages \
        "grpcio>=1.78.0" "protobuf>=6.30,<7" mcp "fastmcp>=3" \
        numpy Pillow uvicorn httpx 2>/dev/null || \
    python3 -m pip install --no-cache-dir \
        "grpcio>=1.78.0" "protobuf>=6.30,<7" mcp "fastmcp>=3" \
        numpy Pillow uvicorn httpx 2>/dev/null

    # 1.6 ROCm 环境变量（确保 PyTorch 能找到 GPU）
    # 机器上已有 ROCm 7.2.1 + PyTorch 2.9.1，只需要设置环境变量
    if [[ -d /opt/rocm ]]; then
        info "检测到 ROCm $(cat /opt/rocm/.info/version 2>/dev/null || echo 'installed')"
        # 写入 /etc/profile.d 以便所有 shell 都能使用
        cat > /etc/profile.d/rocm-env.sh <<'ROCM_EOF'
# ROCm environment
export ROCM_HOME=/opt/rocm
export PATH=$ROCM_HOME/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_HOME/lib:${LD_LIBRARY_PATH:-}
export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-0}
export ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-0}
# PyTorch ROCm 需要 HSA_OVERRIDE_GFX_VERSION 来确保 gfx1100 兼容
export HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-11.0.0}
ROCM_EOF
        chmod +x /etc/profile.d/rocm-env.sh
        # 立即生效
        source /etc/profile.d/rocm-env.sh
        info "ROCm 环境变量已设置（/etc/profile.d/rocm-env.sh）"
    fi

    log "系统依赖安装完成。"
}

# ===========================================================================
# 阶段 2：Rust + uv 工具链
# ===========================================================================
install_toolchain() {
    log "=== 阶段 2: 安装 Rust + uv ==="

    # Rust
    if ! command -v cargo &>/dev/null; then
        log "安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        info "Rust 已安装 ($(rustc --version))"
    fi

    # uv（Python 包管理器）
    if ! command -v uv &>/dev/null; then
        log "安装 uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    else
        info "uv 已安装 ($(uv --version))"
    fi

    # 确认 PATH
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
}

# ===========================================================================
# 阶段 3：构建 Robonix 本体
# ===========================================================================
build_robonix() {
    log "=== 阶段 3: 构建 Robonix ==="

    cd "$REPO_ROOT"

    # make install: 构建 + 安装 rbnx/atlas/pilot/executor/liaison/soma/vitals/codegen
    log "执行 make install（构建 Rust 工作区 + 安装二进制到 ~/.cargo/bin）..."
    make install

    # 验证 rbnx 可用
    if ! command -v rbnx &>/dev/null; then
        err "rbnx 未在 PATH 中。请手动 source ~/.cargo/env 后重试。"
        return 1
    fi
    info "rbnx 版本: $(rbnx --version 2>/dev/null || echo 'ok')"

    # 注册仓库源
    log "注册 robonix 源路径..."
    rbnx setup "$REPO_ROOT" || warn "rbnx setup 失败，可能已注册。"

    # Python 工作区同步（system/scene, services/*, pylib/*）
    log "同步 Python 工作区 (uv sync)..."
    uv sync 2>/dev/null || warn "uv sync 有警告，继续。"

    log "Robonix 构建完成。"
}

# ===========================================================================
# 阶段 4：构建 eaios_webots ROS2 包
# ===========================================================================
build_webots_pkg() {
    log "=== 阶段 4: 构建 eaios_webots ==="

    cd "$REPO_ROOT/examples/webots/sim/ros_ws"

    source /opt/ros/$ROS_DISTRO/setup.bash
    colcon build --symlink-install --packages-select eaios_webots

    log "eaios_webots 构建完成。"
}

# ===========================================================================
# 阶段 5：改造 driver 脚本（docker exec → 原生运行）
# ===========================================================================
patch_driver_scripts() {
    log "=== 阶段 5: 改造 driver 脚本 ==="

    local primitives_dir="$REPO_ROOT/examples/webots/primitives"

    # --- 5.1 tiago_chassis ---
    local chassis_dir="$primitives_dir/tiago_chassis"
    log "改造 tiago_chassis..."

    cat > "$chassis_dir/scripts/start.sh" <<START_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# tiago_chassis runtime — 原生模式（无 Docker）。
# 直接在宿主机运行，与 Webots 共享同一个 DDS 域。
set -euo pipefail

source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true

export ROBONIX_ATLAS="\${ROBONIX_ATLAS:-127.0.0.1:50051}"
export ROBONIX_ADVERTISE_HOST="\${ROBONIX_ADVERTISE_HOST:-127.0.0.1}"
export ROBONIX_PKG_HOST_DIR="\$PKG_DIR"
export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export PYTHONPATH="\$(rbnx path robonix-api 2>/dev/null || echo "\$PKG_DIR/../../pylib/robonix-api"):\$PKG_DIR/rbnx-build/codegen/proto_gen:\${PYTHONPATH:-}"

cd "\$PKG_DIR"
exec python3 -m chassis_driver.driver
START_EOF
    chmod +x "$chassis_dir/scripts/start.sh"

    cat > "$chassis_dir/scripts/build.sh" <<BUILD_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# tiago_chassis build — 原生模式。codegen + colcon build 都在宿主机跑。
set -euo pipefail
PKG="\${RBNX_PACKAGE_ROOT:-\$(cd "\$(dirname "\$0")/.." && pwd)}"

CLEAN="\${RBNX_BUILD_CLEAN:-}"
FLAGS=(--mcp --ros2)
[[ "\$CLEAN" == "1" ]] && FLAGS+=(--clean)

echo "[tiago_chassis/build] rbnx codegen \${FLAGS[*]}"
rbnx codegen -p "\$PKG" "\${FLAGS[@]}"

# 原生构建 ROS 2 overlay（不需要 docker exec）
IDL_DIR="\$PKG/rbnx-build/codegen/ros2_idl"
if [ -d "\$IDL_DIR" ]; then
    echo "[tiago_chassis/build] colcon build ros2_idl (native)"
    source /opt/ros/$ROS_DISTRO/setup.bash
    (cd "\$IDL_DIR" && colcon build)
else
    echo "[tiago_chassis/build] WARN: ros2_idl dir not found, skipping"
fi
echo "[tiago_chassis/build] done."
BUILD_EOF
    chmod +x "$chassis_dir/scripts/build.sh"

    # 改 package_manifest.yaml 的 stop 段
    sed -i 's|docker exec "$SIM_CT" pkill|pkill|g' "$chassis_dir/package_manifest.yaml"
    sed -i '/SIM_CT=/d' "$chassis_dir/package_manifest.yaml"

    # --- 5.2 tiago_camera ---
    local camera_dir="$primitives_dir/tiago_camera"
    log "改造 tiago_camera..."

    cat > "$camera_dir/scripts/start.sh" <<START_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# tiago_camera runtime — 原生模式（无 Docker）。
set -euo pipefail

source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true

export ROBONIX_ATLAS="\${ROBONIX_ATLAS:-127.0.0.1:50051}"
export ROBONIX_ADVERTISE_HOST="\${ROBONIX_ADVERTISE_HOST:-127.0.0.1}"
export ROBONIX_PKG_HOST_DIR="\$PKG_DIR"
export TIAGO_RGB_TOPIC="\${TIAGO_RGB_TOPIC:-/head_front_camera/rgb/image_raw}"
export TIAGO_DEPTH_TOPIC="\${TIAGO_DEPTH_TOPIC:-/head_front_camera/depth_registered/image_raw}"
export TIAGO_RGB_FRAME_ID="\${TIAGO_RGB_FRAME_ID:-head_front_camera_rgb_optical_frame}"
export TIAGO_DEPTH_FRAME_ID="\${TIAGO_DEPTH_FRAME_ID:-head_front_camera_depth_optical_frame}"
export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export PYTHONPATH="\$(rbnx path robonix-api 2>/dev/null || echo "\$PKG_DIR/../../pylib/robonix-api"):\$PKG_DIR/rbnx-build/codegen/proto_gen:\$PKG_DIR/rbnx-build/codegen/robonix_mcp_types:\${PYTHONPATH:-}"

# Webots 帧名补偿：发布静态 TF（原 docker exec -d 部分）
ros2 run tf2_ros static_transform_publisher \\
    --x 0 --y 0 --z 0 --yaw 0 --pitch 0 --roll 0 \\
    --frame-id 'Astra rgb' --child-frame-id head_front_camera_rgb_optical_frame &
ros2 run tf2_ros static_transform_publisher \\
    --x 0 --y 0 --z 0 --yaw 0 --pitch 0 --roll 0 \\
    --frame-id 'Astra depth' --child-frame-id head_front_camera_depth_optical_frame &

cd "\$PKG_DIR"
exec python3 -m camera_driver.driver
START_EOF
    chmod +x "$camera_dir/scripts/start.sh"

    cat > "$camera_dir/scripts/build.sh" <<BUILD_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
set -euo pipefail
PKG="\${RBNX_PACKAGE_ROOT:-\$(cd "\$(dirname "\$0")/.." && pwd)}"
CLEAN="\${RBNX_BUILD_CLEAN:-}"
FLAGS=(--mcp --ros2)
[[ "\$CLEAN" == "1" ]] && FLAGS+=(--clean)
echo "[tiago_camera/build] rbnx codegen \${FLAGS[*]}"
rbnx codegen -p "\$PKG" "\${FLAGS[@]}"

IDL_DIR="\$PKG/rbnx-build/codegen/ros2_idl"
if [ -d "\$IDL_DIR" ]; then
    echo "[tiago_camera/build] colcon build ros2_idl (native)"
    source /opt/ros/$ROS_DISTRO/setup.bash
    (cd "\$IDL_DIR" && colcon build)
else
    echo "[tiago_camera/build] WARN: ros2_idl dir not found, skipping"
fi
echo "[tiago_camera/build] done."
BUILD_EOF
    chmod +x "$camera_dir/scripts/build.sh"

    sed -i 's|docker exec "$SIM_CT" pkill|pkill|g' "$camera_dir/package_manifest.yaml"
    sed -i '/SIM_CT=/d' "$camera_dir/package_manifest.yaml"

    # --- 5.3 tiago_lidar ---
    local lidar_dir="$primitives_dir/tiago_lidar"
    log "改造 tiago_lidar..."

    cat > "$lidar_dir/scripts/start.sh" <<START_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# tiago_lidar runtime — 原生模式（无 Docker）。
set -euo pipefail

source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true

export ROBONIX_ATLAS="\${ROBONIX_ATLAS:-127.0.0.1:50051}"
export ROBONIX_ADVERTISE_HOST="\${ROBONIX_ADVERTISE_HOST:-127.0.0.1}"
export ROBONIX_PKG_HOST_DIR="\$PKG_DIR"
export TIAGO_SCAN_RAW_TOPIC="\${TIAGO_SCAN_RAW_TOPIC:-/scanner}"
export TIAGO_SCAN_TOPIC="\${TIAGO_SCAN_TOPIC:-/scanner_normalized}"
export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export PYTHONPATH="\$(rbnx path robonix-api 2>/dev/null || echo "\$PKG_DIR/../../pylib/robonix-api"):\$PKG_DIR/rbnx-build/codegen/proto_gen:\$PKG_DIR/rbnx-build/codegen/robonix_mcp_types:\${PYTHONPATH:-}"

RAW_TOPIC="\${TIAGO_SCAN_RAW_TOPIC}"
OUT_TOPIC="\${TIAGO_SCAN_TOPIC}"

# 启动 scan normalize（Webots LaserScan 修正）
python3 "\$PKG_DIR/scripts/scan_normalize.py" --in "\$RAW_TOPIC" --out "\$OUT_TOPIC" &
NORM_PID=\$!
trap "kill -TERM '\$NORM_PID' 2>/dev/null || true" EXIT

cd "\$PKG_DIR"
exec python3 -m lidar_driver.driver
START_EOF
    chmod +x "$lidar_dir/scripts/start.sh"

    cat > "$lidar_dir/scripts/build.sh" <<BUILD_EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
set -euo pipefail
PKG="\${RBNX_PACKAGE_ROOT:-\$(cd "\$(dirname "\$0")/.." && pwd)}"
CLEAN="\${RBNX_BUILD_CLEAN:-}"
FLAGS=(--mcp --ros2)
[[ "\$CLEAN" == "1" ]] && FLAGS+=(--clean)
echo "[tiago_lidar/build] rbnx codegen \${FLAGS[*]}"
rbnx codegen -p "\$PKG" "\${FLAGS[@]}"

IDL_DIR="\$PKG/rbnx-build/codegen/ros2_idl"
if [ -d "\$IDL_DIR" ]; then
    echo "[tiago_lidar/build] colcon build ros2_idl (native)"
    source /opt/ros/$ROS_DISTRO/setup.bash
    (cd "\$IDL_DIR" && colcon build)
else
    echo "[tiago_lidar/build] WARN: ros2_idl dir not found, skipping"
fi
echo "[tiago_lidar/build] done."
BUILD_EOF
    chmod +x "$lidar_dir/scripts/build.sh"

    sed -i 's|docker exec "$SIM_CT" pkill|pkill|g' "$lidar_dir/package_manifest.yaml"
    sed -i '/SIM_CT=/d' "$lidar_dir/package_manifest.yaml"

    # --- 5.4 验证改造结果 ---
    log "验证改造结果..."
    local remaining
    remaining=$(grep -rl "docker exec" "$primitives_dir"/*/scripts/ 2>/dev/null | wc -l)
    if (( remaining > 0 )); then
        warn "仍有 $remaining 个脚本包含 docker exec，请手动检查："
        grep -rl "docker exec" "$primitives_dir"/*/scripts/ 2>/dev/null
    else
        info "所有 driver 脚本已改造为原生模式。"
    fi

    log "driver 脚本改造完成。"
}

# ===========================================================================
# 阶段 6：（可选）本地 VLM（vLLM on ROCm）
# ===========================================================================
install_vlm() {
    log "=== 阶段 6: 安装本地 VLM（vLLM on ROCm）==="

    # 确认 ROCm 环境
    if [[ ! -d /opt/rocm ]]; then
        warn "未检测到 ROCm，跳过 VLM 安装。请使用远程 VLM API。"
        return 0
    fi

    local rocm_ver
    rocm_ver=$(cat /opt/rocm/.info/version 2>/dev/null || echo "7.2.1")
    info "ROCm 版本: $rocm_ver"

    # 确认 PyTorch 已装
    if ! python3 -c "import torch" 2>/dev/null; then
        warn "PyTorch 未安装，先安装 PyTorch ROCm 版..."
        pip3 install --no-cache-dir --pre --break-system-packages \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/nightly/rocm7.2
    else
        info "PyTorch 已安装: $(python3 -c 'import torch; print(torch.__version__)')"
    fi

    # 安装 vLLM（ROCm 版）
    # ROCm 7.2 用 rocm721 tag（如果不可用回退到 rocm700）
    info "安装 vLLM ROCm 版..."
    pip3 install --no-cache-dir --break-system-packages \
        "vllm==0.18.0+rocm700" \
        --extra-index-url "https://wheels.vllm.ai/rocm/0.18.0/rocm700" \
        2>/dev/null || \
    pip3 install --no-cache-dir --break-system-packages \
        "vllm==0.18.0" \
        --extra-index-url "https://wheels.vllm.ai/rocm/0.18.0/rocm700" \
        2>/dev/null || \
    warn "vLLM 安装失败，请手动安装或使用远程 API。"

    # 预下载模型权重（可选，首次启动会自动下载）
    info "VLM 安装完成。启动方式："
    info "  export HF_ENDPOINT=https://hf-mirror.com"
    info "  python3 -m vllm.entrypoints.openai.api_server \\"
    info "    --host 0.0.0.0 --port 8000 \\"
    info "    --model Qwen/Qwen2.5-VL-7B-Instruct \\"
    info "    --trust-remote-code --dtype bfloat16 \\"
    info "    --max-model-len 4096 --gpu-memory-utilization 0.85"
    info ""
    info "然后在 rbnx boot 前设置："
    info "  export VLM_BASE_URL=http://127.0.0.1:8000/v1"
    info "  export VLM_API_KEY=dummy-key"
    info "  export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct"
}

# ===========================================================================
# 阶段 7：生成启动脚本
# ===========================================================================
generate_launch_scripts() {
    log "=== 阶段 7: 生成启动脚本 ==="

    local launch_dir="$REPO_ROOT/scripts/native"
    mkdir -p "$launch_dir"

    # 7.1 Webots 仿真启动脚本（替代 sim/start.sh）
    cat > "$launch_dir/start_sim.sh" <<SIM_EOF
#!/usr/bin/env bash
# 原生 Webots 仿真启动脚本（替代 examples/webots/sim/start.sh）
# 启动 Webots + eaios_webots 控制器，使用 ROS2 launch。
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
REPO_ROOT="\$(cd "\$SCRIPT_DIR/../.." && pwd)"
ROS_WS="\$REPO_ROOT/examples/webots/sim/ros_ws"

source /opt/ros/$ROS_DISTRO/setup.bash
source "\$ROS_WS/install/setup.bash" 2>/dev/null || {
    echo "[sim] eaios_webots 未构建，正在构建..."
    cd "\$ROS_WS" && colcon build --symlink-install --packages-select eaios_webots
    source "\$ROS_WS/install/setup.bash"
}

export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export ROBONIX_WEBOTS_WORLD="\${ROBONIX_WEBOTS_WORLD:-office.wbt}"
export ROBONIX_WEBOTS_ROBOT="\${ROBONIX_WEBOTS_ROBOT:-tiago_webots.urdf}"

# 无头模式：如果需要浏览器流式查看（云服务器场景）
if [[ "\${WEBOTS_STREAM:-0}" == "1" ]]; then
    export DISPLAY="\${DISPLAY:-:99}"
    # 启动 Xvfb（如果没有真实 X server）
    if ! pgrep -x Xvfb >/dev/null 2>&1; then
        Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
        sleep 1
    fi
    # 尝试用 AMD GPU 加速 Xorg（比 Xvfb 快很多）
    if [[ -e /dev/dri/card0 ]] || [[ -e /dev/dri/card2 ]]; then
        if ! pgrep -f "Xorg :48" >/dev/null 2>&1; then
            echo "[sim] 尝试启动 AMD GPU 加速 Xorg :48..."
            cat > /tmp/xorg-amd.conf <<'XORG'
Section "ServerLayout"
  Identifier "L0"
  Screen 0 "S0"
EndSection
Section "Device"
  Identifier "D0"
  Driver "amdgpu"
EndSection
Section "Screen"
  Identifier "S0"
  Device "D0"
  Option "AllowEmptyInitialConfiguration" "true"
  Option "UseDisplayDevice" "none"
  SubSection "Display"
    Virtual 1920 1080
    Depth 24
  EndSubSection
EndSection
XORG
            Xorg :48 -config /tmp/xorg-amd.conf -noreset -novtswitch -sharevts -nolisten tcp \
                -logfile /tmp/Xorg.48.log &
            sleep 2
            if [ -S /tmp/.X11-unix/X48 ]; then
                export DISPLAY=:48
                echo "[sim] AMD GPU Xorg :48 启动成功"
            else
                echo "[sim] AMD GPU Xorg 启动失败，回退到 Xvfb :99"
                export DISPLAY=:99
            fi
        fi
    fi
    echo "[sim] 浏览器流式模式已启用："
    echo "[sim]   Webots 3D 视图: http://\$(hostname -I 2>/dev/null | awk '{print \$1}' || echo localhost):8080/"
    echo "[sim]   WS 流地址:      ws://\$(hostname -I 2>/dev/null | awk '{print \$1}' || echo localhost):1234"
    # 启动 viewer HTTP 服务
    WEBOTS_VIEWER_DIR="/usr/local/webots/resources/web/streaming_viewer"
    if [ -d "\$WEBOTS_VIEWER_DIR" ]; then
        (cd "\$WEBOTS_VIEWER_DIR" && python3 -m http.server 8080 --bind 0.0.0.0) &
    fi
fi

echo "[sim] 启动 Webots..."
echo "[sim]   world: \$ROBONIX_WEBOTS_WORLD"
echo "[sim]   robot: \$ROBONIX_WEBOTS_ROBOT"
echo "[sim]   RMW:   \$RMW_IMPLEMENTATION"
echo "[sim]   DISPLAY: \$DISPLAY"

# 启动 Zenoh router（如果用 Zenoh RMW）
if [[ "\$RMW_IMPLEMENTATION" == "rmw_zenoh_cpp" ]]; then
    ZENOH_ROUTER="/opt/ros/$ROS_DISTRO/lib/rmw_zenoh_cpp/rmw_zenohd"
    if [ -x "\$ZENOH_ROUTER" ] && ! pgrep -f rmw_zenohd >/dev/null 2>&1; then
        echo "[sim] 启动 rmw_zenohd..."
        "\$ZENOH_ROUTER" >/tmp/rmw_zenohd.log 2>&1 &
        sleep 2
    fi
fi

exec ros2 launch eaios_webots robot_launch.py \\
    use_sim_time:=true \\
    world:="\$ROBONIX_WEBOTS_WORLD" \\
    robot:="\$ROBONIX_WEBOTS_ROBOT"
SIM_EOF
    chmod +x "$launch_dir/start_sim.sh"

    # 7.2 Robonix 启动脚本
    cat > "$launch_dir/start_robonix.sh" <<ROBONIX_EOF
#!/usr/bin/env bash
# Robonix 启动脚本（原生模式）
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
REPO_ROOT="\$(cd "\$SCRIPT_DIR/../.." && pwd)"

source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
source "\$HOME/.cargo/env" 2>/dev/null || true
export PATH="\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH"

# ROCm 环境
source /etc/profile.d/rocm-env.sh 2>/dev/null || true

# RMW 设置
export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

# VLM 设置（三选一，默认用远程 API）
# 选项 1：远程 OpenAI 兼容 API
export VLM_BASE_URL="\${VLM_BASE_URL:-https://api.openai.com/v1}"
export VLM_API_KEY="\${VLM_API_KEY:?请设置 VLM_API_KEY}"
export VLM_MODEL="\${VLM_MODEL:-gpt-5.5}"

# 选项 2：本地 vLLM（取消注释，需要先装 vLLM）
# export VLM_BASE_URL=http://127.0.0.1:8000/v1
# export VLM_API_KEY=dummy-key
# export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct

# 场景地图 ID
export SCENE_MAP_ID="\${SCENE_MAP_ID:-webots_lab}"

# scene 包用 Jazzy 构建（适配 Ubuntu 24.04）
export ROBONIX_SCENE_ROS_DISTRO=$ROS_DISTRO

echo "[robonix] VLM: \$VLM_BASE_URL / \$VLM_MODEL"
echo "[robonix] RMW: \$RMW_IMPLEMENTATION"
echo "[robonix] ROS distro: $ROS_DISTRO"

cd "\$REPO_ROOT/examples/webots"
exec rbnx boot
ROBONIX_EOF
    chmod +x "$launch_dir/start_robonix.sh"

    # 7.3 停止脚本
    cat > "$launch_dir/stop_all.sh" <<'STOP_EOF'
#!/usr/bin/env bash
# 停止所有 Robonix + Webots 进程
set -eo pipefail

echo "[stop] 停止 rbnx boot..."
cd "$(dirname "$0")/../../examples/webots"
rbnx shutdown 2>/dev/null || true

echo "[stop] 停止 Webots..."
pkill -TERM -f "webots|ros2 launch eaios_webots|robot_launch" 2>/dev/null || true
sleep 1
pkill -KILL -f "webots|ros2 launch eaios_webots|robot_launch" 2>/dev/null || true

echo "[stop] 停止 Zenoh router..."
pkill -f rmw_zenohd 2>/dev/null || true

echo "[stop] 停止 Xvfb / Xorg..."
pkill -f "Xvfb :99" 2>/dev/null || true
pkill -f "Xorg :48" 2>/dev/null || true

echo "[stop] 停止 VLM..."
pkill -f "vllm.entrypoints" 2>/dev/null || true

echo "[stop] 完成。"
STOP_EOF
    chmod +x "$launch_dir/stop_all.sh"

    # 7.4 构建 driver 的脚本
    cat > "$launch_dir/build_drivers.sh" <<BUILD_EOF
#!/usr/bin/env bash
# 构建所有 driver 包的 codegen + ROS2 overlay
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
REPO_ROOT="\$(cd "\$SCRIPT_DIR/../.." && pwd)"

source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
source "\$HOME/.cargo/env" 2>/dev/null || true
export PATH="\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH"

PRIMITIVES="\$REPO_ROOT/examples/webots/primitives"

for pkg in tiago_chassis tiago_camera tiago_lidar; do
    echo ""
    echo "=== 构建 \$pkg ==="
    bash "\$PRIMITIVES/\$pkg/scripts/build.sh"
done

echo ""
echo "=== 构建完成 ==="
BUILD_EOF
    chmod +x "$launch_dir/build_drivers.sh"

    # 7.5 启动本地 VLM 的脚本
    cat > "$launch_dir/start_vlm.sh" <<'VLM_EOF'
#!/usr/bin/env bash
# 启动本地 vLLM VLM 服务（AMD ROCm）
set -euo pipefail

source /etc/profile.d/rocm-env.sh 2>/dev/null || true

export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export VLLM_MODEL="${VLM_MODEL:-Qwen/Qwen2.5-VL-7B-Instruct}"
export VLLM_PORT="${VLM_PORT:-8000}"

echo "[vlm] 启动 vLLM..."
echo "[vlm]   model: $VLLM_MODEL"
echo "[vlm]   port:  $VLLM_PORT"
echo "[vlm]   GPU:   $(rocm-smi --showproductname 2>/dev/null | grep -i 'Card series' | head -1 || echo 'AMD ROCm')"

exec python3 -m vllm.entrypoints.openai.api_server \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --model "$VLLM_MODEL" \
    --served-model-name "$VLLM_MODEL" \
    --trust-remote-code \
    --dtype bfloat16 \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.85
VLM_EOF
    chmod +x "$launch_dir/start_vlm.sh"

    log "启动脚本已生成到 scripts/native/:"
    info "  start_sim.sh       — 启动 Webots 仿真（支持 AMD GPU Xorg 加速）"
    info "  start_robonix.sh   — 启动 Robonix 栈"
    info "  build_drivers.sh   — 构建所有 driver"
    info "  start_vlm.sh       — 启动本地 vLLM VLM 服务"
    info "  stop_all.sh        — 停止一切"
}

# ===========================================================================
# 主流程
# ===========================================================================
main() {
    log "Robonix 原生环境配置（无 Docker）"
    log "仓库: $REPO_ROOT"
    log "目标环境: Ubuntu 24.04 + AMD ROCm 7.2.1 + ROS2 $ROS_DISTRO"
    log ""

    check_env
    echo ""

    if [[ "$PATCH_ONLY" == "1" ]]; then
        patch_driver_scripts
        generate_launch_scripts
        log ""
        log "完成！仅改造了脚本，未安装系统依赖。"
        log "下一步：参考 scripts/native/ 下的启动脚本运行。"
        exit 0
    fi

    install_system_deps
    echo ""
    install_toolchain
    echo ""
    build_robonix
    echo ""
    build_webots_pkg
    echo ""
    patch_driver_scripts
    echo ""
    generate_launch_scripts

    if [[ "$SKIP_VLM" == "0" ]]; then
        echo ""
        install_vlm
    fi

    # =========================================================================
    # 完成 + 使用说明
    # =========================================================================
    echo ""
    log "============================================================"
    log "  Robonix 原生环境配置完成！"
    log "  环境: Ubuntu 24.04 + ROCm 7.2.1 + ROS2 $ROS_DISTRO"
    log "============================================================"
    echo ""
    echo "使用步骤（两个或三个终端）："
    echo ""
    echo "  # 终端 1：启动 Webots 仿真（无头流式模式，浏览器查看）"
    echo "  WEBOTS_STREAM=1 bash scripts/native/start_sim.sh"
    echo "  #   然后浏览器打开 http://<服务器IP>:8080/"
    echo ""
    echo "  # 终端 2（可选）：启动本地 VLM（如果不用远程 API）"
    echo "  bash scripts/native/start_vlm.sh"
    echo ""
    echo "  # 终端 3：构建 driver + 启动 Robonix"
    echo "  bash scripts/native/build_drivers.sh   # 首次需要"
    echo "  # 如果用远程 VLM："
    echo "  export VLM_API_KEY=sk-xxx"
    echo "  # 如果用本地 VLM："
    echo "  export VLM_BASE_URL=http://127.0.0.1:8000/v1"
    echo "  export VLM_API_KEY=dummy-key"
    echo "  export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct"
    echo "  bash scripts/native/start_robonix.sh"
    echo ""
    echo "  # 终端 4：交互"
    echo "  rbnx caps   # 查看已注册能力"
    echo "  rbnx chat   # 与 pilot 对话"
    echo ""
    echo "停止一切："
    echo "  bash scripts/native/stop_all.sh"
    echo ""
    echo "注意事项："
    echo "  - ROS2 发行版是 $ROS_DISTRO（Ubuntu 24.04 专用），不是 Humble"
    echo "  - 确保每次新终端都 source /opt/ros/$ROS_DISTRO/setup.bash"
    echo "  - ROCm 环境变量在 /etc/profile.d/rocm-env.sh，新终端自动加载"
    echo "  - gfx1100 GPU 的 HSA_OVERRIDE_GFX_VERSION=11.0.0 已设置"
    echo "  - 48GB VRAM 足够跑 Qwen2.5-VL-7B（需要 ~14GB）"
    echo "  - mapping/nav2 包从 GitHub 克隆，首次 rbnx boot 会自动拉取"
    echo "  - scene 包需要 ROBONIX_SCENE_ROS_DISTRO=$ROS_DISTRO（已设入启动脚本）"
}

main "$@"
