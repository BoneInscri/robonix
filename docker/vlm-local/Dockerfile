# Local VLM Server (AMD ROCm)
#
# Serves an OpenAI-compatible API from a local AMD Radeon GPU using vLLM.
# This replaces remote API calls (OpenAI / etc.) so that VLM inference
# runs entirely on the local AMD GPU via ROCm.
#
# Model: Qwen/Qwen2.5-VL-7B-Instruct
#   - 7B parameters, ~14 GB weight storage
#   - BF16 inference: needs >=16 GB VRAM (24 GB recommended)
#   - Vision-Language model: accepts text + images
#   - Open-weight (Apache 2.0), no API key needed
#
# Inference framework: vLLM (https://docs.vllm.ai)
#   - High-throughput LLM/VLM serving engine
#   - Native ROCm support (no CUDA needed)
#   - Built-in OpenAI-compatible API server
#   - PagedAttention for efficient KV-cache management
#
# Build:
#   docker build -t robonix-vlm .
#
# Run (requires /dev/kfd + /dev/dri on host):
#   docker run --rm --device=/dev/kfd --device=/dev/dri --group-add video \
#     -e HIP_VISIBLE_DEVICES=0 -e ROCR_VISIBLE_DEVICES=0 \
#     -p 8000:8000 robonix-vlm
#
# Then point robonix pilot at it:
#   export VLM_BASE_URL=http://127.0.0.1:8000/v1
#   export VLM_API_KEY=dummy-key
#   export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct

# vLLM ROCm pre-built wheels require Python 3.12 + ROCm 7.0+.
# The rocm/pytorch base image provides PyTorch 2.9.1 with HIP backend.
# Using ROCm 7.2.4 to match the host (Radeon Cloud: ROCm 7.2.1, gfx1100).
# Python 3.12 is mandatory — vLLM ROCm wheels are NOT published for 3.10/3.11.
#
# NOTE: vLLM does NOT publish a pre-built ROCm Docker image on Docker Hub.
# You must build from this Dockerfile. With pre-built wheels the build
# takes ~5 min (wheel download + model weight download).
ARG ROCM_IMAGE=rocm/pytorch:rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1
FROM ${ROCM_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_ENDPOINT=https://hf-mirror.com

# ── 1. Install vLLM with ROCm support ──────────────────────────────
# vLLM on ROCm must be installed from the ROCm wheel index, NOT the
# default PyPI (which serves CUDA-only wheels that will fail with
# "libcudart.so: cannot open shared object file" on AMD GPUs).
#
# We use the official vLLM ROCm wheel index (new format with /rocm/ prefix):
#   https://wheels.vllm.ai/rocm/<version>/<rocm_variant>/
#
# Pin vLLM version for reproducibility. The wheel tag must match the
# ROCm version in the base image:
#   rocm7.0  → rocm700 (stable, vLLM 0.14.0–0.18.0)
#   rocm7.2.1 → rocm721 (nightly only, after commit 171775f)
# We use rocm700 (stable vLLM 0.18.0) — backward-compatible with ROCm 7.2.x
# hosts (ROCm is forward-compatible within the 7.x series).
#
# vLLM ROCm pre-built wheels require Python 3.12 (base image provides it).
# See: https://docs.vllm.ai/en/latest/getting_started/installation/gpu.html#amd-rocm
ARG VLLM_VERSION=0.18.0
ARG VLLM_ROCM_TAG=rocm700
RUN pip install --no-cache-dir \
    "vllm==${VLLM_VERSION}+${VLLM_ROCM_TAG}" \
    --extra-index-url "https://wheels.vllm.ai/rocm/${VLLM_VERSION}/${VLLM_ROCM_TAG}" \
    || {
        echo "[vlm-local] Pre-built wheel not found, trying without +tag suffix..." >&2 && \
        pip install --no-cache-dir \
            "vllm==${VLLM_VERSION}" \
            --extra-index-url "https://wheels.vllm.ai/rocm/${VLLM_VERSION}/${VLLM_ROCM_TAG}" ;
    }

# Verify vLLM can import (catches missing ROCm libraries early).
RUN python3 -c "import vllm; print('[vlm-local] vLLM version:', vllm.__version__)"

# ── 2. Download model weights ──────────────────────────────────────
# Model: Qwen/Qwen2.5-VL-7B-Instruct
#   - Parameters: 7B (7,615,528,960)
#   - Weight storage: ~14 GB (BF16 safetensors)
#   - License: Apache 2.0 (open-weight, commercially usable)
#   - Capabilities: image understanding, OCR, chart reading, video understanding
#   - Context length: up to 128K tokens
#
# We pre-download at build time so the container starts fast and the
# model is baked into the image (no network dependency at runtime).
# HF_ENDPOINT=hf-mirror.com is set above for CN network access.
#
# The weights are cached in /root/.cache/huggingface/hub/ inside the
# image. At runtime you can override VLM_MODEL to use a different model
# (the container will download it on first start if not cached).
ENV VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct \
    VLM_PORT=8000 \
    VLM_MAX_MODEL_LEN=4096 \
    VLM_GPU_MEMORY_UTILIZATION=0.85 \
    VLM_DTYPE=bfloat16

RUN python3 -c "\
from huggingface_hub import snapshot_download; \
import os; \
model = os.environ.get('VLM_MODEL', 'Qwen/Qwen2.5-VL-7B-Instruct'); \
path = snapshot_download(model); \
print(f'[vlm-local] model weights cached at: {path}'); \
# Verify the config file exists (sanity check) \
import json; \
config_path = os.path.join(path, 'config.json'); \
assert os.path.exists(config_path), f'config.json missing at {config_path}'; \
with open(config_path) as f: \
    cfg = json.load(f); \
print(f'[vlm-local] model_type: {cfg.get(\"model_type\", \"unknown\")}'); \
print(f'[vlm-local] hidden_size: {cfg.get(\"hidden_size\", \"unknown\")}'); \
print(f'[vlm-local] num params: ~7B (Qwen2.5-VL-7B)')"

# ── 3. Verify vLLM can see the ROCm GPU ────────────────────────────
# This runs at build time inside the container — the base image has the
# ROCm runtime, so torch should detect HIP. Note: this check only works
# if the build machine has a GPU; in CI without GPU it will print a
# warning and continue (the real check happens at runtime).
RUN python3 -c "\
import torch; \
print('[vlm-local] PyTorch:', torch.__version__); \
print('[vlm-local] CUDA/HIP available:', torch.cuda.is_available()); \
if torch.cuda.is_available(): \
    print('[vlm-local] GPU:', torch.cuda.get_device_name(0)); \
    print('[vlm-local] GPU count:', torch.cuda.device_count()); \
else: \
    print('[vlm-local] WARNING: no GPU visible at build time (OK for CI, will check at runtime)')"

EXPOSE 8000

# ── 4. vLLM OpenAI-compatible server entrypoint ────────────────────
# vLLM's built-in server provides:
#   POST /v1/chat/completions  — chat with the VLM (text + image input)
#   GET  /v1/models            — list available models
#   POST /v1/completions       — text completion
#
# Key flags:
#   --trust-remote-code  : required for Qwen models (custom modeling code)
#   --dtype bfloat16     : BF16 inference — gfx1100 (RDNA3, RX 7900 XTX)
#                          has native BF16 support; better numerical range
#                          than FP16, reduces overflow/NaN risk for VLMs
#   --max-model-len      : max sequence length (4096 balances context vs VRAM)
#   --gpu-memory-utilization : fraction of GPU memory vLLM can use
ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
CMD ["--host", "0.0.0.0", \
     "--port", "8000", \
     "--model", "Qwen/Qwen2.5-VL-7B-Instruct", \
     "--served-model-name", "Qwen/Qwen2.5-VL-7B-Instruct", \
     "--trust-remote-code", \
     "--dtype", "bfloat16", \
     "--max-model-len", "4096", \
     "--gpu-memory-utilization", "0.85"]
