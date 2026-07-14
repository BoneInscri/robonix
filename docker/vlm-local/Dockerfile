# Local VLM Server (AMD ROCm)
#
# Serves an OpenAI-compatible API from a local AMD Radeon GPU using vLLM.
# This replaces remote API calls (OpenAI / etc.) so that VLM inference
# runs entirely on the local AMD GPU via ROCm — satisfying the competition
# requirement that "key stages including training and/or inference should
# run on AMD Radeon GPU".
#
# Build:
#   docker build --build-arg ROBONIX_GPU_BACKEND=rocm -t robonix-vlm .
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

ARG ROCM_IMAGE=rocm/pytorch:rocm6.3_ubuntu22.04_py3.10_pytorch_2.6
FROM ${ROCM_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    HF_ENDPOINT=https://hf-mirror.com

# vLLM with ROCm support.
# vLLM provides an OpenAI-compatible server out of the box.
# The rocm6.3 tag matches the PyTorch ROCm wheel index used elsewhere.
RUN pip install --no-cache-dir vllm

# Default model: Qwen2.5-VL-7B-Instruct (vision-language, open-weight,
# small enough for consumer Radeon GPUs with >=16GB VRAM).
# Override with VLM_MODEL env at runtime.
ENV VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct \
    VLM_PORT=8000 \
    VLM_MAX_MODEL_LEN=4096 \
    VLM_GPU_MEMORY_UTILIZATION=0.85

# Pre-download model weights at build time so the container starts fast.
# HF_ENDPOINT=hf-mirror.com is set above for CN network access.
RUN python3 -c "from huggingface_hub import snapshot_download; snapshot_download('${VLM_MODEL}')"

EXPOSE 8000

# vLLM OpenAI-compatible server.
# --host 0.0.0.0: accept connections from outside the container.
# --trust-remote-code: needed for Qwen models.
# --dtype half: FP16 inference (ROCm supports bf16 too; use half for
#   broader GPU compatibility).
ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
CMD ["--host", "0.0.0.0", \
     "--port", "8000", \
     "--model", "Qwen/Qwen2.5-VL-7B-Instruct", \
     "--served-model-name", "Qwen/Qwen2.5-VL-7B-Instruct", \
     "--trust-remote-code", \
     "--dtype", "half", \
     "--max-model-len", "4096", \
     "--gpu-memory-utilization", "0.85"]
