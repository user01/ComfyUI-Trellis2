# Pixal3D-T: workflows & the hosted API

There are two ways to run Pixal3D-T in this image. They share the same
ComfyUI underneath.

## A) The ComfyUI UI (drive it yourself)

The example workflows are **baked into the image** — no downloading, no
importing from disk. They live in ComfyUI's user library at
`/opt/ComfyUI/user/default/workflows/` (copied from `example_workflows/`).

1. Open `http://<box>:8188`.
2. Open the **Workflows** panel (sidebar / top-left menu → Workflows). You'll
   see `MeshOnly_Pixal3D` and `MeshWithTexturing_Pixal3D` already listed.
   Click one to load it.
3. In the **Image with Transparency** node, pick or upload your input image.
   (Upload via that node's widget; files land in `/opt/ComfyUI/input`, which
   is the host `./data/input`.)
4. The **Trellis2 - LoadModel** node is already set to
   `modelname = TencentARC/Pixal3D-T`. Its `backend` widget can stay as-is;
   if a run errors on attention, set `backend = sdpa` (flash_attn/xformers
   are intentionally not installed — the code falls back to torch SDPA).
5. **Queue Prompt**. First run is slow (model load + NAF download); later
   runs are faster. The `.glb` is written by the **Trellis2 - Export Mesh**
   node into `/opt/ComfyUI/output` → host `./data/output`.

`MeshOnly_*` = geometry only (faster). `MeshWithTexturing_*` = textured GLB
via the in-cascade texture path (1536 shape + 1024 texture; slower).
Pixal3D-T only runs the 1024/1536 cascade — do not set resolution 512.

## B) The hosted HTTP API (image in → GLB out)

`api/workflows/*.api.json` are the **API/prompt-format** equivalents of the
UI workflows above. `api_server.py` loads one of these, swaps in your
uploaded image, forces `backend=sdpa`, gives the export a job-scoped name,
submits it to ComfyUI, and serves the resulting `.glb`. See the repo root /
the plan for the endpoint contract (`POST /v1/generate`, `GET /v1/jobs/{id}`,
`GET /v1/jobs/{id}/model`, bearer auth via `TRELLIS_API_KEY`).

Default template: `pixal3d_textured.api.json` (override with
`WORKFLOW_TEMPLATE`). `pixal3d_mesh.api.json` is the geometry-only variant.

## Regenerating the API templates

The `*.api.json` files are generated from the UI workflows by driving
ComfyUI's own exporter (no hand-conversion). If you change a workflow in
`example_workflows/`, regenerate with either:

- **ComfyUI UI**: load the workflow, top-left menu → Workflow →
  **Export (API)**, save over the matching `api/workflows/*.api.json`.
- **Headless** (what was used here): a short Playwright script that calls
  ComfyUI's `app.graphToPrompt()` against `http://localhost:8188`. The
  server self-reloads the template on the next request — no rebuild needed
  unless you want it re-baked into the image.

These files are committed, so they're baked into every image build via the
final `COPY` — a fresh box has them with no manual export step.
