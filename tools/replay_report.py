#!/usr/bin/env python3
"""Summarise one or more reflex-cli --replay CSVs.

Reads the corpus phrasing list (PHRASES.md) to count residual mis-transcriptions
(clips whose ASR text is not the phrasing that was read) and reports accuracy,
the decisive/non-decisive split, latency percentiles and false splits.

usage: python3 tools/replay_report.py <csv> [<csv> ...]
"""

import csv
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_phrases(path=ROOT / "corpus" / "PHRASES.md"):
    """{(command, id): phrase text} plus the split each id belongs to."""
    phrases, split = {}, {}
    part = "train"
    for line in path.read_text().splitlines():
        if line.startswith("## Part 2"):
            part = "heldout"
        match = re.match(r'- \[ \] "(.+?)" — (\w+)__(\d+)', line)
        if match:
            text, command, phrase_id = match.groups()
            phrases[(command, phrase_id)] = text
            split[(command, phrase_id)] = part
    return phrases, split


def normalise(text):
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def summarise(csv_path, phrases):
    rows = list(csv.DictReader(open(csv_path)))
    out = [f"== {Path(csv_path).name} — {len(rows)} clips =="]
    for split in ("train", "heldout", "all"):
        subset = [r for r in rows if split == "all" or r["split"] == split]
        if not subset:
            continue
        # accuracy is scored by the harness itself (signature equality)
        rules = sum(int(r["correct_rules"]) for r in subset)
        hybrid = sum(int(r["correct_hybrid"]) for r in subset)
        decisive = [r for r in subset if r["rule_sig"] != "none" and float(r["rule_conf"]) >= 0.9]
        nondecisive = [r for r in subset if r["rule_sig"] != "none" and float(r["rule_conf"]) < 0.9]
        scored_laya = [r for r in subset if r["laya_sig"] != "skipped"]
        laya_correct = sum(int(r["correct_laya"]) for r in scored_laya)
        latency = [float(r["last_word_to_route_ms"]) for r in subset]
        false_splits = sum(1 for r in subset if int(r["segments"]) > 1)
        # residual ASR: the transcript is not the line that was read out
        residual = 0
        for row in subset:
            phrase = phrases.get((row["command_id"], row["phrase_id"]))
            if phrase and normalise(row["transcript"]) != normalise(phrase):
                residual += 1
        out.append(
            f"  {split:8s} n={len(subset):3d}  rules {rules/len(subset):5.1%}"
            f"  hybrid {hybrid/len(subset):5.1%}"
            f"  decisive {len(decisive):3d}  non-decisive {len(nondecisive):3d}"
            f"  route p50 {percentile(latency,0.5):4.0f} p95 {percentile(latency,0.95):4.0f} ms"
            f"  ASR-diff {residual:3d}  false-splits {false_splits}"
        )
        if scored_laya:
            out.append(
                f"           laya ran on {len(scored_laya):3d} clips"
                f" ({laya_correct/len(scored_laya):5.1%} correct),"
                f" skipped on {len(subset)-len(scored_laya)} decisive ones"
            )
    return "\n".join(out)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    phrases, _ = load_phrases()
    for path in argv[1:]:
        print(summarise(path, phrases))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
