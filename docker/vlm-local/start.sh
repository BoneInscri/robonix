#!/usr/bin/env bash
# Local VLM Server launcher — runs an OpenAI-compatible VLM on the local
# AMD Radeon GPU via ROCm, so that robonix pilot's VLM inference stays
# on-device instead of calling a remote API.
#
# ── What this runs ──────────────────────────────────────────────────
# Inference framework: vLLM (https://docs.vllm.ai)
#   - High-throughput LLM/VLM serving engine with ROCm backend
#   - Provides OpenAI-compatible REST API out of the box
#   - Uses PagedAttention for efficient KV-cache management
#
# Model: Qwen/Qwen2.5-VL-7B-Instruct (default, override with VLM_MODEL)
#   - 7B parameters, ~14 GB weights (BF16 safetensors)
#   - Vision-Language: accepts text + images in the same conversation
#   - License: Apache 2.0 (open-weight, commercially usable)
#   - Capabilities: image understanding, OCR, chart/graph reading,
#     object localization, video understanding
#   - VRAM requirement: >=16 GB (BF16), 24 GB recommended
#   - Context length: up to 128K (we cap at 4096 for VRAM efficiency)
#
# Other supported models (set VLM_MODEL):
#   Qwen/Qwen2.5-VL-3B-Instruct    — 3B params, ~6 GB,  for >=8 GB VRAM
#   Qwen/Qwen2.5-VL-7B-Instruct    — 7B params, ~14 GB, for >=16 GB VRAM (default)
#   Qwen/Qwen2.5-VL-72B-Instruct   — 72B params, ~145 GB, for MI300X
#   Qwen/Qwen2.5-7B-Instruct        — text-only, 7B params (if vision not needed)
#
# ── Usage ───────────────────────────────────────────────────────────
#   bash docker/vlm-local/start.sh --build   # build image + start server
#   bash docker/vlm-local/start.sh            # start (use existing image)
#   bash docker/vlm-local/start.sh --stop     # stop the server
#   bash docker/vlm-local/start.sh --logs     # tail server logs
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
MAX_MODEL_LEN="${VLM_MAX_MODEL_LEN:-4096}"
GPU_MEM_UTIL="${VLM_GPU_MEMORY_UTILIZATION:-0.85}"
DTYPE="${VLM_DTYPE:-half}"

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
    # Show GPU info
    if command -v rocm-smi &>/dev/null; then
        echo "[vlm-local] GPU info:"
        rocm-smi --showproductname --showmeminfo vram 2>/dev/null || true
    fi
elif [[ "$GPU_BACKEND" == "cuda" ]]; then
    echo "[vlm-local] NVIDIA CUDA GPU detected"
    GPU_ARGS="--gpus all"
else
    echo "[vlm-local] WARNING: no GPU detected — VLM will fail to start" >&2
    echo "[vlm-local] Set ROBONIX_GPU_BACKEND=rocm or install rocm-smi" >&2
fi

# ── Parse args ─────────────────────────────────────────────────────
DO_BUILD=0
DO_STOP=0
DO_LOGS=0
for arg in "$@"; do
    case "$arg" in
        --build) DO_BUILD=1 ;;
        --stop)  DO_STOP=1 ;;
        --logs)  DO_LOGS=1 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

if [[ "$DO_STOP" == "1" ]]; then
    echo "[vlm-local] stopping $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    exit 0
fi

if [[ "$DO_LOGS" == "1" ]]; then
    docker logs -f "$CONTAINER_NAME" 2>&1
    exit 0
fi

# ── Build ──────────────────────────────────────────────────────────
if [[ "$DO_BUILD" == "1" ]] || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[vlm-local] building image $IMAGE_NAME..."
    echo "[vlm-local]   model: $MODEL (~14 GB for 7B, ~6 GB for 3B)"
    echo "[vlm-local]   framework: vLLM with ROCm backend"
    echo "[vlm-local]   this will take 15-30 min (downloads weights + compiles ROCm kernels)"
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
else
    echo "[vlm-local] image $IMAGE_NAME found, skipping build"
fi

# ── Run ────────────────────────────────────────────────────────────
echo "[vlm-local] starting VLM server:"
echo "[vlm-local]   model:      $MODEL"
echo "[vlm-local]   framework:  vLLM (OpenAI-compatible API)"
echo "[vlm-local]   port:       $PORT"
echo "[vlm-local]   max_len:    $MAX_MODEL_LEN"
echo "[vlm-local]   gpu_mem:    $GPU_MEM_UTIL"
echo "[vlm-local]   dtype:      $DTYPE"
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
    --dtype "$DTYPE" \
    --max-model-len "$MAX_MODEL_LEN" \
    --gpu-memory-utilization "$GPU_MEM_UTIL"

echo "[vlm-local] VLM server starting in background (container: $CONTAINER_NAME)"
echo "[vlm-local] Model loading takes 30-90s depending on disk/GPU speed..."
echo ""

# ── Health check ───────────────────────────────────────────────────
echo "[vlm-local] Waiting for server to be ready..."
READY=0
for i in $(seq 1 180); do
    # Check if container is still running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[vlm-local] ERROR: container exited unexpectedly" >&2
        echo "[vlm-local] Last 30 lines of logs:" >&2
        docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
        exit 1
    fi

    # Check if API is responding
    if curl -s "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        READY=1
        break
    fi

    # Print progress dots every 10s
    if (( i % 5 == 0 )); then
        echo -n "."
    fi
    sleep 2
done
echo ""

if [[ "$READY" == "1" ]]; then
    echo "[vlm-local] ✅ VLM server ready at http://127.0.0.1:${PORT}/v1"
    echo "[vlm-local] Model: $MODEL (7B params, ~14 GB)"
    echo ""
    echo "[vlm-local] Test it:"
    echo "  curl http://127.0.0.1:${PORT}/v1/models"
    echo ""
    echo "[vlm-local] Set these before rbnx boot:"
    echo "  export VLM_BASE_URL=http://127.0.0.1:${PORT}/v1"
    echo "  export VLM_API_KEY=dummy-key"
    echo "  export VLM_MODEL=$MODEL"
    echo ""
    echo "[vlm-local] View logs: bash $0 --logs"
    echo "[vlm-local] Stop:      bash $0 --stop"
    exit 0
else
    echo "[vlm-local] WARNING: server did not become ready within 360s" >&2
    echo "[vlm-local] Check logs: bash $0 --logs" >&2
    exit 1
fi
