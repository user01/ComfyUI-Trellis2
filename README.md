# 🌀 ComfyUI-Trellis2 — Docker fork for Pixal3D-T

A self-contained Linux Docker build of
[visualbruno/ComfyUI-Trellis2](https://github.com/visualbruno/ComfyUI-Trellis2)
(wrapping [Microsoft/TRELLIS.2](https://github.com/microsoft/TRELLIS.2))
that runs the **`TencentARC/Pixal3D-T`** image → 3D pipeline behind a thin
async HTTP API. Image goes in, `.glb` comes out.

Verified end-to-end on **RTX 3090 (Ampere, sm_86)**; the GPU architecture
is a single build arg (`CUDA_ARCH`) for retargeting (e.g. Blackwell sm_120).

For the original node code, example workflows, model behaviour, and the
upstream build sources see the parent repo above.

---

## Quickstart

```
cp .env.example .env       # then fill in HF_TOKEN + TRELLIS_API_KEY
make build                 # ~30 min cold; CUDA_ARCH=12.0 make build for Blackwell
make fetch-models          # one-time, ~26 GB (gated DinoV3 + Pixal3D-T + MoGe + ss_dec)
make up                    # API on :8487, ComfyUI UI loopback on :8488
make health                # confirm everything is wired
```

## Generate a model (image in → `.glb` out)

```bash
KEY=$(grep ^TRELLIS_API_KEY= .env | cut -d= -f2-)

# Submit (mode=textured ~25 min, mode=mesh ~10 min)
JOB=$(curl -s -X POST http://localhost:8487/v1/generate \
        -H "Authorization: Bearer $KEY" \
        -F image=@your-photo.jpg \
        -F mode=mesh \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')
echo "$JOB"

# Poll until status == succeeded
curl -s -H "Authorization: Bearer $KEY" http://localhost:8487/v1/jobs/$JOB

# Fetch the GLB
curl -s -H "Authorization: Bearer $KEY" http://localhost:8487/v1/jobs/$JOB/model -o out.glb
```

The same `.glb` also lands on the host at `data/output/api_<JOB>*.glb`
(the output volume is bind-mounted).

## Browse the ComfyUI UI

The UI is **loopback-bound** (no auth on ComfyUI itself; only the API has
the bearer token). From a remote workstation, SSH-tunnel:

```
ssh -L 8488:127.0.0.1:8488 <user>@<box>
# then open http://localhost:8488 in your browser
```

Both Pixal3D-T workflows (`MeshOnly_Pixal3D`, `MeshWithTexturing_Pixal3D`)
are baked into ComfyUI's Workflows browser — no import step.

## Make targets

```
make help
```

`make build` accepts `CUDA_ARCH` (default `8.6`; `12.0` for Blackwell /
RTX PRO 6000). `make restart` recreates the container on the current image.

## Going deeper

`api/README.md` covers the API contract, the `mode=mesh|textured` switch,
how to regenerate the workflow templates if you edit them, and the
multi-architecture / Blackwell-readiness notes.

## 🙏 Acknowledgements

- Upstream node code, example workflows, and bundled Linux wheels:
  [visualbruno/ComfyUI-Trellis2](https://github.com/visualbruno/ComfyUI-Trellis2).
  Source builds use the upstream author's documented "Custom Build" repos
  at pinned commits: [`FlexGEMM`](https://github.com/visualbruno/FlexGEMM),
  [`CuMesh`](https://github.com/visualbruno/CuMesh), and the `o_voxel`
  subtree of [`TRELLIS.2`](https://github.com/visualbruno/TRELLIS.2);
  rasterization uses official [`NVlabs/nvdiffrast`](https://github.com/NVlabs/nvdiffrast).
- Discord community
- "Blackwell Fix" from <https://github.com/ThatButters/trellis2-blackwell-fix>
