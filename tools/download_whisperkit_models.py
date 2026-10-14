#!/usr/bin/env python3
"""Fetch a WhisperKit CoreML model variant for Reflex's live transcription.

WhisperKit keeps ready-to-load CoreML packs on Hugging Face at
`argmaxinc/whisperkit-coreml`. Reflex downloads a single variant into
`<models>/whisperkit/<variant>` so `LiveTranscriber` can load it offline
(`download: false`). Uses the huggingface_hub client, which handles the
repo's xet-bridged blob storage (plain git sparse clones fail on xet repos).

Usage:
  download_whisperkit_models.py [variant] [models-dir]
  download_whisperkit_models.py --list
"""

import argparse
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import project_env  # noqa: F401,E402  (pins HF_HOME/REFLEX_MODELS in-project)

project_env.ensure_cache_dirs()

import huggingface_hub  # noqa: E402  (must follow project_env)

REPO_ID = "argmaxinc/whisperkit-coreml"

# Short aliases -> canonical Hugging Face folder names. The folder name is what
# ends up under <models>/whisperkit/, so `LiveTranscriber` finds the pack.
ALIASES = {
    "t": "openai_whisper-tiny",
    "tiny": "openai_whisper-tiny",
    "tiny.en": "openai_whisper-tiny.en",
    "b": "openai_whisper-base",
    "base": "openai_whisper-base",
    "base.en": "openai_whisper-base.en",
    "s": "openai_whisper-small",
    "small": "openai_whisper-small",
    "small.en": "openai_whisper-small.en",
    "small.compressed": "openai_whisper-small_216MB",
    "small.en.compressed": "openai_whisper-small.en_217MB",
    "m": "openai_whisper-medium",
    "medium": "openai_whisper-medium",
    "medium.en": "openai_whisper-medium.en",
    "medium.compressed": "openai_whisper-medium_769MB",
    "turbo": "openai_whisper-large-v3-v20240930_turbo",
    "turbo.compressed": "openai_whisper-large-v3-v20240930_turbo_632MB",
}

DEFAULT_VARIANT = "small"


def default_models_dir():
    override = os.environ.get("REFLEX_MODELS")
    if override:
        return Path(override)
    # tools/ -> repo root. Never derive this from $HOME: a clone can live anywhere.
    return project_env.REPO_ROOT / "Models"


def canonical(variant: str) -> str:
    if variant in ALIASES:
        return ALIASES[variant]
    lowered = variant.lower()
    if lowered in ALIASES:
        return ALIASES[lowered]
    return variant


def list_variants():
    try:
        info = huggingface_hub.list_repo_tree(repo_id=REPO_ID, repo_type="model")
        folders = sorted(
            p.path for p in info if p.type == "folder" and not p.path.startswith(".")
        )
    except Exception:
        folders = sorted(ALIASES.values())
    aliases = {}
    for short, full in ALIASES.items():
        aliases.setdefault(full, []).append(short)
    lines = []
    for folder in folders:
        aliased = ",".join(aliases.get(folder, []))
        lines.append(f"{folder}{('  (' + aliased + ')') if aliased else ''}")
    print("\n".join(lines))


def tokenizer_repo_for_variant(variant: str) -> str:
    """WhisperKit pulls the tokenizer from the standard openai/whisper-* repo,
    so we bundle just `tokenizer.json` beside the weights. Strip the WhisperKit
    folder suffix (`_216MB`) and `openai_whisper-` prefix to recover it."""
    base = variant
    for suffix in ("_216MB", "_217MB", "_594MB", "_600MB", "_632MB", "_769MB", "_947MB", "_955MB"):
        base = base.removesuffix(suffix)
    if not base.startswith("openai_whisper-"):
        return None
    return base.replace("openai_whisper-", "openai/whisper-", 1)


def fetch(variant: str, models_dir: Path):
    dest = models_dir / "whisperkit" / variant
    markers = [
        dest / "MelSpectrogram.mlmodelc",
        dest / "AudioEncoder.mlmodelc",
        dest / "TextDecoder.mlmodelc",
        dest / "config.json",
        dest / "tokenizer.json",
    ]
    if all(m.exists() for m in markers):
        print(f"{variant} already installed at {dest}")
        return

    print(f"downloading {REPO_ID}/{variant} -> {dest} ...")
    huggingface_hub.snapshot_download(
        repo_id=REPO_ID,
        repo_type="model",
        allow_patterns=[f"{variant}/**", f"{variant}/*"],
        local_dir=str(dest),
    )

    # snapshot_download may nest files under local_dir/<variant>; flatten so the
    # pack lives directly at dest (WhisperKit searches dest for the models).
    nested = dest / variant
    if nested.exists():
        for item in sorted(nested.iterdir()):
            target = dest / item.name
            if target.exists():
                shutil.rmtree(target, ignore_errors=True)
            shutil.move(str(item), str(target))
        shutil.rmtree(nested, ignore_errors=True)

    tokenizer_repo = tokenizer_repo_for_variant(variant)
    if tokenizer_repo:
        try:
            print(f"bundling tokenizer from {tokenizer_repo} ...")
            huggingface_hub.hf_hub_download(
                repo_id=tokenizer_repo,
                filename="tokenizer.json",
                local_dir=str(dest),
            )
        except Exception as e:
            print(f"warning: could not bundle tokenizer.json ({e}); WhisperKit will fetch it itself")

    probes = [
        dest / "MelSpectrogram.mlmodelc",
        dest / "AudioEncoder.mlmodelc",
        dest / "TextDecoder.mlmodelc",
        dest / "config.json",
        dest / "tokenizer.json",
    ]
    present = [p for p in probes if p.exists()]
    missing = [p.name for p in probes if not p.exists()]
    print(f"installed {variant} with {len(present)}/{len(probes)} expected files")
    if missing:
        print(f"missing: {', '.join(missing)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", nargs="?", default=DEFAULT_VARIANT)
    parser.add_argument("models_dir", nargs="?", default=None)
    parser.add_argument("--list", action="store_true", help="list available variants")
    args = parser.parse_args()

    if args.list:
        list_variants()
        return

    variant = canonical(args.variant)
    models_dir = Path(args.models_dir) if args.models_dir else default_models_dir()
    try:
        fetch(variant, models_dir)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
