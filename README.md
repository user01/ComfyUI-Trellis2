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

## What `make fetch-models` provisions

Pre-populates `./data/models` (host bind-mount) idempotently with everything
the **Pixal3D-T API** path needs. Re-run any time on a fresh box / new
volume — already-present model sets are skipped via per-repo
`.fetch_complete` markers.

**Required in `.env`:**

- `HF_TOKEN` — a Hugging Face access token with at least **read** scope.
  DinoV3 is a **gated** model, so you must first accept its license at
  <https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m> using
  the same HF account that owns the token. Without that the fetch fails
  fast with a clear "HF_TOKEN is not set and DinoV3 is missing" message.
- `TRELLIS_API_KEY` — bearer used at run time by the API. Not used by
  `fetch-models`; you can set it later.

**Fetches** (~26 GB total):

| Repo | Size | Gated |
|---|---|---|
| `facebook/dinov3-vitl16-pretrain-lvd1689m` | ~1.2 GB | yes |
| `TencentARC/Pixal3D-T` | ~23 GB | no |
| `Ruicheng/moge-2-vitl` | ~1.3 GB | no |
| `microsoft/TRELLIS-image-large` (the two `ss_dec` files only) | ~140 MB | no |

One extra model — `valeoai/NAF` — auto-downloads via `torch.hub` at the
**first Pixal3D-T generation**, not during `fetch-models`. It is cached in
the mounted `data/models/.torch_hub` and reused after.

**Not fetched** — `Trellis2LoadModel` in the ComfyUI UI also offers
`microsoft/TRELLIS.2-4B` and `visualbruno/TRELLIS.2-4B-FP8` for other
(non-Pixal3D-T) workflows. Those would auto-download on first selection in
the UI. The hosted API only exposes Pixal3D-T, so for API use these four
are sufficient.

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
