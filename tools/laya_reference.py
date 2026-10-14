"""Generate ground-truth Laya reference data for the Swift port.

Builds the exact CoreML input tensors for a set of transcripts, then runs the
original PyTorch `DecisionModel` (fp32) to produce the authoritative
probabilities / decisions. The CoreML export is only as accurate as the compute
unit it runs on, so the checkpoint — not CoreML — is the source of truth.
Writes `tools/laya_reference.json` so `reflex-cli --laya-ref` can diff Swift
against it.

Usage:
  python laya_reference.py
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import project_env  # noqa: F401,E402  (pins HF_HOME/REFLEX_MODELS in-project)

project_env.ensure_cache_dirs()

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
RESOURCES = REPO / "ReflexCore" / "Sources" / "ReflexCore" / "Resources"
MODELS = Path(os.environ.get("REFLEX_MODELS", TOOLS.parent / "Models"))
REFERENCE = TOOLS / "laya_reference.json"

TRANSCRIPTS = [
    "create the back end project and open my coding split",
    "open safari",
    "remind me to call mom tomorrow",
    "play some jazz",
    "what is the capital of france",
    "make a folder called invoices and move the pdfs into it",
    "URGENT: delete the staging database right now",
]


def log(msg: str) -> None:
    print(f"[reflex-laya-ref] {msg}", flush=True)


def load_inputs():
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer

    snapshot = Path(snapshot_download("convaiinnovations/laya"))
    tok = AutoTokenizer.from_pretrained(str(snapshot / "tokenizer"))
    config = json.loads((RESOURCES / "laya-config.json").read_text())
    schema = json.loads((RESOURCES / "reflex-questions.json").read_text())["questions"]
    return tok, config, schema


def build_tensors(tok, config, schema, transcript):
    max_len = config["max_len"]
    n_q = config["questions"]
    n_opt = config["options"]
    pad_id = json.loads((RESOURCES / "laya-tokenizer.json").read_text())["specials"]["pad"]
    sep_id = json.loads((RESOURCES / "laya-tokenizer.json").read_text())["specials"]["sep"]
    mask_tok = tok.mask_token

    state_ids = tok(transcript.replace(mask_tok, " "), add_special_tokens=False)["input_ids"]

    input_ids = np.full((n_q, max_len), pad_id, dtype=np.int32)
    attention = np.zeros((n_q, max_len), dtype=np.int32)
    marker_pos = np.zeros((n_q, n_opt), dtype=np.int32)
    marker_mask = np.zeros((n_q, n_opt), dtype=np.int32)
    qtype = np.zeros((n_q,), dtype=np.int32)

    seqs = []
    for i, q in enumerate(schema):
        seq = (q["prefix_tokens"] + state_ids + [sep_id])[:max_len]
        seqs.append(seq)
        input_ids[i, : len(seq)] = seq
        attention[i, : len(seq)] = 1
        k = len(q["markers"])
        marker_pos[i, :k] = q["markers"][:k]
        marker_mask[i, :k] = 1
        qtype[i] = q["qtype"]

    return {
        "input_ids": input_ids,
        "attention_mask": attention,
        "marker_pos": marker_pos,
        "marker_mask": marker_mask,
        "qtype": qtype,
    }, seqs, state_ids


def load_torch_model():
    import torch
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file

    snapshot = Path(snapshot_download("convaiinnovations/laya"))
    sys.path.insert(0, str(snapshot))
    from rl_common import build_model

    cfg = json.loads((snapshot / "rl_agent_config.json").read_text())
    model = build_model(cfg, encoder_dir=str(snapshot / "encoder"))
    model.load_state_dict(load_file(snapshot / "model.safetensors"))
    model.eval()
    return model


def run_model(model, tensors):
    import torch

    with torch.no_grad():
        logits, act = model(
            torch.tensor(tensors["input_ids"]),
            torch.tensor(tensors["attention_mask"]),
            torch.tensor(tensors["marker_pos"], dtype=torch.int64),
            torch.tensor(tensors["marker_mask"]).bool(),
            torch.tensor(tensors["qtype"]),
        )
    return logits.numpy(), act.numpy()


def decide(config, schema, logits, act):
    temps = config["temperature"]
    by_opts = config["temperature_by_options"]
    results = []
    for i, q in enumerate(schema):
        k = len(q["markers"])
        qt = q["qtype"]
        size = "2" if k <= 2 else "3-5" if k <= 5 else "6-10" if k <= 10 else "11+"
        bucket = f"{q['type']}:{size}"
        t = float(by_opts.get(bucket, temps[qt]))
        z = np.asarray(logits[i, :k], dtype=np.float64) / max(1e-3, t)
        p = np.exp(z - z.max())
        p = p / p.sum()
        a = np.asarray(act[i, :2], dtype=np.float64)
        a = np.exp(a - a.max())
        act_prob = float((a / a.sum())[0])
        ent = -(p * np.log(np.clip(p, 1e-12, 1.0))).sum()
        conf = float(np.clip(1.0 - ent / np.log(k), 0.0, 1.0)) if k >= 2 else 1.0
        if q["type"] == "choice":
            value = q["options"][int(p.argmax())].split(":")[0].strip()
        elif q["type"] == "score":
            value = float((np.arange(k) * p).sum())
        else:
            value = float(p[1])
        results.append(
            {
                "id": q["id"],
                "type": q["type"],
                "temperature": t,
                "probabilities": [round(float(v), 6) for v in p],
                "confidence": round(conf, 6),
                "value": value,
                "act_probability": round(act_prob, 6),
            }
        )
    return results


def finite(value):
    """Replace NaN/Inf (e.g. the all-masked padding question's act logits) with
    None so the JSON stays standards-compliant and Swift's decoder accepts it."""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, list):
        return [finite(v) for v in value]
    if isinstance(value, dict):
        return {k: finite(v) for k, v in value.items()}
    return value


def main() -> int:
    tok, config, schema = load_inputs()
    log(f"{len(schema)} questions, max_len={config['max_len']}")
    model = load_torch_model()

    cases = []
    for transcript in TRANSCRIPTS:
        tensors, seqs, state_ids = build_tensors(tok, config, schema, transcript)
        logits, act = run_model(model, tensors)
        decision = decide(config, schema, logits, act)
        cases.append(
            {
                "transcript": transcript,
                "state_ids": state_ids,
                "sequences": seqs,
                "input_ids": tensors["input_ids"].tolist(),
                "attention_mask": tensors["attention_mask"].tolist(),
                "marker_pos": tensors["marker_pos"].tolist(),
                "marker_mask": tensors["marker_mask"].tolist(),
                "qtype": tensors["qtype"].tolist(),
                "logits": np.asarray(logits).tolist(),
                "act_logits": np.asarray(act).tolist(),
                "decision": decision,
            }
        )
        log(f"  {transcript!r} -> {[ (d['id'], d['value']) for d in decision ]}")

    REFERENCE.write_text(json.dumps(finite({"cases": cases}), indent=2))
    log(f"Wrote {REFERENCE} ({REFERENCE.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
