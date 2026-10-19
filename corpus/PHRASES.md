# Corpus recording script — Live Demo v1

Say each line out loud, in order, then tick it.
Canonical spec: `atlas/docs/live-demo-corpus-v0.md` — if a phrasing ever changes there,
change it here too (this file is the reading copy).

## Rules

- **2 takes minimum per line:** `take1` at normal speed, `take2` a bit faster.
  Ideal (4 takes): + `take3` normal with background noise, + `take4` fast.
- One file per take. Line stem `volume_up__1` → files `volume_up__1__take1.wav`,
  `volume_up__1__take2.wav`, …
- Repeat the phrase with a ~1 s pause between takes, tick the line, move on.
- Format: `.wav` or `.m4a`, anything the Mac records.
- Say the words exactly as written — the train phrasings become the rules-lane list.

## Where to save

```
/Users/emir/Documents/Atlas/Projects/reflex/corpus/
├── train/      Part 1 — 91 lines → 182–364 clips
├── heldout/    Part 2 — 41 lines →  82–164 clips
└── ambient/    Part 3 — one 30–60 min conversation
```

**Part 2 lines are the heldout test set.** Record them now, but never say them
while building rules, prompts, or aliases — the Laya lane is judged on them.

Recording tool: ask me for the prompt-and-name recorder script (it prints the
next line, records on enter, saves under the right name), or record manually in
Voice Memos/QuickTime and rename on export to the stems below.

---

## Part 1 — train phrasings → `corpus/train/` (91 lines)

### volume_up (4)
- [ ] "volume up" — volume_up__1
- [ ] "turn it up" — volume_up__2
- [ ] "louder" — volume_up__3
- [ ] "raise the volume" — volume_up__4

### volume_down (4)
- [ ] "volume down" — volume_down__1
- [ ] "turn it down" — volume_down__2
- [ ] "quieter" — volume_down__3
- [ ] "lower the volume" — volume_down__4

### volume_mute (4)
- [ ] "mute" — volume_mute__1
- [ ] "mute the volume" — volume_mute__2
- [ ] "silence it" — volume_mute__3
- [ ] "volume off" — volume_mute__4

### play_pause (4)
- [ ] "pause" — play_pause__1
- [ ] "play" — play_pause__2
- [ ] "pause the music" — play_pause__3
- [ ] "resume" — play_pause__4

### next_track (4)
- [ ] "next track" — next_track__1
- [ ] "next song" — next_track__2
- [ ] "skip" — next_track__3
- [ ] "skip this one" — next_track__4

### prev_track (4)
- [ ] "previous track" — prev_track__1
- [ ] "go back" — prev_track__2
- [ ] "last song" — prev_track__3
- [ ] "previous song" — prev_track__4

### scroll_up (4)
- [ ] "scroll up" — scroll_up__1
- [ ] "go up" — scroll_up__2
- [ ] "page up" — scroll_up__3
- [ ] "move up" — scroll_up__4

### scroll_down (4)
- [ ] "scroll down" — scroll_down__1
- [ ] "go down" — scroll_down__2
- [ ] "page down" — scroll_down__3
- [ ] "move down" — scroll_down__4

### screenshot (4)
- [ ] "screenshot" — screenshot__1
- [ ] "take a screenshot" — screenshot__2
- [ ] "capture the screen" — screenshot__3
- [ ] "screen capture" — screenshot__4

### dark_mode (4)
- [ ] "dark mode" — dark_mode__1
- [ ] "toggle dark mode" — dark_mode__2
- [ ] "switch to dark" — dark_mode__3
- [ ] "turn on dark mode" — dark_mode__4

### copy (4)
- [ ] "copy" — copy__1
- [ ] "copy that" — copy__2
- [ ] "copy this" — copy__3
- [ ] "put it on the clipboard" — copy__4

### paste (4)
- [ ] "paste" — paste__1
- [ ] "paste that" — paste__2
- [ ] "paste it here" — paste__3
- [ ] "put it here" — paste__4

### undo (4)
- [ ] "undo" — undo__1
- [ ] "undo that" — undo__2
- [ ] "take it back" — undo__3
- [ ] "undo it" — undo__4

### show_desktop (4)
- [ ] "show desktop" — show_desktop__1
- [ ] "minimize everything" — show_desktop__2
- [ ] "go to the desktop" — show_desktop__3
- [ ] "show me the desktop" — show_desktop__4

### brightness_up (4)
- [ ] "brightness up" — brightness_up__1
- [ ] "brighter" — brightness_up__2
- [ ] "turn up the brightness" — brightness_up__3
- [ ] "more light" — brightness_up__4

### brightness_down (4)
- [ ] "brightness down" — brightness_down__1
- [ ] "dimmer" — brightness_down__2
- [ ] "turn down the brightness" — brightness_down__3
- [ ] "less light" — brightness_down__4

### open_safari (3)
- [ ] "open safari" — open_safari__1
- [ ] "launch safari" — open_safari__2
- [ ] "start safari" — open_safari__3

### open_terminal (3)
- [ ] "open terminal" — open_terminal__1
- [ ] "launch terminal" — open_terminal__2
- [ ] "start terminal" — open_terminal__3

### open_notes (3)
- [ ] "open notes" — open_notes__1
- [ ] "launch notes" — open_notes__2
- [ ] "start notes" — open_notes__3

### open_music (3)
- [ ] "open music" — open_music__1
- [ ] "launch music" — open_music__2
- [ ] "start music" — open_music__3

### open_calendar (3)
- [ ] "open calendar" — open_calendar__1
- [ ] "launch calendar" — open_calendar__2
- [ ] "open my calendar" — open_calendar__3

### go_github (3)
- [ ] "go to github" — go_github__1
- [ ] "open github" — go_github__2
- [ ] "visit github" — go_github__3

### go_youtube (3)
- [ ] "go to youtube" — go_youtube__1
- [ ] "open youtube" — go_youtube__2
- [ ] "visit youtube" — go_youtube__3

### go_wikipedia (3)
- [ ] "go to wikipedia" — go_wikipedia__1
- [ ] "open wikipedia" — go_wikipedia__2
- [ ] "visit wikipedia" — go_wikipedia__3

### go_google (3)
- [ ] "go to google" — go_google__1
- [ ] "open google" — go_google__2
- [ ] "visit google" — go_google__3

---

## Part 2 — heldout phrasings → `corpus/heldout/` (41 lines)

Do not use these while developing rules/prompts/aliases.

### volume_up (2)
- [ ] "crank it up" — volume_up__5
- [ ] "volume a bit higher" — volume_up__6

### volume_down (2)
- [ ] "bring the volume down" — volume_down__5
- [ ] "it's way too loud" — volume_down__6

### volume_mute (2)
- [ ] "put it on mute" — volume_mute__5
- [ ] "mute everything" — volume_mute__6

### play_pause (2)
- [ ] "toggle playback" — play_pause__5
- [ ] "stop for a second" — play_pause__6

### next_track (2)
- [ ] "go to the next song" — next_track__5
- [ ] "skip ahead" — next_track__6

### prev_track (2)
- [ ] "play the last one" — prev_track__5
- [ ] "back to the previous one" — prev_track__6

### scroll_up (2)
- [ ] "scroll up a bit" — scroll_up__5
- [ ] "take me to the top" — scroll_up__6

### scroll_down (2)
- [ ] "scroll down a bit" — scroll_down__5
- [ ] "take me to the bottom" — scroll_down__6

### screenshot (2)
- [ ] "grab the screen" — screenshot__5
- [ ] "take a picture of the screen" — screenshot__6

### dark_mode (2)
- [ ] "make it dark" — dark_mode__5
- [ ] "night mode" — dark_mode__6

### copy (2)
- [ ] "copy the selection" — copy__5
- [ ] "copy everything" — copy__6

### paste (2)
- [ ] "paste from the clipboard" — paste__5
- [ ] "drop it in here" — paste__6

### undo (2)
- [ ] "undo the last change" — undo__5
- [ ] "never mind, undo" — undo__6

### show_desktop (2)
- [ ] "clear the screen" — show_desktop__5
- [ ] "desktop please" — show_desktop__6

### brightness_up (2)
- [ ] "increase brightness" — brightness_up__5
- [ ] "screen a bit brighter" — brightness_up__6

### brightness_down (2)
- [ ] "decrease brightness" — brightness_down__5
- [ ] "screen a bit darker" — brightness_down__6

### open_safari (1)
- [ ] "safari please" — open_safari__4

### open_terminal (1)
- [ ] "open the terminal" — open_terminal__4

### open_notes (1)
- [ ] "open the notes app" — open_notes__4

### open_music (1)
- [ ] "open the music app" — open_music__4

### open_calendar (1)
- [ ] "start calendar" — open_calendar__4

### go_github (1)
- [ ] "github dot com" — go_github__4

### go_youtube (1)
- [ ] "youtube dot com" — go_youtube__4

### go_wikipedia (1)
- [ ] "wikipedia dot com" — go_wikipedia__4

### go_google (1)
- [ ] "google dot com" — go_google__4

---

## Part 3 — ambient → `corpus/ambient/`

One continuous 30–60 min conversation, no commands spoken as commands.
Save as `ambient/talk_001.m4a` (continue as `talk_002`, … if split).
Slip these command words into ordinary sentences naturally:

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

The rest is free conversation — this file measures false triggers per hour.
