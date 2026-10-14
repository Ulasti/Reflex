# Reflex — Phase-by-Phase Implementation Plan

Mapping the Jev Voice action/workflow reference
(`~/Desktop/Jev_Voice_Action_Reference.md`) onto Reflex. Two fronts, in order:
**A. Architecture first** (how commands become typed plans → fixes the parsing
bugs and the low-confidence dispatches seen in logs), **B. the action catalog**
(every shortcut/workflow the reference has that we don't).

Current state (from `ReflexCore/Sources`): 6 ML actions (`open_app`,
`web_search`, `file_operation`, `media_control`, `general_query`,
`environment_setup`) + rule-only actions (`open_url`, `type_text`,
`display_control`, `browser_command`). Dispatcher re-parses the raw transcript
with `appName`/`phraseBetween`/`searchQuery` heuristics. No generic shortcuts,
no scroll amounts, no `new_item`, no screenshot, no folders, no system ops, no
compound commands, no confidence floor, no addressed gate.

**Design constraint:** `reflex-questions.json` is pre-tokenized (models were
exported with these exact choices). Adding a *new ML action kind* needs a Laya
re-export/retrain. New action kinds that already work are surveyable only via
`RuleRouter` + `ActionDispatcher` (rule confidence ≥0.9 beats a weak Laya call
in `DecisionArbiter`). So the plan *always* adds new actions rules-first, and
only deepens Laya's question set when retraining is feasible.

---

## Phase A — Architecture: payloads, plans, gating, compounds

### A1. Candidate payload extraction ("select, don't generate")
**File:** new `ReflexCore/Sources/ReflexCore/PayloadExtractor.swift`
Port Jev's `text_candidates` + criteria regexes, adapted to our verb set:
- `_TITLE`: `called|titled|named|that says …`
- `_TEXT_PATTERNS`: `type|write|paste|dictate …`, `search|look up|find …`,
  trailing `for|about|of|on …`, quoted `"…"`
- `_TRAILING_IN_APP` strip (→ becomes `in_app`), `_TRAILING_SUBMIT` (→ `submit`)
- A `Candidates` type: `text`, `query`, `appName`, `site`, `folder`, `title`,
  `direction`, `amount`, `shortcutName`, each backed by ordered candidate spans.
Refactor `ActionDispatcher.appName/searchQuery/phraseBetween/parseSiteSearch`
to feed/consume these — one source of truth instead of six ad-hoc slices.

### A2. Typed `Plan` with carried confidence
**File:** new `ReflexCore/Sources/ReflexCore/CommandPlan.swift`
Mirror `brain.Plan`:
```swift
struct CommandPlan {
  let action: String
  let confidence: Double      // min over the extractions it used
  let submit: Bool
  let in_app: Bool
  let compound: Bool
  let addressed: Double
  let args: [String: String]
  let candidates: Candidates
}
```
Dispatcher signature becomes `dispatch(_ plan: CommandPlan)`; entity extraction
happens inside A1's extractor, not re-sliced mid-execution. Remove `parseFailure`
paths that currently guess ("quit calculator", "openyoutube.com").

### A3. Confidence floor + addressed gate (fixes entry 12 "50 times 20")
**File:** `DecisionArbiter.swift`, `ReflexSystemEngine.swift`
Add `ACTION_MIN_CONFIDENCE` (≈0.4) and an `addressed` noul (Laya `noul` + rule
fallback). Below floor → `.noOp("not sure what you meant")`, never dispatch to a
wrong bucket `file_operation` at P(6–29%) again.

### A4. Compound command support
**File:** new `ReflexCore/Sources/ReflexCore/CompoundRouter.swift`
Port `split_compound` (`and then|then|and also|and`), fold trailing
"hit enter" into the prior type_text's `submit`, reuse the same plan for a
single-part utterance, execute parts sequentially. CLI flag `--compound` to test.

### A5. Wire upstream
- `RuleRouter.classify` stays the intent gate; add any new rule targets from
  Phase B here.
- AppModel live path: run A3/A4 before dispatch.
- **Verify per step:** `swift build`, `--laya-ref` stays 126/126, `--rule` over
  the A-log phrases (`Search, PSP`, `quit calculator`, `50 times 20`), app
  schemes BUILD SUCCEEDED.

---

## Phase B — Action catalog (rules-first, no retrain needed)

Every new target here = RuleRouter rule (≥0.9, beats weak Laya) + dispatcher
case + `ReflexActionResult` case. Verify each against the reference table.

### B1. Generic keyboard shortcut controller (≈40 shortcuts)
**File:** new `ReflexCore/Sources/ReflexCore/ShortcutController.swift`
Port `SHORTCUTS` (key codes `code:N` or chars + modifier arrays) with the Jev
criteria strings — enter, esc, tab, space, backspace, arrows, copy, paste, cut,
undo, redo, select_all, save, find, new, new_tab, close, reopen, quit_app,
minimize, hide, fullscreen, next/prev tab, browser back/forward, reload,
address_bar, spotlight, switch_app, next_window, delete_word, delete_line,
zoom in/out, bold, italic, send_message, emoji_picker.
- `ShortcutController.press(named:)` → System Events, matches our existing
  `keystroke` helper; Accessibility-gated (surfaced by `--diagnose`).
- Router: `shortcut` target; criteria words select the key (code-side, like
  Jev's SHORTCUT_CRITERIA; no model needed). Confidence from match strength.
- Reuse for existing `browser_command` tab/back/forward/reload cases — one
  code path.

### B2. Real scroll events with top/bottom & amounts
**File:** extend `BrowserController`/new `ScrollController.swift`
Port Jev: Quartz `CGEventCreateScrollWheelEvent` (fallback to arrow keys) +
`direction ∈ up|down|top|bottom` + `amount ∈ little|page|a_lot`.
Add `scroll` rule target; supersedes the single "scroll down/up" browser rule.

### B3. Volume + media completion
- Volume: add `max` (100%), `half` (50%) to the existing up/down/mute/set path.
- Media: keep `NowPlaying` (better than HID — routes to actual host), but add
  Quartz HID media-key fallback (NX 16/17/18) when MediaRemote returns nothing
  and the user named a browser. Mirrors the reference's HID event path.

### B4. `new_item` workflow (tabs, windows, documents with titles)
**File:** `ActionDispatcher` + rule
`new tab` → browser; `new window/document/note` → ⌘N in frontmost (or named
`in_app`); optional title → type_text with `submit`. Mirrors `new_item` +
`has_title` + `in_app` and fixes the "open a new tab" → browser_command split.

### B5. `open_folder`, `screenshot`, `system` ops
**Files:** `ActionDispatcher` + rule targets
- `open_folder`: Downloads/Desktop/Documents/… via Finder (we have FOLDERS data
  in Jev reference; `file_operation` already creates folders).
- `screenshot`: `screencapture -x` to Desktop.
- `system`: lock (⌘⌃Q), sleep display (`pmset displaysleepnow`), show desktop,
  toggle dark mode, empty trash.

### B6. `stop` action
"stop listening / go to sleep / exit" → `stop` target → app tears down cleanly.
Also the natural home for future wake-word/hold/toggle modes.

### B7. Sites & engines catalog
**File:** `ActionDispatcher` SITES/SEARCH_ENGINES tables
Adopt Jev's curated `SITES` (youtube, google, wikipedia, github, reddit, maps,
amazon, …) and engine templates per site; add `domain_guess` ("dot com" →
`.com`, "youtube dot com"). Extends existing `parseSiteSearch`/`siteSearchURL`.

---

## Phase C — Structural follow-ups (captured from your notes)

- **Wake word / hold-to-speak / toggle-listening**: reuse addressed gate (A3)
  as the ambient-command filter; add `strip_wake` + Caps Lock→F18 remap (Jev
  `hotkey.py`) when you're ready.
- **Status LED + settings page**: single `StatusLight` enum
  (Red = unavailable / Amber = busy / Green = listening) — AirPods/PSP-style
  pulsing; feed from engine lifecycle; settings page lists toggles +
  `--diagnose` results re-run in-app.
- **Feedback**: replace success-only traces with the light; ding on done/fail.

## Suggested order
A1→A2→A3→A4→A5 (verify once, fixes the log bugs) → B1 (biggest "more actions"
win) → B4 → B5 → B6 → B2 → B3 → B7 → C. Unless you tell me otherwise I'll start
with A1.
