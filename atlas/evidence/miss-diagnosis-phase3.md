# Miss diagnosis — where v1 accuracy actually goes (plan steps 1–3, 5)

Measured on the M3 Max with the corpus replay harness and a new ground-truth
oracle. Numbers come from the CSV files in this directory; commands are at the
bottom. Nothing here is estimated.

## Summary

- With **perfect ASR the rules lane decides 131/132 phrasings (99.2%)**. The
  router is no longer the bottleneck; ASR is.
- Rules+arbiter accuracy on the corpus went **45.1% → 77.3%** in this round
  (train 47.8% → 75.3%, heldout 39.0% → 81.7%).
- Route stage (last word → routed action) **p50 594 → 365 ms**, **p95 789 →
  765 ms**. The short-circuit removed the Laya forward pass from decisive rules.
- Laya rescued **0 of 145** baseline misses and is in none of the shipped paths.

## Oracle: the router's ceiling with perfect ASR

`reflex-cli --oracle [PHRASES.md]` feeds each **intended phrasing text** straight
into `resolveCompoundTranscript`, skipping audio and Whisper. A phrase that fails
there is a router failure no ASR improvement can fix.

| build | oracle accuracy | remaining gaps |
|---|---|---|
| Phase 3 as first written | 120/132 (90.9%) | 12 |
| after the router fixes below | **131/132 (99.2%)** | 1 (`go back`) |

`go back` is the documented ambiguity: routed to `browser_command`, accepted as a
miss for `prev_track` (plan decision, kept).

## Baseline 145 misses, tagged (provisional)

Tagging the 145 misses in `replay-baseline-v1.csv` against the oracle:

| cause | clips |
|---|---|
| (a) ASR error — ground-truth text routes fine | 123 |
| (b) phrasing absent from the rule table | 10 |
| (c) rule fires, payload/target wrong | 12 |

Caveat: the oracle used here is the **Phase 3** rules, so (a) is an upper bound —
phrasings the baseline router could not route but Phase 3 can are counted as (a).
The direction is not in doubt: the current build's 42/182 train clips whose
transcript differs from the intended phrase are pure ASR, and the router now has
~1% residual error. Whisper is the lever.

## The 12 router gaps, and the fix for each

| phrase | was | now |
|---|---|---|
| `github dot com`, `youtube dot com`, `wikipedia dot com` | `general_query` (space in "dot com" defeated the bare-entity rule) | `open_app` — `normalizeSpokenDomain` before the bare-entity test |
| `google dot com` | `web_search` site `.com` | `open_app` — same fix, bare entity now fires before the web rule |
| `go to google`, `open google`, `visit google` | scored as Chrome | harness now scores what the dispatcher does (`looksLikeURL` before `AppResolver` → google.com) |
| `desktop, please` | `system.none` — the router normalized, the dispatcher's parse did not | `system.showDesktop` — `systemOperation` normalizes with `normalizeIntent` |
| `silence it` | `silenceDetected` error — the text *contained* "silence" | `volume.mute` — a marker must be the whole utterance |
| `stop for a second` | `general_query` | `media_control` |
| `back to the previous one` | `general_query` | `media_control` |

## Latency: the prompt experiment is a measured regression

Phase 3.2 biased Whisper with a command-vocabulary prompt. WhisperKit re-prefills
the prompt on every sampled token, so cost scales with prompt length:

| prompt | decode per pass (6 clips) | route p50 |
|---|---|---|
| none | 149–174 ms | 588 ms |
| 6 tokens | 291–1121 ms | ~760 ms |
| ~60 tokens (as written) | **14–37 s** | 14–37 s |

Removed entirely; mishearings go through the alias table instead, which costs no
decode time. A full 264-clip run with the long prompt was abandoned mid-run
(22–41 s per clip).

## Trailing silence: replay understates live latency

261 of 264 clips end within **300 ms of the last voiced frame** (p50 = 0 ms), so
the segmenter flushes at end of stream and the 7 × 100 ms gate never elapses.
Consequences:

- replay p50 understates the live p50 by up to the gate time;
- the Phase 2 gate sweep cannot be measured on the raw corpus at all.

An 800 ms-padded copy of the corpus is used for latency work
(`replay-phase3b-padded.csv`).

## Media guardrail (plan step 6, found early)

`suppressWhileMediaPlaying` defaults to **ON** and dropped *every* segment while
media played, including "volume up" and the chain's "open Safari". It now
suppresses only speech that is not a decisive rule (≥ 0.9): music never
classifies that high.

## Commands

```
reflex-cli --oracle corpus/PHRASES.md [--csv out.csv]
reflex-cli --replay <corpus-dir> [--variant base|small|large-v3-turbo] [--csv out.csv]
REFLEX_FORCE_LAYA=1 reflex-cli --replay ...   # ablation: keep the Laya lane
```
