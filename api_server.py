"""
Pixal3D-T hosted API — image in, .glb out.

A thin async wrapper over the local ComfyUI instance. It loads a ComfyUI
API-format workflow template (exported once from the UI), patches in the
uploaded image + sdpa backend + a job-scoped output name, submits it to
ComfyUI, and serves the resulting GLB.

Design (approved): async jobs, bearer-token auth, bound 0.0.0.0.
  POST /v1/generate            -> 202 {job_id}
  GET  /v1/jobs/{job_id}       -> {status, error?}
  GET  /v1/jobs/{job_id}/model -> the .glb (model/gltf-binary)
  GET  /healthz                -> no auth; readiness

Node lookup is by class_type and input names are resolved from ComfyUI's
/object_info at startup, so re-exporting the template (widget reordering)
does not break this.
"""
from __future__ import annotations

import asyncio
import copy
import glob
import json
import os
import secrets
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional

import httpx
from fastapi import (Depends, FastAPI, File, Form, HTTPException, UploadFile,
                     status)
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

COMFY_URL = os.environ.get("COMFY_URL", "http://127.0.0.1:8188").rstrip("/")
OUTPUT_DIR = Path(os.environ.get("COMFY_OUTPUT_DIR", "/opt/ComfyUI/output"))
DINOV3 = Path("/opt/ComfyUI/models/facebook/"
              "dinov3-vitl16-pretrain-lvd1689m/model.safetensors")
_WF = Path("/opt/ComfyUI/custom_nodes/ComfyUI-Trellis2/api/workflows")
# Two baked workflows: "textured" (full, ~24 min) and "mesh" (geometry only,
# much faster). Client picks via the `mode` form field; default textured.
TEMPLATES = {
    "textured": Path(os.environ.get("WORKFLOW_TEMPLATE",
                                    _WF / "pixal3d_textured.api.json")),
    "mesh": Path(os.environ.get("WORKFLOW_TEMPLATE_MESH",
                                _WF / "pixal3d_mesh.api.json")),
}
DEFAULT_MODE = "textured"
API_KEY = os.environ.get("TRELLIS_API_KEY", "")
JOB_TIMEOUT_S = int(os.environ.get("JOB_TIMEOUT_S", "2400"))  # 40 min

# Class types we patch. Input names are resolved at startup from /object_info.
CLS_IMAGE = "Trellis2LoadImageWithTransparency"
CLS_MODEL = "Trellis2LoadModel"
CLS_EXPORT = "Trellis2ExportMesh"
CLS_PREPROCESS = "Trellis2PreProcessImage"

app = FastAPI(title="Pixal3D-T API", version="1.0")
_bearer = HTTPBearer(auto_error=False)

# In-memory job store (single instance; ComfyUI serializes its own queue).
_jobs: Dict[str, Dict[str, Any]] = {}
_state: Dict[str, Any] = {}  # template + resolved input-name mapping


def _auth(cred: Optional[HTTPAuthorizationCredentials] = Depends(_bearer)):
    if not API_KEY:
        raise HTTPException(503, "TRELLIS_API_KEY not configured on the server")
    if cred is None or not secrets.compare_digest(cred.credentials, API_KEY):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid bearer token")


def _inputs(obj_info: dict, cls: str):
    spec = obj_info[cls]["input"]
    for grp in ("required", "optional"):
        for name, decl in spec.get(grp, {}).items():
            yield name, decl[0]


def _first_input_of_type(obj_info: dict, cls: str, want: str) -> str:
    """First input of `cls` whose declared type == want (e.g. 'STRING')."""
    for name, t in _inputs(obj_info, cls):
        if t == want:
            return name
    raise RuntimeError(f"{cls}: no input of type {want}")


def _sole_input_name(obj_info: dict, cls: str) -> str:
    """First (here: only) input name of `cls`, regardless of type.
    Trellis2LoadImageWithTransparency exposes a single `image` COMBO whose
    value is just the filename string."""
    for name, _t in _inputs(obj_info, cls):
        return name
    raise RuntimeError(f"{cls}: has no inputs")


async def _ensure_loaded(mode: str) -> None:
    """Lazily resolve a mode's template + ComfyUI input names, and cache it.

    Deliberately NOT a startup hook: if a template is missing the API must
    still come up (degraded) and report it via /healthz instead of
    crash-looping. Self-heals: the first call after the file appears loads it.
    """
    if mode in _state:
        return
    path = TEMPLATES[mode]
    if not path.exists():
        raise HTTPException(503,
            f"workflow template for mode '{mode}' not found at {path}")
    template = json.loads(path.read_text())
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            oi = (await c.get(f"{COMFY_URL}/object_info")).json()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"ComfyUI not reachable: {e}")

    img_in = _sole_input_name(oi, CLS_IMAGE)              # `image` COMBO
    backend_in = "backend"                                # COMBO on LoadModel
    export_name_in = _first_input_of_type(oi, CLS_EXPORT, "STRING")

    def node_id(cls: str) -> str:
        ids = [k for k, v in template.items() if v.get("class_type") == cls]
        if not ids:
            raise HTTPException(503,
                                f"'{mode}' template has no {cls} node")
        return ids[0]

    _state[mode] = dict(
        template=template,
        img_node=node_id(CLS_IMAGE), img_in=img_in,
        model_node=node_id(CLS_MODEL), backend_in=backend_in,
        export_node=node_id(CLS_EXPORT), export_name_in=export_name_in,
    )


@app.get("/healthz")
async def healthz() -> JSONResponse:
    ok = {"dinov3": DINOV3.exists(),
          "templates_present": {m: p.exists() for m, p in TEMPLATES.items()},
          "templates_loaded": sorted(_state.keys())}
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            ok["comfyui"] = (await c.get(f"{COMFY_URL}/system_stats")
                             ).status_code == 200
    except Exception:
        ok["comfyui"] = False
    if ok["comfyui"]:
        for m in TEMPLATES:        # opportunistically warm any present mode
            try:
                await _ensure_loaded(m)
            except Exception:      # noqa: BLE001
                pass
        ok["templates_loaded"] = sorted(_state.keys())
    # Ready = ComfyUI up, DinoV3 present, and the default mode is servable.
    code = 200 if (ok["comfyui"] and ok["dinov3"]
                   and ok["templates_present"].get(DEFAULT_MODE)) else 503
    return JSONResponse(ok, status_code=code)


def _build_prompt(mode: str, image_name: str, basename: str,
                  seed: Optional[int]) -> dict:
    st = _state[mode]
    g = copy.deepcopy(st["template"])
    g[st["img_node"]]["inputs"][st["img_in"]] = image_name
    # flash_attn/xformers are not installed; sdpa is the supported path.
    g[st["model_node"]]["inputs"][st["backend_in"]] = "sdpa"
    g[st["export_node"]]["inputs"][st["export_name_in"]] = basename
    # API clients send arbitrary photos (often RGB/JPEG). The preprocess node
    # otherwise assumes a pre-masked RGBA input and crashes on the missing
    # alpha channel; force rembg background removal so any image works.
    for v in g.values():
        if v.get("class_type") == CLS_PREPROCESS:
            v["inputs"]["remove_background"] = True
    if seed is not None:
        for v in g.values():
            if "seed" in v.get("inputs", {}):
                v["inputs"]["seed"] = seed
    return g


async def _run_job(job_id: str, prompt_id: str, basename: str) -> None:
    job = _jobs[job_id]
    deadline = time.time() + JOB_TIMEOUT_S
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            while time.time() < deadline:
                await asyncio.sleep(3)
                h = (await c.get(f"{COMFY_URL}/history/{prompt_id}")).json()
                if prompt_id not in h:
                    # ComfyUI only writes history once execution finishes.
                    job["status"] = "running"
                    continue
                st = h[prompt_id].get("status", {})
                if st.get("status_str") == "error":
                    job.update(status="failed",
                               error="ComfyUI execution error; see container logs")
                    return
                # Success: locate the GLB we gave a unique basename.
                matches = sorted(glob.glob(
                    str(OUTPUT_DIR / "**" / f"{basename}*.glb"),
                    recursive=True))
                job.update(status="succeeded", glb=matches[0]) if matches else \
                    job.update(status="failed",
                               error="run finished but no .glb produced")
                return
        job.update(status="failed", error="job timed out")
    except Exception as e:  # noqa: BLE001
        job.update(status="failed", error=f"{type(e).__name__}: {e}")


@app.post("/v1/generate", status_code=202, dependencies=[Depends(_auth)])
async def generate(image: UploadFile = File(...),
                   seed: Optional[int] = Form(None),
                   mode: str = Form(DEFAULT_MODE)) -> dict:
    if mode not in TEMPLATES:
        raise HTTPException(422,
            f"mode must be one of {sorted(TEMPLATES)} (got '{mode}')")
    await _ensure_loaded(mode)  # 503 with an actionable message if not ready
    data = await image.read()
    job_id = uuid.uuid4().hex
    basename = f"api_{job_id}"
    async with httpx.AsyncClient(timeout=60) as c:
        up = await c.post(f"{COMFY_URL}/upload/image", files={
            "image": (image.filename or f"{job_id}.png", data,
                      image.content_type or "image/png")},
            data={"overwrite": "true"})
        up.raise_for_status()
        uploaded = up.json()
        ref = uploaded["name"]
        if uploaded.get("subfolder"):
            ref = f"{uploaded['subfolder']}/{uploaded['name']}"
        prompt = _build_prompt(mode, ref, basename, seed)
        r = await c.post(f"{COMFY_URL}/prompt",
                         json={"prompt": prompt, "client_id": job_id})
        if r.status_code != 200:
            raise HTTPException(502, f"ComfyUI rejected prompt: {r.text}")
        prompt_id = r.json()["prompt_id"]
    _jobs[job_id] = {"status": "queued", "prompt_id": prompt_id}
    asyncio.create_task(_run_job(job_id, prompt_id, basename))
    return {"job_id": job_id, "status": "queued"}


@app.get("/v1/jobs/{job_id}", dependencies=[Depends(_auth)])
async def job_status(job_id: str) -> dict:
    j = _jobs.get(job_id)
    if not j:
        raise HTTPException(404, "unknown job")
    return {"job_id": job_id, "status": j["status"],
            "error": j.get("error")}


@app.get("/v1/jobs/{job_id}/model", dependencies=[Depends(_auth)])
async def job_model(job_id: str):
    j = _jobs.get(job_id)
    if not j:
        raise HTTPException(404, "unknown job")
    if j["status"] != "succeeded":
        raise HTTPException(409, f"job not ready (status={j['status']})")
    return FileResponse(j["glb"], media_type="model/gltf-binary",
                        filename=f"{job_id}.glb")
