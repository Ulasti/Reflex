"""Export Whisper's multilingual tokenizer into a compact binary resource.

Produces, into ReflexCore/Sources/ReflexCore/Resources/:
  - whisper-tokens.bin : for each token id, uint32 little-endian length + raw bytes
  - whisper-tokenizer.json : metadata (vocab size, special ids, language tokens)
  - whisper-mel-80.bin / whisper-mel-128.bin : raw float32 mel filterbanks
    (shape n_mels x 201, row-major), copied verbatim from whisper's assets
    so Swift needs no librosa-style filterbank math.

Run: python export_tokenizer.py
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np
import whisper

RESOURCES = Path(__file__).resolve().parents[1] / "reflexApp" / "ReflexCore" / "Sources" / "ReflexCore" / "Resources"


def main() -> None:
    tok = whisper.tokenizer.get_tokenizer(True)
    enc = tok.encoding
    n_vocab = enc.n_vocab

    RESOURCES.mkdir(parents=True, exist_ok=True)

    blob = bytearray()
    for i in range(n_vocab):
        raw = enc.decode_single_token_bytes(i)
        blob += struct.pack("<I", len(raw))
        blob += raw
    (RESOURCES / "whisper-tokens.bin").write_bytes(bytes(blob))

    meta = {
        "n_vocab": n_vocab,
        "sot": tok.sot,
        "eot": tok.eot,
        "transcribe": tok.transcribe,
        "translate": tok.translate,
        "no_timestamps": tok.no_timestamps,
        "language_token_en": tok.to_language_token("en"),
        "special_ids": sorted(
            enc.encode_single_token(text)
            for text in tok.special_tokens
            if text in enc._special_tokens
        ),
    }
    (RESOURCES / "whisper-tokenizer.json").write_text(json.dumps(meta, indent=2))

    for n_mels in (80, 128):
        filters = whisper.audio.mel_filters(None, n_mels).numpy().astype(np.float32)
        (RESOURCES / f"whisper-mel-{n_mels}.bin").write_bytes(filters.tobytes())

    print(f"wrote {n_vocab} tokens ({len(blob)/1024/1024:.1f} MB) + mel filters -> {RESOURCES}")


if __name__ == "__main__":
    main()
