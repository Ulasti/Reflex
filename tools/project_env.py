"""Project-root and cache-path resolution for the Reflex toolchain.

Every `tools/*.py` script imports this first so that no script ever derives a
path from `$HOME`. Reflex must survive being cloned to any directory on any
machine, so:

* `REPO_ROOT`  - the project root, resolved from this file's own location
  (`tools/` -> parent). The same value a fresh `git clone` would produce.
* `HF_HOME`    - the Hugging Face cache is pinned *inside* the project
  (`.cache/huggingface`) rather than the default `~/.cache/huggingface`. This
  relocates the download path itself, so weights are fetched into the project
  instead of being copied in afterwards.

Import this before `huggingface_hub`, `transformers`, `whisper`, or `torch`
resolve their cache locations:

    import project_env  # noqa: F401  (must precede HF/transformers imports)
"""

from __future__ import annotations

import os
from pathlib import Path

# tools/ -> project root.
REPO_ROOT = Path(__file__).resolve().parent.parent

# Canonical locations, all inside the project.
MODELS_DIR = REPO_ROOT / "Models"
RESOURCES_DIR = REPO_ROOT / "reflexApp" / "ReflexCore" / "Sources" / "ReflexCore" / "Resources"
CACHE_DIR = REPO_ROOT / ".cache"
HF_CACHE_DIR = CACHE_DIR / "huggingface"

# Pin the Hugging Face cache in-project. `setdefault` so an explicit
# `HF_HOME=/somewhere` from the environment still wins.
os.environ.setdefault("HF_HOME", str(HF_CACHE_DIR))
# Keep Xet/HF scratch traffic next to the cache instead of the OS temp dir.
os.environ.setdefault("HF_XET_CACHE", str(HF_CACHE_DIR / "xet"))

# The Swift app and the toolchain must agree on the models directory.
os.environ.setdefault("REFLEX_MODELS", str(MODELS_DIR))


def ensure_cache_dirs() -> None:
    """Create the in-project cache directories. Safe to call repeatedly."""
    for directory in (CACHE_DIR, HF_CACHE_DIR):
        directory.mkdir(parents=True, exist_ok=True)


def relative_to_repo(path: Path | str) -> str:
    """Render `path` repo-relative when possible, else absolute.

    Used by anything that writes a path into a committed file (e.g.
    `Models/manifest.json`) so no absolute host path is ever recorded.
    """
    candidate = Path(path)
    try:
        return candidate.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return candidate.as_posix()
