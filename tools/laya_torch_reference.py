"""Ground-truth Laya logits from the original PyTorch checkpoint.

Loads `convaiinnovations/laya` (DecisionModel) in fp32, runs the exact same
input tensors the CoreML export consumes, and prints per-question logits +
temperature-scaled decisions. Used to decide which CoreML compute unit is
numerically faithful.

Usage:
  python laya_torch_reference.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import torch

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import project_env  # noqa: E402,F401  (pins HF_HOME/REFLEX_MODELS in-project)

project_env.ensure_cache_dirs()

from laya_reference import build_tensors, load_inputs, decide, log  # noqa: E402


def main() -> int:
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file

    snapshot = Path(snapshot_download("convaiinnovations/laya"))
    sys.path.insert(0, str(snapshot))
    from rl_common import build_model  # noqa: E402

    tok, config, schema = load_inputs()
    cfg = json.loads((snapshot / "rl_agent_config.json").read_text())

    model = build_model(cfg, encoder_dir=str(snapshot / "encoder"))
    model.load_state_dict(load_file(snapshot / "model.safetensors"))
    model.eval()

    with torch.no_grad():
        for transcript in TRANSCRIPTS:
            tensors, _, _ = build_tensors(tok, config, schema, transcript)
            logits, act = model(
                torch.tensor(tensors["input_ids"]),
                torch.tensor(tensors["attention_mask"]),
                torch.tensor(tensors["marker_pos"], dtype=torch.int64),
                torch.tensor(tensors["marker_mask"]).bool(),
                torch.tensor(tensors["qtype"]),
            )
            decision = decide(config, schema, logits.numpy(), act.numpy())
            log(f"{transcript!r}")
            for row in decision:
                log(f"    {row['id']:8s} p={[round(v, 4) for v in row['probabilities']]}  "
                    f"conf={row['confidence']:.3f}  value={row['value']}")
    return 0


TRANSCRIPTS = [
    "create the back end project and open my coding split",
    "open safari",
    "remind me to call mom tomorrow",
    "play some jazz",
    "what is the capital of france",
    "make a folder called invoices and move the pdfs into it",
    "URGENT: delete the staging database right now",
]

if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    raise SystemExit(main())
