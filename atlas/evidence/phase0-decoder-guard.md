# Phase 0 — decoder-guard defect (pre-baseline fix)

Live Demo v1 plan, Phase 0.4. Found while wiring the replay harness.

## Symptom
Any utterance shorter than ~1.1 s decodes to an empty string on the
WhisperKit live path (`LiveTranscriber.finalizeUtterance`), so the final
transcript is "" and the command is dropped. This kills short commands:
"copy", "pause", "skip", "undo" are all ≤ ~1.05 s in the corpus.

## Repro (before fix, release CLI `95591ac` + harness work)
  reflex-cli --vlive corpus/train/copy__1__take1.wav small --wk
    -> "no speech detected in segment" / final: <empty>   (file is 1.034 s)
  reflex-cli --vlive corpus/train/play_pause__1__take1.wav small --wk
    -> "no speech detected in segment" / final: <empty>   (file is 0.928 s)
  reflex-cli --vlive corpus/train/volume_mute__1__take1.wav small --wk
    -> "final: Mute."                                     (file is 1.248 s)

Boundary check (silence-trimmed cut of brightness_up__6__take1):
  16000 samples (1.00 s) -> empty
  16800 samples (1.05 s) -> empty
  17600 samples (1.10 s) -> "Screen a bit brighter"

Segmenter was healthy in all cases: onSegment fired, `inUtterance=true`,
`rolling=16000`; `wk.transcribe` returned an empty result within ~5 ms.

## Cause
WhisperKit returns no transcription for windows under ~1.1 s of audio.

## Fix (ReflexCore/Sources/ReflexCore/LiveTranscriber.swift)
- `decodeAudio(_:)` pads the decode window to 3 s of zeros (Whisper pads to
  30 s internally anyway, so no cost). Applies to partials and finals.
- `clean(_:)` drops non-speech markers Whisper emits alongside the padding
  ("[BLANK_AUDIO]", "[MUSIC]") so they never reach routing.
- Tests: ReflexCore/Tests/ReflexCoreTests/LiveTranscriberDecodeTests.swift
  (3 cases); suite total 59 tests / 15 suites pass.

## After fix (same commands)
  copy__1__take1 -> "Copy."
  play_pause__1__take1 -> "Pause."

## Also found while harnessing: unordered partial tasks
The app spawns one `Task` per VAD window (`AppModel.startListening`), so an
older window can land last and roll the transcriber's buffer back to a short
prefix. Observed nondeterministic empty finals; the harness pumps partials
FIFO. App-side fix is plan Phase 1 (queue instead of Task-per-window).
