# Live Demo v1 — demo script (draft)

Driver: `atlas/docs/live-demo-v1-plan.md`, Phase 7. Environment: ideal room,
one mic, menu bar app loaded with the `small` Whisper variant, lights
Armed → Hearing → Executed. Numbers below are filled from the measured
evidence (see `atlas/evidence/`); rehearsal on the presentation hardware is
still pending.

## The eight beats

| # | Say | Expected light + action |
|---|---|---|
| 1 | "volume up" | green flash, system volume up |
| 2 | "next track" | green flash, music skips |
| 3 | "pause" | green flash, playback pauses |
| 4 | "volume up, next song, open Safari" — one breath | **three** green flashes, three separate actions (FIFO queue, no merge) |
| 5 | "crank it up" | green flash — a train paraphrase, not the canonical "volume up" |
| 6 | "go to github" | green flash, browser opens github.com (site alias, not a search) |
| 7 | "how do I make a nice risotto" | **nothing** — light passes through Hearing and returns to Armed |
| 8 | "screenshot" | green flash, screenshot taken |

Beat 7 is the safety demo: the pipeline's answer to speech it cannot map is
inaction, never a wild dispatch.

**Deviation from the plan:** the plan asked for "one paraphrase that only Laya
catches". The Phase 0 ablation measured Laya rescuing **zero** rule misses
(and answering `file_operation` at 0.878 confidence), so no honest Laya-only
beat exists for the closed command set. Beat 5 now demonstrates a *rules-lane
paraphrase*; Laya's v1 role is the ambient gate (Phase 5, deferred) — see the
Phase 4 write-up in the evidence file.

## Before you walk up

- [ ] Permissions: Microphone, Accessibility, Input Monitoring
- [ ] Models present (small variant), status light Armed
- [ ] Sound output at a level the mic will not hear
- [ ] Fallback ready: pre-recorded screen capture of the same 8 beats
      (record it once on the same hardware during rehearsal)
- [ ] Slide with before/after: p50/p95 last-word→route, command accuracy,
      rules/Laya/hybrid ablation

## Rehearsal

Rehearse on the presentation setup (same mic, room, display), then re-run the
corpus with that mic: `reflex-cli --replay corpus --csv <out>` — numbers from
the rehearsal mic replace the lab numbers on the slide.

Stop adding commands. Before every rehearsal:

- [ ] `reflex-cli --replay corpus --csv atlas/evidence/rehearsal.csv` — accuracy
      and latency must be within a few points of the numbers on the slide
- [ ] A live session of at least 20 minutes from the frozen demo set, verbose
      session log on
- [ ] Read the exported log for **confident wrong actions**: any entry whose
      target is not what was said, or whose confidence is P(90–90)% while the
      transcript is not a catalog phrasing. Anything wrong becomes a regression
      test, not a tweak.
- [ ] Check the latency line of each entry: `voice→dispatch` is the number the
      500/700 ms target is stated in. Entry timestamps are to the millisecond,
      so command-to-command gaps are readable straight off the log.
