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

# 2) Bundled Linux cp312 / torch2.9.1 compiled extensions, --no-deps so their
#    loose "torch>=2.4" metadata cannot move the pinned torch.
#    EXCLUDED on purpose:
#    - nvdiffrec_render: only the projection Mesh Texturing node (Pixal3D-T
#      forbids it, nodes.py:2314), never imported at load; drags tinycudann.
#    - flex_gemm, o_voxel: the upstream Linux wheels are compiled for sm_120
#      (Blackwell) ONLY — verified via cuobjdump. This box is an RTX 3090
#      (sm_86); those kernels raise cudaErrorNoKernelImageForDevice. They are
#      rebuilt from source for sm_86 in step 2b. cumesh (sm_86) + nvdiffrast
#      (runtime JIT) from the bundled set are fine.
RUN uv pip install --python $PYBIN --no-deps \
        wheels/Linux/Torch291/cumesh-1.0-cp312-cp312-linux_x86_64.whl \
        wheels/Linux/Torch291/nvdiffrast-0.4.0-cp312-cp312-linux_x86_64.whl \
        wheels/Linux/Torch291/custom_rasterizer-0.1-cp312-cp312-linux_x86_64.whl

# 2b) Build flex_gemm + o_voxel from source for sm_86 (Ampere / RTX 3090).
#     nodes.py hard-imports flex_gemm.ops.grid_sample.grid_sample_3d and uses
#     o_voxel CUDA mesh ops regardless of sparse-conv backend, so both must
#     have sm_86 kernels. Built against the already-installed torch 2.9.1+cu128
#     (devel base provides nvcc 12.8). --no-build-isolation so they compile
#     against that exact torch; --no-deps so they cannot drag a different one.
# Pinned to specific commits (authorized by the operator) for auditability /
# reproducibility — these are the upstream author's own repos that this repo's
# README "Custom Build" section documents as the official build sources.
ARG FLEXGEMM_SHA=db388bd17c34abc697792aa718dca780734c2783
ARG OVOXEL_SHA=65d1e13b4a92296036044df0633242bb9e95abf6
ENV TORCH_CUDA_ARCH_LIST="8.6" MAX_JOBS="4"
RUN uv pip install --python $PYBIN setuptools wheel ninja pybind11 \
    && uv pip install --python $PYBIN --no-build-isolation --no-deps \
        "git+https://github.com/visualbruno/FlexGEMM@${FLEXGEMM_SHA}" \
        "o_voxel @ git+https://github.com/visualbruno/TRELLIS.2@${OVOXEL_SHA}#subdirectory=o-voxel"

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
