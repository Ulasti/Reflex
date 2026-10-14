"""Export Laya tokenizer + router schema into ReflexCore resources.

Reads the converted Laya checkpoint (already downloaded to the HuggingFace
cache by `convert.py laya`), then writes three resources the Swift runtime
loads from `Bundle.module`:

  laya-tokenizer.json   ByteLevel BPE vocab/merges + special token ids
  laya-config.json      sequence budgets + calibrated temperatures
  reflex-questions.json the Reflex routing schema, with each question's fixed
                        prefix tokens (head + options) and marker positions
                        precomputed so Swift only has to tokenize the state

Usage:
  python export_laya.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

REPO = "convaiinnovations/laya"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import project_env  # noqa: F401,E402  (pins HF_HOME/REFLEX_MODELS in-project)

project_env.ensure_cache_dirs()

DEFAULT_OUTPUT = (
    project_env.REPO_ROOT / "ReflexCore" / "Sources" / "ReflexCore" / "Resources"
)

# The canonical GPT-2 / tokenizers ByteLevel split regex. `use_regex: true` in
# the checkpoint's pre_tokenizer means this exact pattern is applied before the
# byte-level mapping, so the Swift port must reproduce it verbatim.
BYTE_LEVEL_REGEX = (
    r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"
)


def log(msg: str) -> None:
    print(f"[reflex-laya] {msg}", flush=True)


def reflex_questions() -> dict:
    """The Reflex System-1 routing schema.

    Three typed questions mirror the `ReflexDecision` primitives: a `choice`
    action target, a `score` urgency, and a `noul` locality gate.
    """
    return {
        "action": {
            "type": "choice",
            "instructions": "What action does `command` ask the assistant to perform?",
            "criteria": {
                "environment_setup": "set up a project, workspace, repo or development environment",
                "open_app": "open, focus or switch to an application or window",
                "web_search": "look something up online or search the web",
                "file_operation": "create, move, rename or delete files or folders",
                "media_control": "control music, video or playback",
                "general_query": "answer a question or chat, with no system action",
            },
        },
        "urgency": {
            "type": "score",
            "instructions": "How urgent is `command`?",
            "criteria": [
                "no time pressure",
                "should happen soon",
                "needs immediate action",
            ],
        },
        "is_local": {
            "type": "noul",
            "instructions": "Can `command` be carried out entirely on this device, without the network or external services?",
        },
    }


def load_snapshot() -> Path:
    from huggingface_hub import snapshot_download

    log(f"Resolving {REPO} from the HuggingFace cache...")
    return Path(snapshot_download(REPO))


def export_tokenizer(snapshot: Path, output: Path) -> None:
    from transformers import AutoTokenizer

    raw = json.loads((snapshot / "tokenizer" / "tokenizer.json").read_text())
    model = raw["model"]
    if model.get("type") != "BPE":
        raise SystemExit(f"expected a BPE tokenizer, found {model.get('type')!r}")

    merges = [m if isinstance(m, list) else m.split(" ") for m in model["merges"]]

    tok = AutoTokenizer.from_pretrained(str(snapshot / "tokenizer"))
    specials = {
        "unk": tok.unk_token_id,
        "cls": tok.cls_token_id,
        "sep": tok.sep_token_id,
        "pad": tok.pad_token_id,
        "mask": tok.mask_token_id,
    }
    if any(v is None for v in specials.values()):
        raise SystemExit(f"missing special token ids: {specials}")

    payload = {
        "vocab": model["vocab"],
        "merges": merges,
        "specials": specials,
        "added_tokens": [
            {
                "id": t["id"],
                "content": t["content"],
                "normalized": bool(t.get("normalized", False)),
                "special": bool(t.get("special", False)),
            }
            for t in raw.get("added_tokens", [])
        ],
        "byte_level_regex": BYTE_LEVEL_REGEX,
        "add_prefix_space": bool(raw.get("pre_tokenizer", {}).get("add_prefix_space", False)),
    }
    path = output / "laya-tokenizer.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    log(f"Wrote {path} ({path.stat().st_size / 1e6:.1f} MB, vocab={len(payload['vocab'])}, merges={len(merges)})")


def export_config(snapshot: Path, output: Path) -> None:
    cfg = json.loads((snapshot / "rl_agent_config.json").read_text())
    payload = {
        "max_len": int(cfg.get("max_len", 512)),
        "head_max_len": int(cfg.get("head_max_len", 192)),
        "questions": 4,
        "options": 16,
        "qtypes": {"choice": 0, "score": 1, "noul": 2},
        "temperature": cfg.get("temperature", [1.0, 1.0, 1.0]),
        "temperature_by_options": cfg.get("temperature_by_options", {}),
    }
    path = output / "laya-config.json"
    path.write_text(json.dumps(payload, indent=2))
    log(f"Wrote {path}")


def export_questions(snapshot: Path, output: Path) -> None:
    from laya.common import QTYPES, build_sequence
    from laya.agent import Agent
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(str(snapshot / "tokenizer"))
    cfg = json.loads((snapshot / "rl_agent_config.json").read_text())
    max_len = int(cfg.get("max_len", 512))
    head_max_len = int(cfg.get("head_max_len", 192))
    mask_tok = tok.mask_token

    exported = []
    for qid, qdef in reflex_questions().items():
        q = Agent._to_internal(qdef)
        # An empty state isolates the fixed prefix (head + options + closing
        # SEP) and the marker positions, both independent of the transcript.
        seq, markers = build_sequence(tok, "", q, max_len, head_max_len)
        prefix = seq[:-1]  # drop the trailing SEP that precedes the state slot
        exported.append(
            {
                "id": qid,
                "type": q["t"],
                "qtype": QTYPES[q["t"]],
                "instructions": q["ins"].replace(mask_tok, " "),
                "options": [o.replace(mask_tok, " ") for o in _render(q)],
                "prefix_tokens": prefix,
                "markers": markers,
            }
        )
        log(f"  {qid}: qtype={q['t']} prefix={len(prefix)} markers={markers}")

    path = output / "reflex-questions.json"
    path.write_text(json.dumps({"questions": exported}, indent=2))
    log(f"Wrote {path}")


def _render(q: dict) -> list[str]:
    from laya.common import render_options

    return render_options(q)


def main() -> int:
    output = Path(os.environ.get("REFLEX_RESOURCES", DEFAULT_OUTPUT))
    output.mkdir(parents=True, exist_ok=True)
    snapshot = load_snapshot()
    export_tokenizer(snapshot, output)
    export_config(snapshot, output)
    export_questions(snapshot, output)
    log("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
