# Apply Blackwell (sm_120) compatibility patches BEFORE importing nodes (which
# imports trellis2 / o_voxel). patch_all() self-detects the GPU: on
# non-Blackwell (e.g. sm_86) it is a no-op, so this is safe on every arch.
from . import blackwell_fix
blackwell_fix.patch_all()

from .nodes import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]