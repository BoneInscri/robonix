#!/usr/bin/env bash
# Local VLM Server launcher — runs an OpenAI-compatible VLM on the local
# AMD Radeon GPU via ROCm, so that robonix pilot's VLM inference stays
# on-device instead of calling a remote API.
#
# Usage:
#   bash docker/vlm-local/start.sh          # build + run
#   bash docker/vlm-local/start.sh --build  # force rebuild
#   bash docker/vlm-local/start.sh --stop   # stop the server
#
# After the server is up, export these before `rbnx boot`:
#   export VLM_BASE_URL=http://127.0.0.1:8000/v1
#   export VLM_API_KEY=dummy-key
#   export VLM_MODEL=Qwen/Qwen2.5-VL-7B-Instruct
#
# The robonix_manifest.yaml's pilot.vlm block reads ${VLM_*} and points
# pilot at this local server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="robonix-vlm"
CONTAINER_NAME="robonix-vlm"
PORT="${VLM_PORT:-8000}"
MODEL="${VLM_MODEL:-Qwen/Qwen2.5-VL-7B-Instruct}"

# ── GPU backend detection ──────────────────────────────────────────
GPU_ARGS=""
GPU_BACKEND="${ROBONIX_GPU_BACKEND:-}"

if [[ -z "$GPU_BACKEND" ]]; then
    if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null; then
        GPU_BACKEND="rocm"
    elif [[ -e /dev/kfd ]]; then
        GPU_BACKEND="rocm"
    elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        GPU_BACKEND="cuda"
    fi
fi

if [[ "$GPU_BACKEND" == "rocm" ]]; then
    echo "[vlm-local] AMD ROCm GPU detected"
    GPU_ARGS="--device=/dev/kfd --device=/dev/dri --group-add video"
    export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
    export ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"
elif [[ "$GPU_BACKEND" == "cuda" ]]; then
    echo "[vlm-local] NVIDIA CUDA GPU detected"
    GPU_ARGS="--gpus all"
else
    echo "[vlm-local] WARNING: no GPU detected — VLM will fail to start" >&2
fi

# ── Parse args ─────────────────────────────────────────────────────
DO_BUILD=0
DO_STOP=0
for arg in "$@"; do
    case "$arg" in
        --build) DO_BUILD=1 ;;
        --stop)  DO_STOP=1 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

if [[ "$DO_STOP" == "1" ]]; then
    echo "[vlm-local] stopping $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    exit 0
fi

# ── Build ──────────────────────────────────────────────────────────
if [[ "$DO_BUILD" == "1" ]] || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[vlm-local] building image $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
else
    echo "[vlm-local] image $IMAGE_NAME found, skipping build"
fi

# ── Run ────────────────────────────────────────────────────────────
echo "[vlm-local] starting VLM server: model=$MODEL port=$PORT"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --network host \
    $GPU_ARGS \
    -e HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}" \
    -e ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}" \
    -e HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}" \
    -v "${VLM_MODEL_CACHE:-$HOME/.cache/huggingface}:/root/.cache/huggingface" \
    "$IMAGE_NAME" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --model "$MODEL" \
    --served-model-name "$MODEL" \
    --trust-remote-code \
    --dtype half \
    --max-model-len "${VLM_MAX_MODEL_LEN:-4096}" \
    --gpu-memory-utilization "${VLM_GPU_MEMORY_UTILIZATION:-0.85}"

echo "[vlm-local] VLM server starting in background (container: $CONTAINER_NAME)"
echo "[vlm-local] Waiting for server to be ready..."
for i in $(seq 1 120); do
    if curl -s "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        echo "[vlm-local] VLM server ready at http://127.0.0.1:${PORT}/v1"
        echo "[vlm-local] Model: $MODEL"
        echo ""
        echo "[vlm-local] Set these before rbnx boot:"
        echo "  export VLM_BASE_URL=http://127.0.0.1:${PORT}/v1"
        echo "  export VLM_API_KEY=dummy-key"
        echo "  export VLM_MODEL=$MODEL"
        exit 0
    fi
    sleep 2
done

echo "[vlm-local] WARNING: server did not become ready within 240s" >&2
echo "[vlm-local] Check logs: docker logs $CONTAINER_NAME" >&2
exit 1
