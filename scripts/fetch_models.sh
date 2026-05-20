#!/usr/bin/env bash
# Declarative, idempotent weight provisioning for the Pixal3D-T path.
#
# Pattern: the image is weight-free; weights live on the host bind-mount
# ./data/models (-> /opt/ComfyUI/models). This script (re-)populates that volume
# on any machine. Re-running it is safe: each model is skipped if already
# present. The HF token is read from the HF_TOKEN env (compose injects it from a
# gitignored .env) and is never baked into an image layer.
#
# Run:  docker compose --profile setup run --rm model-fetch
set -euo pipefail

MODELS=/opt/ComfyUI/models

dl() {  # repo_id  local_subdir  [allow_pattern ...]
  local repo="$1" sub="$2"; shift 2
  local dest="$MODELS/$sub"
  # Assumption-free idempotency: a marker written only after a complete snapshot.
  if [ -e "$dest/.fetch_complete" ]; then
    echo "[fetch] OK (cached): $repo -> $sub"
    return 0
  fi
  echo "[fetch] downloading: $repo -> $sub"
  local allow_py="None"
  if [ "$#" -gt 0 ]; then
    allow_py="[$(printf "'%s'," "$@")]"
  fi
  python - "$repo" "$dest" "$allow_py" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo, dest, allow = sys.argv[1], sys.argv[2], sys.argv[3]
allow = None if allow == "None" else eval(allow)
snapshot_download(repo_id=repo, local_dir=dest, allow_patterns=allow)
PY
  touch "$dest/.fetch_complete"
  echo "[fetch] done: $repo"
}

# 1) DinoV3 — GATED. Not auto-downloaded by the node (nodes.py:378 hard-raises).
if [ -z "${HF_TOKEN:-}" ] && [ ! -e "$MODELS/facebook/dinov3-vitl16-pretrain-lvd1689m/model.safetensors" ]; then
  echo "[fetch] ERROR: HF_TOKEN is not set and DinoV3 is missing." >&2
  echo "        Accept the license at" >&2
  echo "        https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m" >&2
  echo "        then put HF_TOKEN=hf_... in ./.env and re-run." >&2
  exit 1
fi
dl facebook/dinov3-vitl16-pretrain-lvd1689m \
   facebook/dinov3-vitl16-pretrain-lvd1689m

# 2) Pixal3D-T — public; the node auto-downloads it, but pre-seeding makes the
#    first generation fast and the box air-gap-capable.
dl TencentARC/Pixal3D-T  TencentARC/Pixal3D-T

# 3) MoGe (camera/depth for Pixal3D) — public.
dl Ruicheng/moge-2-vitl  Ruicheng/moge-2-vitl

# 4) TRELLIS-image-large sparse-structure decoder — only the two ss_dec files.
dl microsoft/TRELLIS-image-large \
   microsoft/TRELLIS-image-large \
   "ckpts/ss_dec_conv3d_16l8_fp16.json" "ckpts/ss_dec_conv3d_16l8_fp16.safetensors"

# 5) Trellis2LoadModel unconditionally seeds reconviagen_pipeline.json into
#    models/microsoft/TRELLIS.2-4B/ (even for Pixal3D-T) and shutil.copyfile
#    does not create parent dirs. Pre-create the dir so the node doesn't crash.
mkdir -p "$MODELS/microsoft/TRELLIS.2-4B"
echo "[fetch] ensured $MODELS/microsoft/TRELLIS.2-4B (Trellis2LoadModel needs it)"

echo "[fetch] All Pixal3D-T weights provisioned in $MODELS"
echo "[fetch] NAF (valeoai/NAF) is fetched at first generation via torch.hub;"
echo "[fetch] set PREWARM_NAF=1 on the main service to cache it into TORCH_HOME."
