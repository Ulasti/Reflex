# Phase 0 draft — v1 command set and phrasings (DRAFT, awaiting freeze)

Companion to `live-demo-v1-plan.md`, Phase 0 steps 1-2. Status: **drafted by
the agent 2026-10-19, not frozen.** The user freezes it (edit this file), then
records from it.

## Rules for this set

- Tier A: no parameters, reversible, one action each. Tier B: closed parameter
  (app or site name from the fixed lists below).
- Nothing that sends, deletes, quits, or locks.
- `split = heldout` phrasings are **never** shown to the rules lane or used for
  prompt/alias work — they test Laya generalization only. Do not record a
  heldout phrasing as a synonym of a train phrasing.

## Recording protocol

- Takes per phrasing: minimum 2 (normal + fast), ideally 4 (+ fast, + noisy).
  Time-boxed fallback: 2 takes everywhere beats 4 takes on half the list.
- Ambient: 30-60 minutes of normal conversation, no commands spoken as
  commands, but with command words inside ordinary sentences (decoys listed
  below). This corpus measures false triggers per hour.
- Format: anything the Mac records (Voice Memos, QuickTime); name files so the
  harness can parse them.
- Naming: `corpus/<split>/<command_id>__<phrase_id>__<take>.wav` (or .m4a) and
  `corpus/ambient/<subject>_<NNN>.wav`. `phrase_id` = the `#` column below.
- Manifest: `corpus/manifest.csv` with header
  `file,command_id,phrase_id,split` — one row per recording. The harness reads
  this, nothing else.

## Command set (25 commands)

### Tier A (16)

| # | command_id | label | phrasings (id: text [split]) |
|---|---|---|---|
| 1 | volume_up | Volume up | 1: "volume up" [train] · 2: "turn it up" [train] · 3: "louder" [train] · 4: "raise the volume" [train] · 5: "crank it up" [heldout] · 6: "volume a bit higher" [heldout] |
| 2 | volume_down | Volume down | 1: "volume down" [train] · 2: "turn it down" [train] · 3: "quieter" [train] · 4: "lower the volume" [train] · 5: "bring the volume down" [heldout] · 6: "it's way too loud" [heldout] |
| 3 | volume_mute | Mute | 1: "mute" [train] · 2: "mute the volume" [train] · 3: "silence it" [train] · 4: "volume off" [train] · 5: "put it on mute" [heldout] · 6: "mute everything" [heldout] |
| 4 | play_pause | Play / pause | 1: "pause" [train] · 2: "play" [train] · 3: "pause the music" [train] · 4: "resume" [train] · 5: "toggle playback" [heldout] · 6: "stop for a second" [heldout] |
| 5 | next_track | Next track | 1: "next track" [train] · 2: "next song" [train] · 3: "skip" [train] · 4: "skip this one" [train] · 5: "go to the next song" [heldout] · 6: "skip ahead" [heldout] |
| 6 | prev_track | Previous track | 1: "previous track" [train] · 2: "go back" [train] · 3: "last song" [train] · 4: "previous song" [train] · 5: "play the last one" [heldout] · 6: "back to the previous one" [heldout] |
| 7 | scroll_up | Scroll up | 1: "scroll up" [train] · 2: "go up" [train] · 3: "page up" [train] · 4: "move up" [train] · 5: "scroll up a bit" [heldout] · 6: "take me to the top" [heldout] |
| 8 | scroll_down | Scroll down | 1: "scroll down" [train] · 2: "go down" [train] · 3: "page down" [train] · 4: "move down" [train] · 5: "scroll down a bit" [heldout] · 6: "take me to the bottom" [heldout] |
| 9 | screenshot | Screenshot | 1: "screenshot" [train] · 2: "take a screenshot" [train] · 3: "capture the screen" [train] · 4: "screen capture" [train] · 5: "grab the screen" [heldout] · 6: "take a picture of the screen" [heldout] |
| 10 | dark_mode | Dark mode toggle | 1: "dark mode" [train] · 2: "toggle dark mode" [train] · 3: "switch to dark" [train] · 4: "turn on dark mode" [train] · 5: "make it dark" [heldout] · 6: "night mode" [heldout] |
| 11 | copy | Copy | 1: "copy" [train] · 2: "copy that" [train] · 3: "copy this" [train] · 4: "put it on the clipboard" [train] · 5: "copy the selection" [heldout] · 6: "copy everything" [heldout] |
| 12 | paste | Paste | 1: "paste" [train] · 2: "paste that" [train] · 3: "paste it here" [train] · 4: "put it here" [train] · 5: "paste from the clipboard" [heldout] · 6: "drop it in here" [heldout] |
| 13 | undo | Undo | 1: "undo" [train] · 2: "undo that" [train] · 3: "take it back" [train] · 4: "undo it" [train] · 5: "undo the last change" [heldout] · 6: "never mind, undo" [heldout] |
| 14 | show_desktop | Show desktop | 1: "show desktop" [train] · 2: "minimize everything" [train] · 3: "go to the desktop" [train] · 4: "show me the desktop" [train] · 5: "clear the screen" [heldout] · 6: "desktop please" [heldout] |
| 15 | brightness_up | Brightness up | 1: "brightness up" [train] · 2: "brighter" [train] · 3: "turn up the brightness" [train] · 4: "more light" [train] · 5: "increase brightness" [heldout] · 6: "screen a bit brighter" [heldout] |
| 16 | brightness_down | Brightness down | 1: "brightness down" [train] · 2: "dimmer" [train] · 3: "turn down the brightness" [train] · 4: "less light" [train] · 5: "decrease brightness" [heldout] · 6: "screen a bit darker" [heldout] |

### Tier B — `open <app>` (apps: Safari, Terminal, Music, Notes, Calendar)

| # | command_id | phrasings |
|---|---|---|
| 17 | open_safari | 1: "open safari" [train] · 2: "launch safari" [train] · 3: "start safari" [train] · 4: "safari please" [heldout] |
| 18 | open_terminal | 1: "open terminal" [train] · 2: "launch terminal" [train] · 3: "start terminal" [train] · 4: "open the terminal" [heldout] |
| 19 | open_notes | 1: "open notes" [train] · 2: "launch notes" [train] · 3: "start notes" [train] · 4: "open the notes app" [heldout] |
| 20 | open_music | 1: "open music" [train] · 2: "launch music" [train] · 3: "start music" [train] · 4: "open the music app" [heldout] |
| 21 | open_calendar | 1: "open calendar" [train] · 2: "launch calendar" [train] · 3: "open my calendar" [train] · 4: "start calendar" [heldout] |

### Tier B — `go to <site>` (sites: github.com, youtube.com, wikipedia.org, google.com)

| # | command_id | phrasings |
|---|---|---|
| 22 | go_github | 1: "go to github" [train] · 2: "open github" [train] · 3: "visit github" [train] · 4: "github dot com" [heldout] |
| 23 | go_youtube | 1: "go to youtube" [train] · 2: "open youtube" [train] · 3: "visit youtube" [train] · 4: "youtube dot com" [heldout] |
| 24 | go_wikipedia | 1: "go to wikipedia" [train] · 2: "open wikipedia" [train] · 3: "visit wikipedia" [train] · 4: "wikipedia dot com" [heldout] |
| 25 | go_google | 1: "go to google" [train] · 2: "open google" [train] · 3: "visit google" [train] · 4: "google dot com" [heldout] |

## Ambient decoys (say these naturally inside sentences, during the 30-60 min recording)

- "I need to open the window, it's warm in here."
- "Turn the volume up on the TV later."
- "Can you pause for a second and hand me that?"
- "Let me copy the recipe into my notes."
- "We should scroll through the photos tonight."
- "Don't undo anything on the document yet."
- "The brightness on this screen is too much for reading."
- "I'll take a screenshot of the error and send it to support."
- "Is it dark outside yet? It feels like dark mode in here."
- "Skipping lunch today." / "I went back and fixed the typo."
- Free conversation for the rest — the point is command-like words with no
  command intent, plus pure non-command speech.

## Ablation bookkeeping (plan Phase 0.5)

The harness emits one CSV row per clip:
`clip,truth_command,rules_result,laya_result,hybrid_result,dispatched,
latency_p50_source,routes` — the three configurations are filters over the same
run (rules_only = rules_result, laya_only = laya_result, hybrid = hybrid
result), so one pass over the corpus fills all three ablation cells.
