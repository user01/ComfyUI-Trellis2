# Self-contained image: ComfyUI + ComfyUI-Trellis2 + a uv-managed venv, pinned
# for the Pixal3D-T path on an Ampere GPU (RTX 3090, CC 8.6).
#
# Pin rationale (see /home/erik/.claude/plans/review-this-implementation-i-m-hazy-breeze.md):
#   torch 2.9.1+cu128 / cp312  -> only bundled-wheel torch line with a prebuilt natten >=0.21.5
#   natten 0.21.5+torch290cu128 (whl.natten.org) -> NAF/Pixal3D needs natten; no source build
#   devel base                 -> keeps a natten source-build escape hatch (not expected)
#
# Layering note: only the install INPUTS (requirements.txt + the Torch291 wheels)
# are copied before the heavy installs, and the full repo source is copied LAST,
# so editing node source / later steps does not bust the multi-GB torch layer.
ARG CUDA_IMAGE=nvidia/cuda:12.8.1-devel-ubuntu22.04
FROM ${CUDA_IMAGE}

ARG COMFYUI_REF=master
ENV DEBIAN_FRONTEND=noninteractive \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/cuda/bin:$PATH \
    CUDA_HOME=/usr/local/cuda \
    PYTHONUNBUFFERED=1 \
    PYBIN=/opt/venv/bin/python

# System deps: git/build for the (unlikely) natten source fallback; GL/EGL for
# nvdiffrast headless rendering; libgomp/libgl for open3d/opencv.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential ninja-build cmake \
        libgl1 libglib2.0-0 libgomp1 libegl1 libgles2 libglvnd-dev \
        ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# uv, pinned to match the host (0.7.20).
COPY --from=ghcr.io/astral-sh/uv:0.7.20 /uv /uvx /bin/

# Python 3.12 + venv (cp312 matches the bundled wheels/Linux/Torch291 set).
RUN uv python install 3.12 && uv venv --python 3.12 /opt/venv

# ComfyUI host (the custom node hard-imports comfy.* / folder_paths and cannot
# run standalone).
RUN git clone --depth 1 --branch ${COMFYUI_REF} \
        https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI

WORKDIR /opt/ComfyUI/custom_nodes/ComfyUI-Trellis2

# Copy ONLY the install inputs first (keeps the torch/wheels layers cacheable).
COPY requirements.txt ./requirements.txt
COPY wheels/Linux/Torch291 ./wheels/Linux/Torch291

# --- Ordered install (order protects the torch pin) ---------------------------
# 1) torch trio FIRST from the cu128 index. torchaudio MUST be pinned to the
#    matching 2.9.1 — ComfyUI's own requirements otherwise pull torchaudio
#    2.11.0 (built for torch 2.11) and ComfyUI fails to import with
#    "undefined symbol: torch_library_impl".
RUN uv pip install --python $PYBIN --index-strategy unsafe-best-match \
        --extra-index-url https://download.pytorch.org/whl/cu128 \
        torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1

# ── GPU architecture knob ────────────────────────────────────────────────────
# Build per target GPU:  --build-arg CUDA_ARCH=8.6   (Ampere, RTX 3090; default)
#                        --build-arg CUDA_ARCH=12.0  (Blackwell, RTX PRO 6000)
# Drives TORCH_CUDA_ARCH_LIST for every source/JIT-built CUDA extension below.
ARG CUDA_ARCH=8.6
ENV TORCH_CUDA_ARCH_LIST="${CUDA_ARCH}" MAX_JOBS="4"
# Pinned upstream source commits (operator-authorized; the repo's README
# "Custom Build" section documents these as the official build sources).
ARG FLEXGEMM_SHA=db388bd17c34abc697792aa718dca780734c2783
ARG OVOXEL_SHA=65d1e13b4a92296036044df0633242bb9e95abf6
ARG NVDIFFRAST_SHA=253ac4fcea7de5f396371124af597e6cc957bfae
ARG CUMESH_SHA=d10e54c30ddd03d11472c1431693f985501c7966

# 2) custom_rasterizer: bundled wheel, --no-deps. Unused by Pixal3D-T (never
#    imported in the repo) but harmless; kept for parity. nvdiffrec_render is
#    excluded on purpose (projection Mesh Texturing only — Pixal3D-T forbids
#    it, nodes.py:2314 — and it drags the build-hell tinycudann).
RUN uv pip install --python $PYBIN --no-deps \
        wheels/Linux/Torch291/custom_rasterizer-0.1-cp312-cp312-linux_x86_64.whl

# 2b) GPU-arch extensions, all targeting ${CUDA_ARCH}. The bundled Linux
#     flex_gemm / o_voxel / nvdiffrast wheels are sm_120 (Blackwell) ONLY
#     (verified via cuobjdump / runtime CUDA err 209), so they are rebuilt
#     from the upstream-author / NVlabs sources for the chosen arch:
#       flex_gemm  - nodes.py hard-imports flex_gemm.ops.grid_sample
#       o_voxel    - CUDA mesh ops used by the pipeline
#       nvdiffrast - official NVlabs v0.4.0; JIT-builds its rasterizer plugin
#                    at first use against TORCH_CUDA_ARCH_LIST
#     cumesh: the bundled wheel is genuinely sm_86 — kept as-is for the
#     default (verified) 8.6 build; source-built from pinned CuMesh otherwise.
#     Built --no-build-isolation (against the installed torch 2.9.1+cu128,
#     devel base = nvcc 12.8) and --no-deps (no torch drift).
# NB: each source package is installed in its OWN `uv pip install` call so
# they build strictly sequentially. Passing multiple specs to one call lets
# uv build them in parallel (uv is parallel-first), which combined with
# per-package MAX_JOBS=4 spawns ~12 concurrent g++/nvcc processes compiling
# CUDA template code — gcc OOMs / segfaults. Sequential keeps the resource
# budget bounded; build16 (working) used this same pattern.
RUN uv pip install --python $PYBIN setuptools wheel ninja pybind11 \
 && uv pip install --python $PYBIN --no-build-isolation --no-deps \
        "git+https://github.com/visualbruno/FlexGEMM@${FLEXGEMM_SHA}" \
 && uv pip install --python $PYBIN --no-build-isolation --no-deps \
        "o_voxel @ git+https://github.com/visualbruno/TRELLIS.2@${OVOXEL_SHA}#subdirectory=o-voxel" \
 && uv pip install --python $PYBIN --no-build-isolation --no-deps \
        "git+https://github.com/NVlabs/nvdiffrast@${NVDIFFRAST_SHA}" \
 && if [ "${CUDA_ARCH}" = "8.6" ]; then \
        uv pip install --python $PYBIN --no-deps \
            wheels/Linux/Torch291/cumesh-1.0-cp312-cp312-linux_x86_64.whl ; \
    else \
        uv pip install --python $PYBIN --no-build-isolation --no-deps \
            "cumesh @ git+https://github.com/visualbruno/CuMesh@${CUMESH_SHA}" ; \
    fi

# 3) Repo deps + UNDECLARED deps the package imports at module load but never
#    lists (requirements.txt/pyproject omit them). Verified by import-graph scan:
#      plyfile, zstandard -> o_voxel/io/{ply,vxz}.py (hidden inside the wheel)
#      easydict -> samplers/flow_euler.py, renderers/*
#      utils3d  -> trellis2/utils/render_utils.py  (the TRELLIS-family GIT package;
#                  the PyPI "utils3d" hard-pins an old open3d with no cp312 wheel,
#                  so install from git --no-deps; its runtime deps are already in)
#      diffusers/lpips/omegaconf/accelerate -> lazy/optional paths (cheap insurance)
#    transformers/einops/scikit-image/etc. come from ComfyUI's own requirements.
RUN uv pip install --python $PYBIN -r requirements.txt \
    && uv pip install --python $PYBIN \
        trimesh huggingface_hub \
        plyfile zstandard easydict diffusers lpips omegaconf accelerate \
        onnxruntime \
        fastapi "uvicorn[standard]" python-multipart httpx \
    && uv pip install --python $PYBIN --no-deps \
        "git+https://github.com/EasternJournalist/utils3d.git"

# 4) natten from the NATTEN wheel index. --no-deps so it cannot drag a different
#    torch. Label is torch290 (built vs 2.9.0, ABI-compatible with 2.9.1).
RUN uv pip install --python $PYBIN --no-deps \
        --find-links https://whl.natten.org \
        "natten==0.21.5+torch290cu128"

# 5) ComfyUI's own requirements LAST, keeping the cu128 index pinned so a loose
#    torch spec there cannot pull a CPU/other-cuda build.
RUN uv pip install --python $PYBIN --index-strategy unsafe-best-match \
        --extra-index-url https://download.pytorch.org/whl/cu128 \
        -r /opt/ComfyUI/requirements.txt

# Fail the build immediately if anything above moved the torch trio off
# 2.9.1+cu128 (does not initialize CUDA, so it is build-safe). torchaudio is
# checked too: ComfyUI's requirements are the thing that drifts it.
RUN $PYBIN -c "import torch,torchvision,torchaudio,sys; \
print('torch',torch.__version__,'vision',torchvision.__version__,'audio',torchaudio.__version__,'cuda',torch.version.cuda); \
ok = torch.__version__=='2.9.1+cu128' and torchvision.__version__=='0.24.1+cu128' and torchaudio.__version__=='2.9.1+cu128'; \
sys.exit(0 if ok else 1)"
# NOTE: the compiled-extension + natten ABI smoke test is intentionally NOT run
# here: flex_gemm probes torch.cuda.get_device_name() at import, and `docker
# build` has no GPU. It runs at RUNTIME instead (entrypoint smoke check below,
# or: docker compose run --rm comfyui-trellis2 \
#     python -c "import cumesh,o_voxel,nvdiffrast.torch,custom_rasterizer,natten; \
#     from flex_gemm.ops.grid_sample import grid_sample_3d; print('ext ok')")

# Full repo source LAST (cache-cheap; edits here don't rebuild the install layers).
COPY . .

# Bake the example workflows into ComfyUI's user workflow library so they show
# up in the UI's Workflows browser out of the box — no external fetch needed.
RUN mkdir -p /opt/ComfyUI/user/default/workflows \
    && cp example_workflows/*.json /opt/ComfyUI/user/default/workflows/

WORKDIR /opt/ComfyUI
EXPOSE 8188 8000
ENTRYPOINT ["/opt/ComfyUI/custom_nodes/ComfyUI-Trellis2/docker-entrypoint.sh"]
