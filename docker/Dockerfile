ARG ROS_BASE_IMAGE=osrf/ros:humble-desktop
FROM ${ROS_BASE_IMAGE}

# ── TUNA mirrors ───────────────────────────────────────────────────
# Swap apt sources (Ubuntu/ports + ROS 2) to TUNA. Use `find` + sed
# --follow-symlinks because /etc/apt/sources.list.d/ros2.sources is
# a symlink into /usr/share/ros-apt-source/ in the upstream ros image.
RUN set -eux; \
    find /etc/apt/sources.list.d/ -maxdepth 1 \( -name '*.list' -o -name '*.sources' \) -print0 \
      | xargs -0 -r sed -i --follow-symlinks \
          -e 's|http://packages\.ros\.org/ros2/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu|g' \
          -e 's|^Types: deb deb-src$|Types: deb|'; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i --follow-symlinks \
            -e 's|http://archive\.ubuntu\.com/ubuntu/\?|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
            -e 's|http://security\.ubuntu\.com/ubuntu/\?|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
            -e 's|http://ports\.ubuntu\.com/ubuntu-ports/\?|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' \
            /etc/apt/sources.list; \
    fi
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    HF_ENDPOINT=https://hf-mirror.com
    
ENV ROS_DOMAIN_ID=0
ENV ROS_LOCALHOST_ONLY=0
ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

# ── GPU backend selection ──────────────────────────────────────────
# ROBONIX_GPU_BACKEND controls the PyTorch wheel variant:
#   rocm  → AMD ROCm wheels (default on AMD Radeon hosts)
#   cuda  → NVIDIA CUDA wheels (default when nvidia-smi exists)
# The build arg is set by docker/run.sh based on host GPU detection.
ARG ROBONIX_GPU_BACKEND=cuda

RUN apt-get update && apt-get install -y \
    ca-certificates \
    wget gnupg && \
    rm -rf /var/lib/apt/lists/*

# NVIDIA CUDA toolkit — only installed for the cuda backend.
RUN if [ "${ROBONIX_GPU_BACKEND}" = "cuda" ]; then \
        wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
        dpkg -i cuda-keyring_1.1-1_all.deb && \
        apt-get update && \
        apt-get install -y cuda-toolkit-12-4 && \
        rm cuda-keyring_1.1-1_all.deb && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# AMD ROCm — only installed for the rocm backend.
RUN if [ "${ROBONIX_GPU_BACKEND}" = "rocm" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            rocm-core rocm-libs rocm-dev hip-runtime-amd hip-dev && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# RUN wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh && \
#     bash Miniconda3-latest-Linux-x86_64.sh -b -p /opt/miniconda3 && \
#     rm Miniconda3-latest-Linux-x86_64.sh

RUN apt update && apt install -y \
    ros-humble-rmw-fastrtps-cpp \
    ros-humble-rmw-zenoh-cpp \
    python3-pip \
    python3-grpcio \
    python3-protobuf \
    python3-dev \
    build-essential \
    git \
    curl \
    wget \
    protobuf-compiler \
    libeigen3-dev \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    bzip2 \
    libosmesa6 \
    libglu1-mesa \
    libglfw3 \
    libglfw3-dev \
    mesa-utils \
    libclang-dev python3-vcstool \
    bash-completion \
    fonts-lmodern \
    ros-humble-test-msgs \
    python-is-python3

RUN pip3 install --no-cache-dir \
    grpcio-tools openai pyarrow "eclipse-zenoh>=1.2,<2" \
    mujoco>=3.3.0 \
    robosuite \
    Pillow

RUN pip3 install --no-cache-dir \
    "lerobot[smolvla]" \
    libero

RUN GRPCURL_VERSION=1.9.3 && \
    GH_BASE=https://ghfast.top/https://github.com && \
    (curl -fsSL "${GH_BASE}/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" \
       || curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz") \
    | tar -xz -C /usr/local/bin grpcurl

# RUN apt update && apt install -y curl && \
# curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
# curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
# apt update && \
# apt install -y tailscale && \
# pip3 install --upgrade pip

# ENV PATH=/opt/miniconda3/bin:$PATH

# RUN conda tos accept || true && \
#     conda create -n env1 python=3.10 -y && \
#     conda clean -ya

# RUN conda config --set solver classic && \
#     conda config --set channel_priority flexible

# ── PyTorch install — GPU-backend-aware ─────────────────────────────
# cuda backend: standard CUDA 12.4 wheels from pytorch.org.
# rocm backend: ROCm 6.3 wheels from pytorch.org (HIP, no CUDA needed).
RUN if [ "${ROBONIX_GPU_BACKEND}" = "rocm" ]; then \
        pip3 install --no-cache-dir \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/rocm6.3; \
    else \
        pip3 install --no-cache-dir \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/cu124; \
    fi

# ENV PATH=/opt/miniconda3/bin:$PATH

# RUN conda tos accept || true && \
#     conda create -n env1 python=3.10 -y && \
#     conda clean -ya

# RUN conda config --set solver classic && \
#     conda config --set channel_priority flexible

# RUN conda run -n env1 pip install git+https://github.com/colcon/colcon-cargo.git && \
#     conda run -n env1 pip install git+https://github.com/colcon/colcon-ros-cargo.git

# CUDA environment — effective only when the cuda backend is used (ROBONIX_GPU_BACKEND=cuda).
# Under the rocm backend these are no-ops: /usr/local/cuda doesn't exist and
# NVIDIA_VISIBLE_DEVICES is ignored (no nvidia-container-runtime).
ENV CUDA_HOME=/usr/local/cuda
ENV CUDA_PATH=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:$PATH
RUN echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/compat:${LD_LIBRARY_PATH:-}' >> ~/.bashrc
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
# ROCm environment — effective only when the rocm backend is used (ROBONIX_GPU_BACKEND=rocm).
# Under the cuda backend /opt/rocm doesn't exist and HIP_VISIBLE_DEVICES is ignored.
ENV ROCM_HOME=/opt/rocm
ENV PATH=/opt/rocm/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH:-}
ENV HIP_VISIBLE_DEVICES=0
ENV ROCR_VISIBLE_DEVICES=0

# install rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

WORKDIR /root/workspace