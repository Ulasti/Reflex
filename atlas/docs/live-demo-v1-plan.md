# Plan: Live Demo v1 — Fast, Accurate, On-Device Voice Control (Whisper + Laya)

> Provenance: accepted verbatim from the user on 2026-10-19 as the driver for
> `atlas/live-demo-v1`. Line references in this document were written against an
> earlier tree — `LiveTranscriber` throttle guard is now line 196 and the
> `handleSegment` cooldown/drop is now `AppModel.swift:359-364`. Update refs
> when each phase touches them. Companion: `live-demo-corpus-v0.md` (Phase 0
> draft, awaiting freeze).

## Goal

A live demo of on-device, private voice control that is fast and reliable on a small, fixed command set. The app is not a general assistant: if a command is outside the set, it does nothing. The project's core is **Whisper + Laya**, with a rules layer in front for speed and precision.

**v1 targets (measured on the recorded corpus, not by feel):**

| Metric | Target |
|---|---|
| Latency, last voiced frame to dispatch complete | p50 ≤ 500 ms, p95 ≤ 700 ms |
| Command accuracy | ≥ 90% of corpus command attempts execute the correct action |
| False triggers | Near zero in the ambient scenario (see Phase 5) |
| Status light | Every row of the light table behaves correctly (see Phase 6) |

**Starting point (latency report): about 1.1-1.6 s from last word to action.**

| Stage | Cost today |
|---|---|
| VAD endpoint gate: `StreamSegmenter(maxSilenceWindows: 7)` at 100 ms/window | 700 ms of silence before a segment emits |
| Partial-decode throttle: `LiveTranscriber.swift:195` uses `floor(timeIntervalSinceReferenceDate)` against `partialInterval = 0.35` | Partials decode about 1/s, not every 0.35 s |
| Final decode of the segment | ~50-150 ms |
| Router: rules at ≥ 0.9 / Laya | < 1 ms / ~10-40 ms (confirm device, see Phase 4) |
| Dispatch (AppleScript / AX / media key) | 10-80 ms |
| Dead air between segments: `rearmWindows: 4` | 400 ms after every segment |

Other known problems: short gaps between spoken commands (about 0.2 s) are shorter than the 0.7 s gate, so "volume up / resume media / open app" merges into one segment and all actions fire together at the end. `handleSegment` also drops any segment that arrives while processing or within the 1.0 s `feedbackCooldown` (`AppModel.swift:331-338`). The stable partial prefix is computed by local-agreement but thrown away instead of being used for routing.

**Why 500-700 ms is realistic:** with the silence gate at about 300-400 ms and the dead air fixed, the path is roughly gate 300-400 + final decode 50-150 + rule match < 1 + dispatch 10-80, which is about 400-630 ms. Routing on the stable prefix is how the simplest commands get under 500 ms, but it is a stretch goal for v1. The theoretical floor is about 200 ms (audio buffering, one ANE pass, dispatch), and a realistic best case with stabilization is about 300-450 ms.

**Reference point:** Jev Voice (cloud) measures about 850-1,200 ms end to end on a Mac mini M4: 550 ms silence gate, 80-130 ms Whisper, 170-420 ms cloud call, 50-100 ms execute. Yours runs fully local with no API key.

---

## Architecture: three lanes

1. **Rules lane (fast path).** Exact and near-exact matches against the phrasing list fire immediately in under 1 ms.
2. **Laya lane.** Anything the rules miss goes to Laya, which picks one command from the closed set (kept to about 20 options or fewer) or abstains. It fires only above a confidence threshold fitted on the corpus. Below it, nothing happens and the light returns to Armed.
3. **Ambient guard.** A Laya-lane command must also pass the command-shape check and Laya's yes/no question "is this utterance a command directed at the computer?" Rules-lane matches need only the whole segment to be the command.

Why both lanes: rules are the most precise option on phrasings they cover and cost almost nothing, but they miss wordings that were not listed. Laya generalizes across paraphrases and tolerates a mis-heard word, but it can be wrong with confidence (the shipped checkpoints are over-confident and weak zero-shot), so it needs a threshold fitted on your own data.

---

## Phase 0: Freeze scope and build the test corpus

1. **Freeze the v1 command set** (about 20-30 commands; fewer is fine).
   - **Tier A, no parameters, reversible:** volume up/down/mute, play/pause, next/previous track, scroll up/down, screenshot, dark mode toggle, copy/paste/undo, show desktop, brightness up/down.
   - **Tier B, closed parameters:** "open <app>" (a short fixed list of demo apps), "go to <site>" (a short fixed list).
   - **No risky tier in the demo:** nothing that sends, deletes, quits, or locks.
2. For each command, write 5-10 natural phrasings (e.g. "volume up", "turn it up", "louder"). Hold some phrasings back as an unseen test set for Laya.
3. **Record the corpus:** every phrasing, several times each, at normal speed, a bit fast, and with background noise. Then record 30-60 minutes of normal conversation with no commands, including the commands' words used in ordinary sentences ("I need to open the window", "turn the volume up on the TV").
4. **Build the replay harness:** feed recordings through the real pipeline and log stage timestamps (last voiced frame, partial, route, dispatch complete) and the action taken. Also log time from first voiced chunk to the Hearing light.
5. **Run an ablation every time** and report all three configurations:

| Configuration | Command accuracy | False triggers/hr | p50 / p95 latency |
|---|---|---|---|
| Rules only | | | |
| Laya only | | | |
| Rules + Laya (v1 design) | | | |

6. Also report time-to-Hearing. Save the baseline before changing anything. No later phase is "done" without a before/after on these numbers.

## Phase 1: Free wins

1. Fix the `floor()` partial throttle at `LiveTranscriber.swift:195` so partials run at the intended cadence.
2. Replace the drop in `handleSegment` (`AppModel.swift:331-338`) with a FIFO queue. Dedupe on (command, token offset).
3. Remove or shrink `rearmWindows` (400 ms) and the 1.0 s `feedbackCooldown`.
4. Confirm the Executed flash retriggers once per queued action.
5. Re-run the harness and record the new numbers.

## Phase 2: Latency tuning

1. Shrink `maxSilenceWindows` stepwise (7, 5, 4, 3), re-running the corpus each time. Stop when accuracy starts dropping because phrases get split mid-command.
2. Shrink the VAD window (100 ms to 30-50 ms) if the harness shows it helps.
3. Check the three-commands-in-a-row case ("volume up, next song, open Safari"): with the FIFO queue they should fire as separate actions, not merge into one.
4. **Stretch only, if time remains:** route on the stable partial prefix for Tier A commands.
   - Fire only when no longer valid command starts with that prefix (so "volume up" is not fired while the speaker is saying a longer command that begins the same way).
   - Keep a committed cursor of tokens already consumed, so the final segment decode does not re-fire the command.
   - Dedupe in the queue on (command, token offset).
   - Expect the stable prefix to lag the audio by about one extra decode pass.
   - If this is not solid by demo week, skip it.

## Phase 3: Rules lane

1. Normalize the transcript (lowercase, strip punctuation and filler like "um", "please", "hey") and match against the phrasing list per command. Exact and near-exact matches fire.
2. **Bias Whisper** with an initial prompt containing the command words and the demo app and site names.
3. **Fuzzy match** app and site names against the fixed demo list only. A short list means few false matches.
4. **Mishearing table:** look at corpus failures and add common Whisper errors (for example "pause" heard as "paws") as explicit aliases. Re-run after each batch of additions.
5. **Drop junk segments:** ignore very low-energy segments and the usual Whisper silence hallucinations before routing.
6. No match means fall through to Laya (Phase 4), not a guess.

## Phase 4: Laya lane

1. **Confirm Laya's real latency on this Mac before relying on it.** Laya's README reports 33 ms on a Tesla T4 GPU and 193-464 ms on CPU (preloaded). The earlier 10-40 ms figure in the latency report needs its device and settings confirmed. Benchmark on the M3 Max: MPS vs CPU vs ONNX, with small `max_len` and `head_max_len` since commands are short. Report p50/p95 for one forward pass answering all questions together.
2. Run Laya as a persistent, preloaded process with a warmup call at startup. Measure IPC cost from the Swift app.
3. Keep every question at about 20 options or fewer (accuracy falls off beyond that because options share a fixed token budget). Resolve app and site names in code, not as Laya options.
4. Use `min_confidence` with a threshold **fitted on the Phase 0 corpus**. The shipped checkpoints are over-confident, and the multilingual checkpoint has no fitted temperatures. Validate the threshold on the held-back phrasings.
5. Below threshold: do nothing visible, and return the light to Armed. Unsure is not surfaced.
6. Be aware that option order affects answers. If a command pair is repeatedly confused, try the `option_order` rotation trick, which costs extra rows.
7. Fine-tune or calibrate on your own command phrases if zero-shot accuracy is poor. The base checkpoints are weak zero-shot.
8. **Decision gate:** if Laya is consistently over about 100 ms on this Mac, the Laya lane will push its commands past the 700 ms p95 target. In that case, restrict Laya to the ambient yes/no gate and to commands the rules missed on a non-time-critical path, and say so in the write-up. Also consider a tiny Core ML classifier over the closed intent set as an alternative.

## Phase 5: Ambient guard

1. Require the utterance to be command-shaped: for the rules lane, the whole segment must be the command; for the Laya lane, it must be short and start with or consist of a catalog verb phrase. "I need to turn the volume up on the TV" must not fire.
2. Add Laya's yes/no question ("is this utterance a command directed at the computer?") as a required pass for Laya-lane commands.
3. Tune thresholds against the false-triggers-per-hour number from the ambient recording, not by feel.
4. Add a plain on/off toggle so ambient mode can be switched off during the talk if the room is noisy.
5. Rejected ambient speech only moves the light through Hearing and back to Armed. Nothing else is shown.

## Phase 6: Visual feedback (verify, do not redesign)

The light table is already implemented in `MenuBarIconView`. Verify each row against real events:

| State | Light | Pipeline event | Check |
|---|---|---|---|
| Off | Neutral `labelColor`, slashed glyph, no colored light | App closed or listening paused | Looks right when paused or closed |
| Armed | Dim white, 4 s sine breath (0.30-0.65) | Mic live, nothing relevant heard | Visible but calm |
| Hearing | White, 0.70 + 0.30 x level, fed per capture chunk | Voice detected; follows audio level | Responds immediately when you start talking |
| Executed | Green flash, 0.3 s fade, retriggered per action | Dispatch complete for each action | Three quick commands show three flashes |
| Waiting | `systemOrange` (red-leaning amber), breathing | Not used in v1 (no confirmation or LLM lane) | Reserved for later |
| Error | `systemRed`, solid | Mic permission denied, model not loaded, capture failure | Unmistakable |
| Unsure | Not surfaced | Low-confidence or rejected speech | Unmatched speech just returns to Armed |

Notes:
- Hearing is fed per capture chunk (1024 samples at 16 kHz, about 64 ms), independent of the VAD window changes in Phase 2.
- Color is never the only cue: Off has a slashed glyph, Error is the only solid state, and Armed, Waiting and Executed differ in motion.
- Check readability from the back of the room. The Executed flash should read at a glance, and Error should be unmistakable.

## Phase 7: Demo readiness

1. Write a demo script: 6-8 commands in a fixed order, including one three-command chain, one paraphrase that only Laya catches, and one unsupported phrase to show that nothing wrong happens.
2. Rehearse on the presentation setup (same mic, same room if possible, same display) and re-run the harness with that mic.
3. Prepare a fallback: a pre-recorded screen capture of the demo, in case of audio or permission trouble. Check Microphone, Accessibility and Input Monitoring permissions beforehand.
4. Put the before/after numbers on a slide: p50/p95 latency, command accuracy, false triggers per hour, and the rules vs Laya vs hybrid ablation. Compare end to end against Jev Voice's measured 850-1,200 ms, noting yours is fully local and private.
5. When comparing with cloud, include endpointing on both sides. The commonly quoted cloud figure (about 500 ms) usually counts only network plus decode, not the silence gate.

## Stop line

Once the v1 targets are met and the demo script runs clean three times in a row, stop adding features. Everything below waits.

---

## Later (v2, after the presentation)

- **Apple's on-device speech recognition** for the partial lane versus Whisper partials, with Whisper as the verifier.
- **Small Whisper for partials, larger Whisper for the final decode.**
- **Whisper gating improvements.**
- **Prefix routing for all Tier A commands**, if skipped in v1.
- **Local LLM slow lane** (a 4B-class model in MLX 4-bit, kept resident), invoked only when rules and Laya abstain, for richer commands such as messaging.
  - Use constrained decoding to an action schema (intent, parameters). Its job is slot extraction, not writing.
  - For "message <contact> ...": resolve the contact from Contacts in code, open the chat, and put the body in the compose field. Do not auto-send by default; send only on an explicit "send it" confirmation.
  - Show the Waiting light while the model runs; on a failed or invalid result, drop silently.
  - Report its latency separately from the fast lanes.
- **Risky command tier** (send, quit, delete, lock) with confirmation, using the Waiting light.

---

## Deliverable per phase

A short note with before/after command accuracy, false triggers per hour, p50/p95 latency, and time-to-Hearing. Stop and report if a change makes any of them worse.
