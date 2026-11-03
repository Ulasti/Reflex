# Models Manifest

The contents of `Models/` are **gitignored and intentionally not committed**.
They total roughly **1.7 GB** of CoreML weights (tiny/base/small/medium `.en`
Whisper + Laya + WhisperKit small), far past any sane repository limit.

This file is the committed placeholder. A fresh `git clone` gives you the
source code and this manifest, and the re-acquire commands below rebuild the
models in place. Nothing here is load-bearing at runtime unless the models are
present — the app degrades to a clear error instead (see
`ReflexCore/Sources/ReflexCore/SystemDiagnostics.swift`).

Reflex supports **English only** at this time. Only the `.en` Whisper variants
(tiny → medium) are used; multilingual and large-v3-turbo bundles are not
supported and have been removed from the manifest and from disk.

## Re-acquiring

### Whisper `.mlpackage` bundles

```bash
cd <repo>/tools
python3.10 -m venv .venv && .venv/bin/pip install -r requirements.txt
./.venv/bin/python convert.py whisper --variant tiny   --quantize none
./.venv/bin/python convert.py whisper --variant base   --quantize none
./.venv/bin/python convert.py whisper --variant small  --quantize none
./.venv/bin/python convert.py whisper --variant medium --quantize none
```

Output path defaults to `<repo>/Models` and is derived from the script's own
location, so no argument is needed. Weights are fetched from
`openai/whisper` on Hugging Face into the in-project cache at
`<repo>/.cache/huggingface` (see `tools/project_env.py`).

### Laya router `.mlpackage`

```bash
./.venv/bin/python convert.py laya --quantize none
```

Source checkpoint: `convaiinnovations/laya`.

### WhisperKit offline pack (`Models/whisperkit/`)

```bash
./.venv/bin/python download_whisperkit_models.py small
```

Downloads from HF repo `argmaxinc/whisperkit-coreml`, folder
`openai_whisper-small`, into `Models/whisperkit/`. `LiveTranscriber` loads it
with `download: false` so transcription works offline. English only.

## Inventory

Sizes are on-disk bytes.

| Asset | Size | Origin |
|---|---|---|
| `Models/whisper-tiny.en.mlpackage` | 39.3 MB | encoder bundle |
| `Models/whisper-tiny.en-decoder.mlpackage` | 56 MB | decoder half |
| `Models/whisper-base.en.mlpackage` | 39.3 MB | encoder bundle |
| `Models/whisper-base.en-decoder.mlpackage` | 99 MB | decoder half |
| `Models/whisper-small.en.mlpackage` | 168.3 MB | encoder bundle (segmented path) |
| `Models/whisper-small.en-decoder.mlpackage` | 293 MB | decoder half (segmented path) |
| `Models/whisper-medium.en.mlpackage` | 1.5 GB (approx) | encoder bundle |
| `Models/whisper-medium.en-decoder.mlpackage` | 871 MB | decoder half |
| `Models/laya.mlpackage` | 808.5 MB | `convaiinnovations/laya` via `convert.py laya` |
| `Models/whisperkit/` | 469.0 MB | HF `argmaxinc/whisperkit-coreml` folder `openai_whisper-small` (live path) |
| **Total** | ~3.0 GB | |

## Verifying

```bash
cd <repo>/Models
for d in whisper-*.en.mlpackage laya.mlpackage whisperkit; do
  h=$(find "$d" -type f -exec shasum -a 256 {} + \
      | sed "s|$d/||" | LC_ALL=C sort \
      | shasum -a 256 | cut -d' ' -f1)
  echo "$d $h"
done
```

## Why gitignored

| Asset | Reason |
|---|---|
| `Models/*.mlpackage` | Generated build output, not source. |
| `Models/whisperkit/` | Third-party download, not source. |
| `tools/.venv/` | Regenerable from `tools/requirements.txt`. |

Every one of these was reported to the user rather than silently excluded.
Committing them would add ~3 GB to the repository; Atlas convention is
local-first for anything over ~50 MB, with this manifest as the committed
placeholder.
