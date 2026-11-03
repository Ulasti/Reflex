# Phase 0 Baseline Audit — Reflex voice pipeline

Branch: `atlas/phase-0-baseline` (from `dev` @ 735ffd6)
Date: 2026-11-03
Scope: audit of the components named in roadmap Phase 0, runtime call graph,
double-dispatch risks, and a proposed canonical event schema. No code changed.

---

## 1. Runtime call graph (live path)

```
Press Start Listening
  └─ AppModel.startListening()
       ├─ requestMicrophoneAccess()
       ├─ LiveTranscriber (WhisperKit) init + warmup  [if installed]
       ├─ liveUpdatesTask subscribes live.updates
       │     └─ liveText = update.text
       │     └─ evaluateIncremental(text)   [early commit path]
       └─ MicMonitor.start()
            ├─ onLevel  -> UI level + speechStartedAt/lastVoicedAt
            ├─ onPartial -> liveTranscriber.consumePartial  [live only]
            └─ onSegment -> AppModel.handleSegment(samples, reason, audioDuration)
                 ├─ finalizeUtterance() -> text   [live]  (or .samples in segmented mode)
                 ├─ wasCommitted?  -> if true: skip queue (finalized path dropped)
                 └─ else append PendingSegment to pendingSegments (FIFO)
                      └─ if !processing: drainSegments()
                           ├─ media suppression check (unless decisive rule)
                           ├─ cooldown sleep (0.3 s)
                           ├─ resolveLiveTranscript(text) / resolveCommandStreamCompound
                           │     ├─ normalize + sanitize
                           │     ├─ CompoundRouter.split (if compound)
                           │     └─ per clause: RuleRouter short-circuit (>=0.9)
                           │            else LayaRouter.route -> DecisionArbiter.decide
                           │            + confidence floor / addressed gate
                           └─ dispatch(decision) -> ActionDispatcher (detached)
                                └─ UI update, flash, sound, session log, VoiceEvent
```

Segmented path replaces the live transcriber with `engine.resolveCommandStreamCompound(samples,...)`
(CoreML Whisper then the same route + dispatch).

## 2. Component audit (roadmap Phase 0 list)

| Component | File | Role | Notes |
|---|---|---|---|
| MicMonitor | `ReflexCore/.../MicMonitor.swift` | VAD over 100 ms windows; emits onSegment/onPartial/onLevel | min 4 speech windows; segment emits ~0.6–0.7 s after silence (7 windows); hard cap 64k samples |
| LiveTranscriber | `ReflexCore/.../LiveTranscriber.swift` | WhisperKit rolling buffer; `consumePartial`, `finalizeUtterance`, `updates` stream | warmup at start |
| TranscriptSanitizer | `ReflexCore/.../TranscriptSanitizer.swift` | rejects empty, non-speech annotations, repetition loops | validation only, not audio cleaning |
| RuleRouter | `ReflexCore/.../RuleRouter.swift` | verb-driven classifier; `isDecisive` = conf >= 0.9 | short-circuits Laya when decisive |
| LayaRouter | `ReflexCore/.../LayaRouter.swift` | CoreML forward pass; `preload/unload`, in-flight dedup | optional; rules-first skips it |
| DecisionArbiter | `ReflexCore/.../RuleRouter.swift` (same file) | decide + shouldExecute (conf>=0.4, addressed>=0.5); strongRule=0.9, strongLaya=0.55 | confidence floor prevents guessing |
| PayloadExtractor | `ReflexCore/.../PayloadExtractor.swift` | extracts appName, query/site, text, title, folder, volumeOp, shortcut, etc. | AppResolver for installed apps |
| ActionDispatcher | `ReflexCore/.../ActionDispatcher.swift` | macOS dispatch by `plan.action`; non-mac stub noOp | detached, off main actor |
| NowPlaying | `ReflexCore/.../NowPlaying.swift` | MediaRemote status via dlsym, timed semaphores (1.5 s) | used for media suppression |

Supporting: `CompoundRouter` (clause split), `TranscriptNormalizer`, `ReflexSystemEngine` (actor, route orchestration),
`TranscriptEventBuffer` + `IncrementalCommitGate` (safe-target allowlist), `VoiceEventLogger` (monotonic nanos).

## 3. Double-dispatch risks (Phase 0 priority)

1. **Early commit during finalize await (HIGH).** `handleSegment` captures `wasCommitted` *before* `await live.finalizeUtterance()`. If an early commit lands during that await, `wasCommitted` stays false and the finalized utterance is still queued + dispatched → duplicate action. No re-check after finalize. Fix: re-read `incrementalCommitted` after finalize before queueing.
2. **Finalized path ignores `incrementalCommitted` (MEDIUM).** `resolveLiveTranscript` does not consult `incrementalCommitted`; it relies solely on `handleSegment`'s early return. If that gate is bypassed (candidate mismatch), finalized dispatch occurs post-commit. Fix: guard at top of `resolveLiveTranscript`.
3. **Drain continues after stop (MEDIUM).** `stopListening()` cancels `liveUpdatesTask` and resets incremental state but does not clear `pendingSegments` or `processing`; an in-flight drain keeps dispatching queued segments after listening stops. Fix: clear queue + set a `stopping` flag checked by drain.
4. **Early commits only when idle (BY DESIGN, document).** `evaluateIncremental` guards `!processing`; a slow drain blocks early commits. Acceptable but must be measured; document as latency contributor.
5. **Candidate identity reuse (LOW).** `resolveLiveTranscript` reuses `currentCommandID` when finalized text matches candidate; mismatch creates new UUID. Verify no double command ID across utterances. Add test.

Mitigation target for Phase 0: add regression tests asserting (a) one dispatch per utterance even when early commit fires, (b) no dispatch after `stopListening`, (c) command ID uniqueness.

## 4. Cancellation / queue handling observations

- `pendingSegments` is a FIFO array; drain is single-owner via `processing` flag. No concurrent drains observed (guarded).
- `evaluateIncremental` and `drainSegments` are both `@MainActor` (via Task), so state mutations are serialized on main.
- Media suppression (`NowPlaying.status`) runs on a detached task with 1.5 s semaphore timeout; can stall segment decisions up to 1.5 s.
- Cooldown is a sleep inside drain, blocking the queue (intended, but contributes to p95).

## 5. Proposed canonical event schema

Extend `VoiceEvent` (already has sessionID, utteranceID, commandID, eventType, monotonicNanos, wallClock, executionPath, transcriptRevision, detail) with:

- `stage`: enum {capture, vad, transcription, normalization, routing, arbitration, entity_resolution, dispatch, verification}
- `latencyMs`: Double? (stage duration)
- `correlationId`: UUID (utterance-scoped; = commandID for single, parent for compounds)
- `outcome`: enum {success, no_op, rejected, failed, skipped}
- `contextSnapshot`: optional {frontmostApp, playbackState, uiTargetCount} (Phase 1+)
- `inputHash`: short hash of transcript for dedup analysis

One event per stage boundary, monotonic timestamps already present. This lets Phase 0 attribute failures to capture/transcription/interpretation/resolution/execution as required by the exit gate.

## 6. Baseline measurements (reference)

From prior session evidence (not a fully labelled benchmark):
- Mean last-voiced-to-dispatch: ~1044 ms
- Median: ~1038 ms
- p95: ~1698 ms
- Baseline ablation (pre-change binary): rules 45.1% / Laya 21.6% / hybrid 45.1%; last-word→route p50 594 ms / p95 789 ms (`replay-baseline-v1.{txt,csv}`).

Phase 0 must reproduce these via `reflex-cli --replay <dir>` and attach a labelled corpus with expected outcomes per command.

## 7. Phase 0 exit-gate checklist

- [ ] Reproducible benchmark reproduces current measurements
- [ ] Each evaluated command has manually verified expected outcome
- [ ] Failure attribution possible (capture/transcription/interpretation/resolution/execution)
- [ ] Regression tests before architectural changes (double-dispatch tests above)
- [ ] Event schema with monotonic timestamps + correlation ID (proposed §5)
- [ ] Local vs external-service commands separated (web search, music catalog)

## 8. Next concrete steps (smallest slices)

1. Add regression tests for double-dispatch (items 1–3) in `ReflexCoreTests`.
2. Define `VoiceEvent` schema extension (§5) behind a version flag; update `VoiceEventLogger`.
3. Build labelled corpus skeleton: `atlas/corpus/phase-0-labels.json` with command, expected target, expected outcome, category.
4. Re-run `reflex-cli --replay` to capture per-stage timings once schema lands.
5. Only then begin Phase 1 (context/capability foundation).

---

Evidence: atlas/docs/phase-0-baseline-audit.md | Pass 0 | Fail 0 | Unverified 0 (audit doc, no code changed)
