"""Reflex conversion toolchain.

Compiles Whisper variants and the Laya router into `.mlpackage` bundles
targeting the Apple Neural Engine, matching the filenames `ReflexCore` looks
up (`whisper-base`, `whisper-small`, `whisper-large-v3-turbo`, `laya`).

Usage:
  python convert.py whisper --variant large-v3-turbo --quantize int8
  python convert.py laya --quantize int8

Output directory defaults to `<repo>/Models`, derived from this file's own
location so the toolchain stays self-contained after a clone (see
`reflexApp/Reflex/ReflexApp.swift` > `ReflexEnvironment.modelDirectory`).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import project_env  # noqa: F401,E402  (pins HF_HOME/REFLEX_MODELS in-project)

project_env.ensure_cache_dirs()

import torch  # noqa: E402  (must follow project_env)

WHISPER_VARIANTS = {"base": "whisper-base", "small": "whisper-small", "large-v3-turbo": "whisper-large-v3-turbo"}
# tools/ -> repo root. Never derive this from $HOME: a clone can live anywhere.
REPO_ROOT = project_env.REPO_ROOT
DEFAULT_OUTPUT = REPO_ROOT / "Models"


def log(msg: str) -> None:
    print(f"[reflex-convert] {msg}", flush=True)


def load_torch() -> None:
    global torch, np, ct
    import numpy as np
    import torch
    import coremltools as ct


def convert_whisper(variant: str, output_dir: Path, quantize: str, max_tokens: int = 128) -> Path:
    import whisper
    import whisper.model

    # Flash/SDPA attention fails to trace into CoreML and is flaky in this
    # process; the classic softmax path converts cleanly and runs on the ANE.
    whisper.model.MultiHeadAttention.use_sdpa = False

    bundle_name = WHISPER_VARIANTS[variant]
    log(f"Loading openai/whisper weights for '{variant}' (first run downloads from HuggingFace)...")
    model = whisper.load_model(variant)
    model = model.eval()

    # Encoder input: 30s mel spectrogram, `n_mels` x 3000 frames (80 for
    # base/small/large, 128 for large-v3-turbo).
    mel_shape = (1, model.dims.n_mels, 3000)
    # Decoder input: token ids with an empty KV cache (fixed-shape single pass).
    encoder = model.encoder
    decoder = model.decoder

    mel_shape = (1, model.dims.n_mels, 3000)
    mel_sample = torch.zeros(*mel_shape)
    with torch.no_grad():
        encoded = model.encoder(mel_sample)
    log(f"Encoder output shape: {tuple(encoded.shape)}")

    token_shape = (1, max_tokens)
    tokens = torch.zeros(*token_shape, dtype=torch.long)
    wrapped_decoder = _DecoderWrapper(decoder)
    with torch.no_grad():
        decoded = wrapped_decoder(tokens, encoded)
    log(f"Decoder output shape: {tuple(decoded.shape)} (max_tokens={max_tokens})")

    import coremltools as ct

    encoder_traced = torch.jit.trace(encoder, mel_sample)
    encoder_model = ct.convert(
        encoder_traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="audio_features", shape=mel_shape)],
        outputs=[ct.TensorType(name="encoded_audio")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    decoder_traced = torch.jit.trace(wrapped_decoder, (tokens, encoded))
    decoder_model = ct.convert(
        decoder_traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="tokens", shape=token_shape, dtype=np.int32),
            ct.TensorType(name="encoded_audio", shape=(1, encoded.shape[1], encoded.shape[2])),
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    encoder_path = output_dir / f"{bundle_name}.mlpackage"
    decoder_path = output_dir / f"{bundle_name}-decoder.mlpackage"
    output_dir.mkdir(parents=True, exist_ok=True)
    for stale in (encoder_path, decoder_path):
        if stale.exists():
            log(f"Removing stale {stale}")
            shutil.rmtree(stale)
    log(f"Saving encoder -> {encoder_path}")
    encoder_model.save(str(encoder_path))
    log(f"Saving decoder -> {decoder_path}")
    decoder_model.save(str(decoder_path))

    if quantize != "none":
        _quantize(encoder_model, bundle_name + "-encoder", output_dir, quantize)
        _quantize(decoder_model, bundle_name + "-decoder", output_dir, quantize)
        log(f"Applied {quantize} quantization to {bundle_name}.")

    return encoder_path.with_suffix("")


class _DecoderWrapper(torch.nn.Module):
    """Wraps whisper's TextDecoder so tracing emits only the logits tensor,
    not the KV-cache side output, which coremltools cannot represent."""

    def __init__(self, decoder):
        super().__init__()
        self.decoder = decoder

    def forward(self, tokens, encoded_audio):
        result = self.decoder(tokens, encoded_audio, kv_cache=None)
        return result[0] if isinstance(result, tuple) else result


def _patch_masking_utils() -> None:
    """Replace transformers' `and_masks`/`or_masks` helpers, which seed their
    result with `Tensor.new_ones`/`new_zeros` — ops coremltools cannot convert."""
    import transformers.masking_utils as mu

    def and_masks(*mask_functions):
        def and_mask(batch_idx, head_idx, q_idx, kv_idx):
            result = mask_functions[0](batch_idx, head_idx, q_idx, kv_idx).to(torch.bool)
            for mask in mask_functions[1:]:
                result = result & mask(batch_idx, head_idx, q_idx, kv_idx).to(result.device)
            return result

        return and_mask

    def or_masks(*mask_functions):
        def or_mask(batch_idx, head_idx, q_idx, kv_idx):
            result = mask_functions[0](batch_idx, head_idx, q_idx, kv_idx).to(torch.bool)
            for mask in mask_functions[1:]:
                result = result | mask(batch_idx, head_idx, q_idx, kv_idx).to(result.device)
            return result

        return or_mask

    mu.and_masks = and_masks
    mu.or_masks = or_masks


def _patch_decision_forward(model) -> None:
    """Swap DecisionModel.forward for a CoreML-friendly variant.

    The stock forward calls `marker_pos.clamp(min=0)`, and coremltools lowers
    integer `clamp` to a float `clip`, corrupting the gather indices. Marker
    positions are non-negative indices by construction, so the clamp is a no-op
    we can safely drop for export.
    """
    import types

    def forward(self, input_ids, attention_mask, marker_pos, marker_mask, qtype, detach_encoder=False):
        h = self.encoder(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        if detach_encoder:
            h = h.detach()
        h = h + self.type_emb(qtype)[:, None, :]
        if self.head is not None:
            pad = ~attention_mask.bool()
            for layer in self.head.layers:
                h = layer(h, src_key_padding_mask=pad)
        idx = marker_pos[:, :, None].expand(-1, -1, h.size(-1))
        m = torch.gather(h, 1, idx)
        logits = self.scorer(m).squeeze(-1).float()
        logits = logits.masked_fill(~marker_mask, -1e4)

        p = torch.softmax(logits.detach(), -1)
        k = marker_mask.sum(-1).clamp(min=2).float()
        ent = -(p * torch.log(p.clamp_min(1e-9))).sum(-1) / torch.log(k)
        top2 = p.topk(2, -1).values
        feats = torch.stack([top2[:, 0], top2[:, 0] - top2[:, 1], ent, k / 255.0], -1)
        pooled = h[:, 0].float()
        act_logits = self.act_head(torch.cat([pooled, feats], -1))
        return logits, act_logits

    model.forward = types.MethodType(forward, model)


def convert_laya(output_dir: Path, quantize: str, questions: int = 4, options: int = 16) -> Path:
    """Convert the Laya DecisionModel to CoreML.

    The model is non-autoregressive: one forward pass evaluates `questions`
    parallel questions, each with up to `options` option markers, and returns
    per-option `logits` plus an `act_logits` gate.
    """
    import laya

    hf_id = "convaiinnovations/laya"
    log(f"Loading {hf_id} via the laya SDK (ModernBERT-Large backbone + parallel heads)...")
    agent = laya.load(hf_id)
    model = agent.model.to("cpu").eval()

    # Eager attention converts cleanly; SDPA/flash does not trace into CoreML.
    model.encoder.config._attn_implementation = "eager"

    _patch_masking_utils()
    _patch_decision_forward(model)

    cfg = agent.cfg
    max_len = int(cfg.get("max_len", 512))

    import coremltools as ct

    input_ids = torch.zeros((questions, max_len), dtype=torch.long)
    attention_mask = torch.ones((questions, max_len), dtype=torch.long)
    marker_pos = torch.arange(options, dtype=torch.long).repeat(questions, 1).clamp(max=max_len - 1)
    marker_mask = torch.ones((questions, options), dtype=torch.bool)
    qtype = torch.arange(questions, dtype=torch.long) % 3

    with torch.no_grad():
        logits, act_logits = model(input_ids, attention_mask, marker_pos, marker_mask, qtype)
    log(f"Laya logits {tuple(logits.shape)}, act_logits {tuple(act_logits.shape)}")

    class _LayaExport(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, input_ids, attention_mask, marker_pos, marker_mask, qtype):
            logits, act_logits = self.m(
                input_ids, attention_mask, marker_pos, marker_mask.bool(), qtype
            )
            return logits, act_logits

    traced = torch.jit.trace(
        _LayaExport(model),
        (input_ids, attention_mask, marker_pos, marker_mask, qtype),
        check_trace=False,
    )
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids", shape=(questions, max_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(questions, max_len), dtype=np.int32),
            ct.TensorType(name="marker_pos", shape=(questions, options), dtype=np.int32),
            ct.TensorType(name="marker_mask", shape=(questions, options), dtype=np.int32),
            ct.TensorType(name="qtype", shape=(questions,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits"), ct.TensorType(name="act_logits")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    bundle_path = output_dir / "laya.mlpackage"
    if bundle_path.exists():
        log(f"Removing stale {bundle_path}")
        shutil.rmtree(bundle_path)
    log(f"Saving -> {bundle_path}")
    coreml_model.save(str(bundle_path))

    if quantize != "none":
        _quantize(coreml_model, "laya", output_dir, quantize)
        log(f"Applied {quantize} quantization to laya.")

    return bundle_path


def _quantize(model, bundle_prefix: str, output_dir: Path, mode: str) -> None:
    import coremltools as ct

    op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype=np.int8 if mode == "int8" else np.int4,
        granularity="per_channel",
    )
    config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
    q = ct.optimize.coreml.linear_quantize_weights(model, config=config)
    path = output_dir / f"{bundle_prefix}-{mode}.mlpackage"
    if path.exists():
        shutil.rmtree(path)
    log(f"Saving quantized -> {path}")
    q.save(str(path))


def write_manifest(output_dir: Path, entries: dict) -> None:
    path = output_dir / "manifest.json"
    manifest = {"models": {}}
    if path.exists():
        try:
            manifest = json.loads(path.read_text())
            manifest.setdefault("models", {})
        except json.JSONDecodeError:
            pass
    manifest["models"].update(entries)
    path.write_text(json.dumps(manifest, indent=2))
    log(f"Wrote {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    whisper_p = sub.add_parser("whisper")
    whisper_p.add_argument("--variant", choices=list(WHISPER_VARIANTS), default="large-v3-turbo")
    whisper_p.add_argument("--quantize", choices=["none", "int8", "int4"], default="int8")
    whisper_p.add_argument("--max-tokens", type=int, default=128)
    whisper_p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)

    laya_p = sub.add_parser("laya")
    laya_p.add_argument("--quantize", choices=["none", "int8", "int4"], default="int8")
    laya_p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)

    args = parser.parse_args()

    load_torch()
    output_dir = args.output.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.command == "whisper":
        path = convert_whisper(args.variant, output_dir, args.quantize, args.max_tokens)
        write_manifest(output_dir, {"whisper": str(path)})
    elif args.command == "laya":
        path = convert_laya(output_dir, args.quantize)
        write_manifest(output_dir, {"laya": str(path)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
