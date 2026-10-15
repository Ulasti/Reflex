# Reflex → jev-voice-browser: Gap Analysis & Roadmap

**Constraints**: macOS native (Swift), Safari-first, system-wide assistant (not browser-only), local models (WhisperKit + Laya), no cloud API key.

---

## Browser Navigation Gaps

| # | jev-voice-browser Capability | Reflex Current | Gap Severity | Recommended Approach (Swift/Safari-first) | Effort |
|---|------------------------------|----------------|--------------|-------------------------------------------|--------|
| **B1** | **Structured element snapshot** — in-page JS tags every interactive element with stable `data-vb-id`, returns compact JSON (≤100 items, viewport-first, deduped, 60-char text) | AppleScript + `document.querySelectorAll('a[href]')` only for links; no stable IDs; no inputs/buttons/ARIA roles; ranking by DOM order + heuristics | **High** — core enabler for everything else | Inject a small Safari JS (`WKWebView`/`JSContext` or AppleScript `do JavaScript`) that: <br>1. Walks the DOM with a fixed selector (`a[href], button, input, textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], [role=radio], [role=switch], [role=searchbox], [role=combobox], [role=textbox], [contenteditable=true], [onclick]`)<br>2. Assigns stable `data-reflex-id` (r01, r02…)<br>3. Returns compact array: `{id, role, text, href, rect, inViewport, tag}`<br>4. Run on every `browser_command` before deciding | M |
| **B2** | **Viewport-prioritized + size-guarded snapshot** — sorts by `inViewport` then `top`; dedupes on (role, text, href); shrinks until JSON < 24k chars | No prioritization; all anchors scanned; no dedupe; no size limit | **Medium** | In the snapshot JS: sort viewport-first, dedupe, truncate text to 80 chars, cap at 100 elements. Return to Swift for policy. | S |
| **B3** | **Click via stable ID** — `locator.click()` on `[data-vb-id="e07"]`; highlight + 180ms wait; handles new tabs | JS: `element.click()` after filtering; no stable ID; highlight not possible in Safari AppleScript | **High** | Use the `data-reflex-id` from B1. In `clickLink(at:)`, find element by ID, `scrollIntoView()`, `click()`. If AppleScript can't target by custom attr, fall back to XPath/index from snapshot. | M |
| **B4** | **Visual feedback** — highlight (600ms) + toast label on the page | None | **Low** (nice-to-have) | Defer. Could inject a temporary `<div>` toast via JS if we have element coords. | L |
| **B5** | **History via real browser API** — `page.goBack()` / `page.goForward()` (single hop, layout-independent) | `ShortcutController.press("browser_back")` = ⌘[ (layout-dependent) | **Medium** | In `ActionDispatcher`, for `go_back`/`go_forward`: prefer Safari JS `history.back()` / `history.forward()` via `runJavaScript`; fallback to keystroke only if JS fails. | S |
| **B6** | **Type into field via stable ID** — `locator.fill()` + `pressSequentially` (18ms/char) + optional Enter | Not supported (only `type_text` via keystrokes to front app) | **Medium** | Add `type_into_field` intent. Use snapshot to find search/input boxes (role=searchbox/textbox/combobox). Execute via JS: `el.value = text; el.dispatchEvent('input'); if(submit) el.form?.submit()`. | M |
| **B7** | **Numbered disambiguation without model call** — overlays numbers on ambiguous candidates; spoken number parsed locally | Ordinal extraction from transcript only (`first`→0, `second`→1…); no visual disambiguation | **Medium** | When `linkIndex` is ambiguous (multiple candidates within threshold), return a "disambiguate" result with top N candidates. UI shows numbered list; user says "two" → parse locally via existing `parseCandidatePick` logic. No extra model call. | M |
| **B8** | **Site-specific search URLs & search-box fallback** — code owns URL templates; if page has search box, types there instead of navigating | `ActionDispatcher.webSearch` uses Google URL; `openURL` for site search; no search-box detection | **Low** | Keep current URL-template approach (works). Add `searchBoxId` to snapshot (detect `<input type=search>`, `[role=searchbox]`, placeholder "search"). If present and intent=search, use `type_into_field` + Enter instead of navigate. | S |
| **B9** | **Destructive-action confirmation gate** — explicit `destructive` question; if ≥0.5 on click → requires spoken "confirm" | None | **Low** (safety) | Add a `destructive` heuristic in policy: if target element matches `[type=submit]`, `[role=button]` with text "buy|order|checkout|delete|send|post|confirm|pay", require explicit "confirm" utterance before executing. | S |
| **B10** | **Context-aware corrections** — `is_correction` question + reversal logic: "no not that one" → reverse last action; "the other one" → exclude previous target | No structured correction handling; "go back" works but "not that one" falls through | **Medium** | Add `lastBrowserAction` to `AppModel` (type, targetId, targetLabel, URL before/after). In `PayloadExtractor`/`RuleRouter`, detect correction phrases ("not that", "other one", "wrong", "undo"). If correction + no new target → execute `go_back`. If correction + new ordinal → re-run click with previous target excluded. | M |

---

## Engine Pipeline Gaps

| # | jev-voice-browser Capability | Reflex Current | Gap Severity | Recommended Approach (Swift/local models) | Effort |
|---|------------------------------|----------------|--------------|-------------------------------------------|--------|
| **E1** | **Parallel typed questions in one request** — 9-11 questions (intent, target, site, complete, is_command, destructive, scroll, text_span, url_span, tab_direction, is_correction) answered simultaneously | Sequential: RuleRouter (keywords) → LayaRouter (intent+slots) → DecisionArbiter; no parallelism | **High** (latency & accuracy) | **Keep local models.** Replace RuleRouter+LayaRouter with a single Laya prompt that asks multiple typed questions at once (choice/noul/score). Laya supports structured output; we can ask: `intent`, `target_id`, `site`, `complete`, `is_command`, `destructive`, `scroll_amount`, `text_span`, `url_span`, `tab_direction`, `is_correction` in one call. Returns typed probs → Swift policy decides. | L |
| **E2** | **Model only picks; code owns control flow** — Jev returns probabilities; pure Swift policy applies thresholds → ACT/WAIT/IGNORE/CONFIRM/DISAMBIGUATE | Laya returns intent+slots; DecisionArbiter is a simple confidence gate; control flow mixed in routers | **High** (architecture) | Refactor: Laya returns **only** structured probabilities. Swift `PolicyEngine` (new) contains all thresholds and decision logic. Routers become feature extractors only. | L |
| **E3** | **Explicit context in every request** — `previous_page` (url, title) + `recent_actions` (last 3: said, action, target, outcome, seconds_ago) | Session log exists but not passed to Laya/Router | **High** (enables corrections, "back to results") | Add `BrowserContext` struct to `AppModel`: `previousPageURL`, `previousPageTitle`, `recentBrowserActions: [BrowserAction]` (max 3). Serialize into Laya prompt as `context: { previous_page: {...}, recent_actions: [...] }`. | M |
| **E4** | **Completion gating** — `complete ≥ 0.6` OR 900ms silence OR final result; free-text payloads wait for 600ms silence | Single feedback cooldown (1s); VAD-based segmentation; no explicit "is command complete" signal | **Medium** | Add `complete` question to Laya (noul). In live mode, track silence since last word; if `complete < 0.6` and silence < 900ms → WAIT. For search/type intents, require silence ≥ 600ms OR recognizer final. | M |
| **E5** | **Candidate spans extracted by code** — regex extracts quoted spans, post-verb tails, post-"for", post-first-word; Jev only picks one | `PayloadExtractor` does similar but less systematic; `query`/`text`/`site` extracted in one pass | **Low** (already close) | Keep `PayloadExtractor`; ensure it over-generates candidates (like `spans.js`). Laya's `text_span`/`url_span` questions pick from `candidates.text`/`candidates.url` arrays. | S |
| **E6** | **Speculative overlapping requests** — up to 2 in flight; older cancelled via AbortSignal when new transcript arrives | Single request per utterance; no cancellation | **Medium** (live feel) | In live mode (`LiveTranscriber`): keep last `Task` for Laya request. On new partial, cancel previous task, start new one with updated transcript. Max 2 in flight. | M |
| **E7** | **Number parsing when overlays visible** — bare "two"/"second" parsed locally via lookup table | Ordinal extraction in `PayloadExtractor`/`RuleRouter`; works without overlays | **Low** | Keep current ordinal parsing. When disambiguation UI shows numbers, also accept bare number words via same logic. | S |
| **E8** | **Closed-set intents immune to correction** — "go back" after scroll = fresh `go_back`, not "undo scroll" | No such distinction; "go back" always = history back | **Low** | In `PolicyEngine`, if `intent` is closed-set (`go_back`, `go_forward`, `reload`, `scroll_*`, `switch_tab`) and `is_correction` high → treat as fresh command, not correction. | S |
| **E9** | **Latency observability** — per-request Jev latency, p50, tokens, cost, command→action time | `--diagnose` shows model load; no per-decision latency breakdown | **Low** | Add `DecisionMetrics` to `ReflexDecision`: `routerLatencyMs`, `layaLatencyMs`, `policyLatencyMs`, `executionLatencyMs`. Log in verbose mode. | S |

---

## Prioritized Roadmap (Phased)

### Phase 1: Foundation (2-3 weeks)
| ID | Task | Dependencies |
|----|------|--------------|
| B1 | Safari element snapshot JS (stable IDs, compact JSON) | — |
| B2 | Viewport prioritization + size guard in snapshot | B1 |
| E3 | `BrowserContext` in `AppModel` (previous page + recent actions) | — |
| E5 | Align `PayloadExtractor` → over-generate candidates for Laya | — |

### Phase 2: Policy & Decisions (2-3 weeks)
| ID | Task | Dependencies |
|----|------|--------------|
| E1 | Multi-question Laya prompt (intent, target, site, complete, is_command, destructive, scroll, text_span, url_span, tab_direction, is_correction) | B1, E3 |
| E2 | `PolicyEngine` (Swift) with thresholds → ACT/WAIT/IGNORE/CONFIRM/DISAMBIGUATE | E1 |
| E4 | Completion gating (complete + silence thresholds) | E2 |
| E6 | Speculative request cancellation in live mode | E2 |

### Phase 3: Execution Polish (2 weeks)
| ID | Task | Dependencies |
|----|------|--------------|
| B3 | Click by stable ID (from snapshot) | B1, B2 |
| B5 | History via `history.back()` JS (fallback keystroke) | — |
| B7 | Disambiguation UI + local number parsing | B1, E2 |
| B6 | Type into field via JS (search box fallback) | B1, E2 |
| B9 | Destructive heuristic + confirm gate | E2 |
| B10 | Correction handling (reverse / exclude previous target) | E3, E2 |

### Phase 4: Observability & Nice-to-Have (1 week)
| ID | Task | Dependencies |
|----|------|--------------|
| B8 | Search-box detection in snapshot | B1 |
| B4 | Visual highlight/toast (defer) | B3 |
| E7 | Bare number parsing for overlays | B7 |
| E8 | Closed-set intent immunity | E2 |
| E9 | Per-decision latency metrics | E2 |

---

## Key Architectural Shifts

| From (Reflex Today) | To (Target) |
|---------------------|-------------|
| RuleRouter (keywords) → LayaRouter (intent+slots) → DecisionArbiter | **Single Laya call** → **PolicyEngine** (thresholds) → ActionDispatcher |
| Transcript only to Laya | **Transcript + Snapshot + Context** to Laya |
| Laya generates intent+slots | **Laya returns probabilities** for each typed question; Swift decides |
| AppleScript/keystroke execution | **JS execution in Safari** for click/type/scroll/history; keystroke fallback |
| No browser context | **`BrowserContext`** (prev page + last 3 actions) in every decision |
| Single VAD/cooldown | **Per-intent completion gates** (command vs payload silence) |
| No correction logic | **Explicit `is_correction` + reversal/redirect** |

---

## Safari-Specific Notes

- **No Playwright on macOS** — we use `WKWebView`/`JSContext` or AppleScript `do JavaScript` for in-page JS. The snapshot and click/type JS must be self-contained strings.
- **`data-reflex-id` persistence** — Safari doesn't keep custom attributes across navigations. Re-run snapshot on every page load / before every `browser_command`.
- **Element rects** — `getBoundingClientRect()` works in Safari JS. Use for viewport check and `scrollIntoView()`.
- **New tab detection** — After click, poll `window.open` or check `document.title`/`URL` change; Safari JS can't directly detect new tabs, but we can compare tab count via AppleScript if needed.
- **Security** — `do JavaScript` requires "Allow JavaScript from Apple Events" in Safari Develop menu. For distribution, we'll need a Safari Web Extension (later). For now, document the setting.

---

## What We Explicitly DON'T Copy

| jev Feature | Why Not |
|-------------|---------|
| Cloud Jev API | We're local-first; Laya on-device |
| Node server + WebSocket | Native Swift app; no separate process |
| Headed Chromium + Playwright | Safari is the platform browser; Playwright not available on iOS/macOS easily |
| Persistent Chromium profile | Safari profile = user's actual profile |
| CDP attach mode | Safari doesn't support CDP |
| Numbered overlays on page | Requires Safari Web Extension (later); for now, UI-based disambiguation list |
| Real-time cost/token tracking | No API cost locally |

---

## Next Steps

1. **Approve this roadmap** → I'll create GitHub issues / Atlas tasks per phase.
2. **Start Phase 1** — the snapshot JS is the linchpin; everything else builds on it.
3. **Keep Laya prompt engineering separate** — we can iterate prompts without touching Swift.
