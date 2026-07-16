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
        # rocm-smi --showmeminfo vram 输出格式可能变化，用 grep 提取数字
        local vram_bytes
        vram_bytes=$($rocm_smi --showmeminfo vram 2>/dev/null | grep -i 'VRAM Total Memory' | grep -oE '[0-9]+' | head -1 || true)
        if [[ -n "${vram_bytes:-}" ]]; then
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
    # Ubuntu 24.04 包名变化：libgl1-mesa-glx → libgl1
    $SUDO apt-get install -y \
        curl wget gnupg2 lsb-release ca-certificates \
        build-essential cmake git unzip \
        python3 python3-pip python3-dev python3-venv \
        locales \
        xvfb xserver-xorg-core mesa-utils \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
        libosmesa6 libglu1-mesa libglfw3 libglfw3-dev \
        libxcb-cursor0 pciutils \
        bash-completion fonts-lmodern \
        alsa-utils \
        software-properties-common \
        || {
            warn "部分包安装失败，尝试继续..."
        }

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
        $SUDO apt-get install -y ros-${ROS_DISTRO}-desktop-full \
            || { err "ros-${ROS_DISTRO}-desktop-full 安装失败"; return 1; }
    else
        info "ROS2 $ROS_DISTRO 已安装，跳过。"
    fi

    # 1.3 ROS2 补充包（Webots 集成 + Nav2 + Zenoh RMW）
    # 注意：Jazzy 的包名前缀是 ros-jazzy-*
    log "安装 ROS2 补充包..."
    $SUDO apt-get install -y \
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
        || warn "部分 ROS2 补充包安装失败，继续..."

    # 1.4 Webots 仿真器
    if ! command -v webots &>/dev/null; then
        log "安装 Webots R2025a..."
        local webots_deb_url="https://github.com/cyberbotics/webots/releases/download/R2025a/webots_2025a_amd64.deb"

        # 优先检查 /tmp/webots.deb（预置缓存），其次检查仓库本地缓存
        local local_deb="$REPO_ROOT/scripts/webots_2025a_amd64.deb"
        if [[ -s "/tmp/webots.deb" ]]; then
            info "发现 /tmp/webots.deb 已存在且非空，跳过下载。"
        elif [[ -f "$local_deb" ]]; then
            info "发现本地缓存: $local_deb，直接使用。"
            cp "$local_deb" /tmp/webots.deb
        else
            # 多个镜像 + 直连，带超时与重试
            local mirrors=(
                "https://gh.llkk.cc/"       # GitHub 加速（通用）
                "https://github.moeyy.xyz/" # GitHub 加速（备用）
                "https://ghfast.top/"       # 原始镜像
            )
            local downloaded=0
            for mirror in "${mirrors[@]}"; do
                local fetch_url="${mirror}${webots_deb_url}"
                info "尝试: $fetch_url"
                if wget --timeout=60 --tries=3 --progress=dot:giga -O /tmp/webots.deb "$fetch_url"; then
                    downloaded=1
                    break
                fi
                warn "该镜像失败，尝试下一个..."
                rm -f /tmp/webots.deb
            done

            if [[ "$downloaded" == "0" ]]; then
                warn "所有镜像失败，尝试直连 GitHub（可能较慢）..."
                if ! wget --timeout=120 --tries=3 --progress=dot:giga -O /tmp/webots.deb "$webots_deb_url"; then
                    err "Webots 下载失败。请手动下载 webots_2025a_amd64.deb 放到以下任一位置后重试："
                    err "  1) $local_deb"
                    err "  2) /tmp/webots.deb"
                    err "下载地址: $webots_deb_url"
                    rm -f /tmp/webots.deb
                    return 1
                fi
            fi
        fi
        $SUDO apt-get install -y /tmp/webots.deb || {
            # 如果 apt 安装依赖失败，用 dpkg 强装后修依赖
            warn "apt 安装 Webots 依赖失败，尝试 dpkg + 修依赖..."
            $SUDO dpkg -i /tmp/webots.deb || true
            $SUDO apt-get install -f -y
        }
        rm -f /tmp/webots.deb
    else
        info "Webots 已安装 ($(webots --version 2>/dev/null || echo 'unknown'))，跳过。"
    fi

    # 1.4b Webots 运行时依赖：Qt6 6.5+ + OIS（Webots R2025a 基于 Qt6.5）
    # 缺这些库时 webots-bin 能启动但无法加载世界文件、不创建 IPC 端点。
    # Ubuntu 24.04 仓库里的 Qt6 是 6.4.x，但 Webots R2025a 需要 Qt 6.5+，
    # 需要优先检查 Webots 自带的 Qt 库，其次尝试从 PPA 安装更高版本。
    if command -v webots &>/dev/null; then
        local missing_libs
        missing_libs=$(ldd /usr/local/webots/bin/webots-bin 2>/dev/null | grep "not found" || true)
        if [[ -n "$missing_libs" ]]; then
            log "检测到 Webots 缺少运行时库，安装 Qt6 + 依赖..."
            info "缺失的库:"
            echo "$missing_libs" | head -10

            # 步骤 1: 先从 apt 安装基础 Qt6 包（可能是 6.4，不满足但先装上其他依赖）
            $SUDO apt-get install -y \
                libqt6core6t64 libqt6network6t64 libqt6gui6t64 libqt6opengl6t64 \
                libqt6openglwidgets6t64 libqt6websockets6t64 libqt6widgets6t64 \
                libqt6printsupport6t64 libqt6qml6 libqt6xml6t64 \
                libqt6core5compat6 \
                libois-dev libois1.4 \
                2>/dev/null || {
                    warn "部分 Qt6 包名可能不同，尝试通配安装..."
                    $SUDO apt-get install -y \
                        qt6-base-dev qt6-websockets-dev \
                        libqt6core6 libqt6gui6 libqt6widgets6 libqt6opengl6 \
                        libqt6network6 libqt6xml6 libqt6qml6 \
                        libqt6openglwidgets6 libqt6websockets6 libqt6printsupport6 \
                        libois-dev \
                        2>/dev/null || warn "Qt6 apt 安装有警告，继续..."
                }

            # 步骤 2: 检查是否仍有 Qt_6.5 版本不匹配问题
            local qt_version_err
            qt_version_err=$(ldd /usr/local/webots/bin/webots-bin 2>&1 | grep "Qt_6.5.*not found" || true)
            if [[ -n "$qt_version_err" ]]; then
                warn "系统 Qt6 版本 < 6.5，Webots R2025a 需要 Qt 6.5+"
                info "尝试方案 A: 检查 Webots 是否自带 Qt 库..."
                # Webots R2025a 自带 Qt 6.5.3 在 /usr/local/webots/lib/webots/
                local webots_qt_dir=""
                for d in /usr/local/webots/lib/webots /usr/local/webots/lib/qt6 /usr/local/webots/lib /usr/local/webots/bin; do
                    if [[ -f "$d/libQt6Core.so.6" ]]; then
                        webots_qt_dir="$d"
                        break
                    fi
                done
                if [[ -n "$webots_qt_dir" ]]; then
                    info "发现 Webots 自带 Qt 6.5 库: $webots_qt_dir"
                    # 写入 ld.so.conf 让系统优先加载 Webots 的 Qt6.5
                    echo "$webots_qt_dir" > /etc/ld.so.conf.d/webots-qt.conf
                    ldconfig
                    info "已将 Webots Qt 路径写入 /etc/ld.so.conf.d/webots-qt.conf"
                    # 验证 Qt_6.5 错误是否消失
                    local qt_check
                    qt_check=$(ldd /usr/local/webots/bin/webots-bin 2>&1 | grep "Qt_6.5.*not found" || true)
                    if [[ -z "$qt_check" ]]; then
                        info "✅ Qt 6.5 版本问题已解决"
                    else
                        warn "Qt 6.5 版本问题仍存在，可能需要设置 LD_LIBRARY_PATH"
                    fi
                else
                    info "Webots 未自带 Qt6 库，尝试方案 B: 添加 PPA..."
                    # 方案 B: 尝试添加 PPA 获取更高版本 Qt6
                    $SUDO add-apt-repository ppa:ubuntu-toolchain-r/test -y 2>/dev/null || true
                    $SUDO apt-get update -qq 2>/dev/null
                    $SUDO apt-get install -y \
                        libqt6core6 libqt6gui6 libqt6widgets6 libqt6opengl6 \
                        libqt6network6 libqt6xml6 libqt6qml6 \
                        libqt6openglwidgets6 libqt6websockets6 libqt6printsupport6 \
                        2>/dev/null || warn "PPA Qt6 安装失败"
                fi
            fi

            # 步骤 3: 最终验证
            local still_missing
            still_missing=$(ldd /usr/local/webots/bin/webots-bin 2>/dev/null | grep "not found" || true)
            local still_version_err
            still_version_err=$(ldd /usr/local/webots/bin/webots-bin 2>&1 | grep "Qt_6.5.*not found" || true)
            if [[ -n "$still_missing" ]] || [[ -n "$still_version_err" ]]; then
                warn "Webots 仍有库问题:"
                [[ -n "$still_missing" ]] && echo "$still_missing"
                [[ -n "$still_version_err" ]] && echo "$still_version_err"
                warn "请手动安装 Qt 6.5+ 或设置 LD_LIBRARY_PATH 指向 Webots 自带 Qt"
            else
                info "Webots 运行时库已就绪。"
            fi
        else
            info "Webots 运行时库完整，跳过。"
        fi
    fi

    # 1.4c Webots 资源缓存预下载
    # office.wbt 等世界文件引用大量 EXTERNPROTO（从 GitHub 下载的 .proto 文件），
    # 首次启动时 Webots 会逐个下载，在容器/云服务器环境极慢或失败，
    # 导致世界文件无法加载、IPC 端点不创建、extern controller 连接超时。
    # 预下载资源到 ~/.cache/Cyberbotics/Webots/ 可避免此问题。
    if command -v webots &>/dev/null; then
        local webots_cache_dir="/root/.cache/Cyberbotics/Webots"
        local proto_check="$webots_cache_dir/assets/projects/objects/backgrounds/protos/TexturedBackground.proto"

        if [[ ! -f "$proto_check" ]]; then
            log "预下载 Webots 资源缓存（EXTERNPROTO proto 文件）..."
            mkdir -p "$webots_cache_dir/assets"

            # 方案 A: 从 GitHub 下载 assets-R2025a.zip（官方资源包）
            local assets_downloaded=0
            for url in \
                "https://github.com/cyberbotics/webots/releases/download/R2025a/assets-R2025a.zip" \
                "https://ghfast.top/https://github.com/cyberbotics/webots/releases/download/R2025a/assets-R2025a.zip"; do
                info "尝试下载: $url"
                if wget --timeout=120 --tries=2 -q -O /tmp/webots-assets.zip "$url" && \
                   [[ -s /tmp/webots-assets.zip ]]; then
                    unzip -q -o /tmp/webots-assets.zip -d "$webots_cache_dir/assets/" 2>/dev/null
                    assets_downloaded=1
                    info "资源包下载并解压成功"
                    break
                fi
                warn "该 URL 下载失败，尝试下一个..."
                rm -f /tmp/webots-assets.zip
            done

            # 方案 B: 用 git clone 拉取 Webots 仓库的 projects + resources 目录
            if [[ "$assets_downloaded" == "0" ]]; then
                warn "资源包下载失败，尝试 git clone 方式..."
                if GIT_SSL_NO_VERIFY=1 git clone --depth 1 --branch R2025a \
                        https://github.com/cyberbotics/webots.git /tmp/webots-repo 2>/dev/null; then
                    cp -r /tmp/webots-repo/projects "$webots_cache_dir/assets/projects" 2>/dev/null || true
                    cp -r /tmp/webots-repo/resources "$webots_cache_dir/assets/resources" 2>/dev/null || true
                    rm -rf /tmp/webots-repo
                    assets_downloaded=1
                    info "git clone 资源下载成功"
                fi
            fi

            # 验证
            if [[ -f "$proto_check" ]]; then
                local cache_size
                cache_size=$(du -sh "$webots_cache_dir" 2>/dev/null | awk '{print $1}')
                info "✅ Webots 资源缓存就绪（$cache_size）"
            else
                warn "Webots 资源缓存预下载失败。首次启动 Webots 会很慢或失败。"
                warn "手动下载：git clone --depth 1 --branch R2025a https://github.com/cyberbotics/webots.git"
                warn "然后 cp -r /tmp/webots-repo/projects ~/.cache/Cyberbotics/Webots/assets/"
            fi
            rm -f /tmp/webots-assets.zip
        else
            local cache_size
            cache_size=$(du -sh "$webots_cache_dir" 2>/dev/null | awk '{print $1}')
            info "Webots 资源缓存已存在（$cache_size），跳过。"
        fi
    fi

    # 1.5 Python 驱动依赖（driver 进程需要的库）
    # 注意：Ubuntu 24.04 的 Python 是 3.12，需要 --break-system-packages
    log "安装 Python 驱动依赖..."
    python3 -m pip install --no-cache-dir --break-system-packages \
        "grpcio>=1.78.0" "grpcio-tools>=1.78.0" "protobuf>=7.0" mcp "fastmcp>=3" \
        numpy Pillow uvicorn httpx || \
    python3 -m pip install --no-cache-dir \
        "grpcio>=1.78.0" "grpcio-tools>=1.78.0" "protobuf>=7.0" mcp "fastmcp>=3" \
        numpy Pillow uvicorn httpx 2>/dev/null || warn "Python 依赖安装有警告，继续..."

    # 1.6 ROCm 环境变量 + PyTorch 安装
    if [[ -d /opt/rocm ]]; then
        local rocm_ver
        rocm_ver=$(cat /opt/rocm/.info/version 2>/dev/null || echo "7.2")
        info "检测到 ROCm $rocm_ver"

        # 写入 /etc/profile.d 以便所有 shell 都能使用
        cat > /etc/profile.d/rocm-env.sh <<ROCM_EOF
# ROCm environment
export ROCM_HOME=/opt/rocm
export PATH=\$ROCM_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ROCM_HOME/lib:\${LD_LIBRARY_PATH:-}
export HIP_VISIBLE_DEVICES=\${HIP_VISIBLE_DEVICES:-0}
export ROCR_VISIBLE_DEVICES=\${ROCR_VISIBLE_DEVICES:-0}
# gfx1100 需要此变量确保 PyTorch/vLLM 兼容
export HSA_OVERRIDE_GFX_VERSION=\${HSA_OVERRIDE_GFX_VERSION:-11.0.0}
ROCM_EOF
        chmod +x /etc/profile.d/rocm-env.sh
        source /etc/profile.d/rocm-env.sh
        info "ROCm 环境变量已设置（/etc/profile.d/rocm-env.sh）"

        # 检查 PyTorch 是否已安装，没装则安装 ROCm 版
        if ! python3 -c "import torch" 2>/dev/null; then
            log "PyTorch 未安装，安装 ROCm 版..."
            # 从 ROCm 版本提取主次版本号，如 7.2.0 → 7.2
            local rocm_short="${rocm_ver%.*}"  # "7.2"
            pip3 install --no-cache-dir --break-system-packages --pre \
                torch torchvision torchaudio \
                --index-url "https://download.pytorch.org/whl/nightly/rocm${rocm_short}" \
                --timeout 600 \
                || {
                    warn "PyTorch ROCm nightly (rocm${rocm_short}) 安装失败，尝试 rocm6.3..."
                    pip3 install --no-cache-dir --break-system-packages \
                        torch torchvision torchaudio \
                        --index-url https://download.pytorch.org/whl/rocm6.3 \
                        --timeout 600 \
                        || warn "PyTorch 安装失败，VLM 功能需要远程 API"
                }
            # 验证
            if python3 -c "import torch" 2>/dev/null; then
                info "PyTorch 安装成功: $(python3 -c 'import torch; print(torch.__version__)')"
                python3 -c "import torch; print('GPU available:', torch.cuda.is_available())"
            fi
        else
            info "PyTorch 已安装: $(python3 -c 'import torch; print(torch.__version__)')"
        fi
    fi

    log "系统依赖安装完成。"
}

# ===========================================================================
# 阶段 2：Git submodule + Rust + uv 工具链
# ===========================================================================
init_submodules() {
    log "=== 阶段 2a: 初始化 Git submodule ==="

    cd "$REPO_ROOT"

    # 检查是否已有 .gitmodules
    if [[ ! -f .gitmodules ]]; then
        info "无 .gitmodules，跳过 submodule 初始化。"
        return 0
    fi

    # 检查关键 submodule 目录是否为空
    local need_init=0
    for sub in capabilities/lib/common_interfaces capabilities/lib/rcl_interfaces; do
        if [[ -d "$sub" ]] && [[ -z "$(ls -A "$sub" 2>/dev/null)" ]]; then
            warn "submodule 目录为空: $sub"
            need_init=1
        fi
    done

    if [[ "$need_init" == "0" ]] && [[ -f capabilities/lib/common_interfaces/sensor_msgs/msg/Image.msg ]]; then
        info "submodule 已就绪，跳过。"
        return 0
    fi

    log "初始化并拉取 submodule（需要网络）..."
    # 尝试一次性拉所有 submodule
    if ! git submodule update --init --recursive 2>/dev/null; then
        warn "一次性拉取失败，逐个拉取必需的 submodule..."
        # 逐个拉取必需的 submodule
        for sub in capabilities/lib/common_interfaces capabilities/lib/rcl_interfaces; do
            log "拉取 submodule: $sub"
            git submodule init "$sub" 2>/dev/null || true
            git submodule update "$sub" 2>/dev/null || true
        done
    fi

    # 验证关键文件存在
    if [[ ! -f capabilities/lib/common_interfaces/sensor_msgs/msg/Image.msg ]]; then
        err "submodule 拉取失败：common_interfaces/sensor_msgs/msg/Image.msg 不存在"
        err "请手动执行：git submodule update --init --recursive"
        return 1
    fi

    info "submodule 初始化完成。"
    info "  common_interfaces: $(ls capabilities/lib/common_interfaces/ | wc -l) 个目录"
    info "  rcl_interfaces: $(ls capabilities/lib/rcl_interfaces/ | wc -l) 个目录"
}

install_toolchain() {
    log "=== 阶段 2b: 安装 Rust + uv ==="

    # Rust
    if ! command -v cargo &>/dev/null; then
        log "安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        # 某些环境下 rustup 不生成 ~/.cargo/env，回退到手动设 PATH
        if [[ -f "$HOME/.cargo/env" ]]; then
            source "$HOME/.cargo/env"
        else
            export PATH="$HOME/.cargo/bin:$PATH"
        fi
    else
        info "Rust 已安装 ($(rustc --version))"
    fi

    # 确保有默认工具链（rustup 装完有时没设 default）
    if command -v rustup &>/dev/null; then
        if ! rustup show active-toolchain &>/dev/null 2>&1; then
            log "设置 Rust 默认工具链..."
            rustup default stable
        fi
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

    # 写入 ~/.bashrc，确保新终端自动生效
    for entry in 'export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"'; do
        if ! grep -qF "$entry" "$HOME/.bashrc" 2>/dev/null; then
            echo "$entry" >> "$HOME/.bashrc"
            info "已写入 ~/.bashrc：$entry"
        fi
    done
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
        err "rbnx 未在 PATH 中。请执行 source ~/.cargo/env 或 export PATH=\"\$HOME/.cargo/bin:\$PATH\" 后重试。"
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

    # ROS2 setup.bash 在 set -u 下会报 unbound variable，临时关闭
    set +u
    source /opt/ros/$ROS_DISTRO/setup.bash
    set -u
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

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
set +u
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true
set -u

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
    set +u; source /opt/ros/$ROS_DISTRO/setup.bash; set -u
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

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
set +u
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true
set -u

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
    set +u; source /opt/ros/$ROS_DISTRO/setup.bash; set -u
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

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u

PKG_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
OVL="\$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
set +u
[ -f "\$OVL" ] && source "\$OVL" 2>/dev/null || true
set -u

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
    set +u; source /opt/ros/$ROS_DISTRO/setup.bash; set -u
    (cd "\$IDL_DIR" && colcon build)
else
    echo "[tiago_lidar/build] WARN: ros2_idl dir not found, skipping"
fi
echo "[tiago_lidar/build] done."
BUILD_EOF
    chmod +x "$lidar_dir/scripts/build.sh"

    sed -i 's|docker exec "$SIM_CT" pkill|pkill|g' "$lidar_dir/package_manifest.yaml"
    sed -i '/SIM_CT=/d' "$lidar_dir/package_manifest.yaml"

    # --- 5.4 simple_nav 服务 ---
    local nav_dir="$REPO_ROOT/examples/webots/services/simple_nav"
    if [[ -d "$nav_dir/scripts" ]]; then
        log "改造 simple_nav 服务..."

        cat > "$nav_dir/scripts/start.sh" <<'START_EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# simple_nav runtime — 原生模式（无 Docker）。
set -euo pipefail

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OVL="$PKG_DIR/rbnx-build/codegen/ros2_idl/install/setup.bash"
set +u
[ -f "$OVL" ] && source "$OVL" 2>/dev/null || true
set -u

export ROBONIX_ATLAS="${ROBONIX_ATLAS:-127.0.0.1:50051}"
export ROBONIX_PKG_HOST_DIR="$PKG_DIR"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export PYTHONPATH="$(rbnx path robonix-api 2>/dev/null || echo "$PKG_DIR/../../../pylib/robonix-api"):$PKG_DIR/rbnx-build/codegen/proto_gen:${PYTHONPATH:-}"

cd "$PKG_DIR"
exec python3 -m simple_nav.atlas_bridge
START_EOF
        chmod +x "$nav_dir/scripts/start.sh"

        cat > "$nav_dir/scripts/build.sh" <<'BUILD_EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: MulanPSL-2.0
# simple_nav build — 原生模式。codegen + colcon build 都在宿主机跑。
set -euo pipefail
PKG="${RBNX_PACKAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

CLEAN="${RBNX_BUILD_CLEAN:-}"
FLAGS=(--mcp --ros2)
[[ "$CLEAN" == "1" ]] && FLAGS+=(--clean)

echo "[simple_nav/build] rbnx codegen ${FLAGS[*]}"
rbnx codegen -p "$PKG" "${FLAGS[@]}"

IDL_DIR="$PKG/rbnx-build/codegen/ros2_idl"
if [ -d "$IDL_DIR" ]; then
    echo "[simple_nav/build] colcon build ros2_idl (native)"
    set +u; source /opt/ros/$ROS_DISTRO/setup.bash; set -u
    (cd "$IDL_DIR" && colcon build)
else
    echo "[simple_nav/build] WARN: ros2_idl dir not found, skipping"
fi
echo "[simple_nav/build] done."
BUILD_EOF
        chmod +x "$nav_dir/scripts/build.sh"

        sed -i 's|docker exec "$SIM_CT" pkill|pkill|g' "$nav_dir/package_manifest.yaml"
        sed -i '/SIM_CT=/d' "$nav_dir/package_manifest.yaml"

        info "simple_nav 已改造为原生模式。"
    fi

    # --- 5.5 验证改造结果 ---
    log "验证改造结果..."
    local remaining
    remaining=$( (grep -rl "docker exec" "$primitives_dir"/*/scripts/ 2>/dev/null; grep -rl "docker exec" "$REPO_ROOT/examples/webots/services"/*/scripts/ 2>/dev/null) | wc -l)
    if (( remaining > 0 )); then
        warn "仍有 $remaining 个脚本包含 docker exec，请手动检查："
        grep -rl "docker exec" "$primitives_dir"/*/scripts/ "$REPO_ROOT/examples/webots/services"/*/scripts/ 2>/dev/null
    else
        info "所有 driver + 服务脚本已改造为原生模式。"
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

set +u; source /opt/ros/$ROS_DISTRO/setup.bash; set -u
set +u; source "\$ROS_WS/install/setup.bash" 2>/dev/null; set -u

if [ ! -f "\$ROS_WS/install/setup.bash" ]; then
    echo "[sim] eaios_webots 未构建，正在构建..."
    cd "\$ROS_WS" && colcon build --symlink-install --packages-select eaios_webots
    set +u; source "\$ROS_WS/install/setup.bash"; set -u
fi

export RMW_IMPLEMENTATION="\${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export ROBONIX_WEBOTS_WORLD="\${ROBONIX_WEBOTS_WORLD:-office.wbt}"
export ROBONIX_WEBOTS_ROBOT="\${ROBONIX_WEBOTS_ROBOT:-tiago_webots.urdf}"

# 无头模式：如果需要浏览器流式查看（云服务器场景）
if [[ "\${WEBOTS_STREAM:-0}" == "1" ]]; then
    export DISPLAY="\${DISPLAY:-:99}"
    # 启动前清理可能残留的旧进程（避免 IPC 冲突导致世界加载卡死）
    pkill -9 -f webots-bin 2>/dev/null || true
    pkill -9 -f "ros2 launch eaios_webots" 2>/dev/null || true
    pkill -9 -f "http.server 8080" 2>/dev/null || true
    rm -rf /tmp/webots 2>/dev/null || true
    sleep 1
    # 启动 Xvfb（如果没有真实 X server）
    if ! pgrep -x Xvfb >/dev/null 2>&1; then
        Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
        sleep 1
    fi
    # 尝试用 AMD GPU 加速 Xorg（比 Xvfb 快很多，且 stream 模式需要 GPU GL 上下文）
    # 注意：系统通常只装了 modesetting 驱动（xserver-xorg-core 自带），
    #       没装 amdgpu Xorg 驱动，所以必须用 modesetting + kmsdev。
    #       用 amdgpu 驱动会导致 "no screens found"，Xorg 启动失败，
    #       回退到 Xvfb :99，而 Xvfb 不支持 Webots stream 模式的 GL 上下文需求，
    #       导致世界永远加载不完（/tmp/webots/.../loading 文件不删除）。
    if ls /dev/dri/card* >/dev/null 2>&1; then
        if ! pgrep -f "Xorg :48" >/dev/null 2>&1; then
            echo "[sim] 尝试启动 AMD GPU 加速 Xorg :48..."
            # 优先选 card1+（card0 有时是 VGArbiter 非显示设备）
            AMD_DRI_CARD=\$(ls /dev/dri/card* 2>/dev/null | grep -v '/card0\$' | head -1)
            [ -z "\$AMD_DRI_CARD" ] && AMD_DRI_CARD=\$(ls /dev/dri/card* 2>/dev/null | head -1)
            echo "[sim]   DRI device: \$AMD_DRI_CARD"
            cat > /tmp/xorg-amd.conf <<XORG
Section "ServerLayout"
  Identifier "L0"
  Screen 0 "S0"
EndSection
Section "Device"
  Identifier "D0"
  Driver "modesetting"
  Option "kmsdev" "\$AMD_DRI_CARD"
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
                echo "[sim] AMD GPU Xorg :48 启动成功 (modesetting, \$AMD_DRI_CARD)"
            else
                echo "[sim] AMD GPU Xorg 启动失败，回退到 Xvfb :99"
                echo "[sim]   Xorg 日志: /tmp/Xorg.48.log"
                export DISPLAY=:99
            fi
        fi
    fi
    echo "[sim] 浏览器流式模式已启用："
    echo "[sim]   Webots 3D 视图: http://\$(hostname -I 2>/dev/null | awk '{print \$1}' || echo localhost):8080/"
    echo "[sim]   WS 流地址:      ws://\$(hostname -I 2>/dev/null | awk '{print \$1}' || echo localhost):1234"
    # 启动 viewer HTTP 服务（先清理可能占用 8080 的旧进程）
    pkill -f "http.server 8080" 2>/dev/null || true
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

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u
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

set +u
source /opt/ros/$ROS_DISTRO/setup.bash 2>/dev/null || true
set -u
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
    init_submodules
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
