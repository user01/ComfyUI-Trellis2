#!/usr/bin/env bash
# Entrypoint for the ComfyUI-Trellis2 / Pixal3D-T image.
set -euo pipefail

# nodes.py sets this in-process, but some allocations happen before the node
# runs, so set it at the container level too.
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
# Persisted across runs via the mounted volume (NAF / torch.hub cache).
export TORCH_HOME="${TORCH_HOME:-/opt/ComfyUI/models/.torch_hub}"
export HF_HOME="${HF_HOME:-/root/.cache/huggingface}"
# nvdiffrast renders headless via EGL.
export PYOPENGL_PLATFORM="${PYOPENGL_PLATFORM:-egl}"
mkdir -p "$TORCH_HOME"

# Optional: pre-fetch the valeoai/NAF model so the first Pixal3D-T generation is
# not blocked on a download, and so any natten failure surfaces at startup
# instead of mid-run. Enable with PREWARM_NAF=1 (needs network on first start;
# afterwards it is cached in the mounted TORCH_HOME).
if [ "${PREWARM_NAF:-0}" = "1" ]; then
    echo "[entrypoint] Pre-warming valeoai/NAF (exercises natten)..."
    python -c "import torch, torch.hub; torch.hub.load('valeoai/NAF','naf',pretrained=True,trust_repo=True); print('[entrypoint] NAF + natten OK')"
fi

# Reminder: facebook/dinov3-vitl16-pretrain-lvd1689m is GATED and is NOT
# auto-downloaded (nodes.py:378 hard-raises). Pre-place it in the mounted
# models volume on the host before the first Pixal3D-T run.
if [ ! -f /opt/ComfyUI/models/facebook/dinov3-vitl16-pretrain-lvd1689m/model.safetensors ]; then
    echo "[entrypoint] WARNING: DinoV3 weights not found at" \
         "models/facebook/dinov3-vitl16-pretrain-lvd1689m/model.safetensors -" \
         "Pixal3D-T (and all TRELLIS.2) runs will fail until it is pre-placed."
fi

COMFY_PORT="${COMFY_PORT:-8188}"

# MODE=comfyui : just ComfyUI on 0.0.0.0:8188 (the original behavior).
# MODE=api     : ComfyUI in the background (still on 0.0.0.0:8188 so the UI is
#                usable for the one-time API-format export), then the hosted
#                Pixal3D-T API in the foreground on 0.0.0.0:${API_PORT:-8000}.
if [ "${MODE:-api}" = "comfyui" ]; then
    exec python /opt/ComfyUI/main.py --listen 0.0.0.0 --port "$COMFY_PORT" "$@"
fi

echo "[entrypoint] MODE=api — starting ComfyUI (background) + Pixal3D-T API"
python /opt/ComfyUI/main.py --listen 0.0.0.0 --port "$COMFY_PORT" "$@" &
COMFY_PID=$!
trap 'kill $COMFY_PID 2>/dev/null || true' TERM INT

# Wait for ComfyUI to be ready (or die) before starting the API.
for _ in $(seq 1 240); do
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        echo "[entrypoint] ComfyUI exited during startup" >&2; exit 1
    fi
    if python -c "import sys,urllib.request; urllib.request.urlopen('http://127.0.0.1:${COMFY_PORT}/system_stats',timeout=2)" >/dev/null 2>&1; then
        echo "[entrypoint] ComfyUI ready"; break
    fi
    sleep 2
done

export COMFY_URL="http://127.0.0.1:${COMFY_PORT}"
exec uvicorn api_server:app --host 0.0.0.0 --port "${API_PORT:-8000}" \
     --app-dir /opt/ComfyUI/custom_nodes/ComfyUI-Trellis2
