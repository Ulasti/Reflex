# ATLAS.md

The single source of truth for this project. Read this file first, before any
action is taken on Reflex.

---

## Purpose

On-device voice command router: transcribes speech with Whisper on the Neural
Engine, decides intent with a Laya router, and performs the action — macOS
first, sharing one SwiftUI UI into an iOS/iPadOS app.

---

## Original Intent

On-device voice command router: transcribes speech with Whisper on the Neural
Engine, decides intent with a Laya router, and performs the action — macOS
first, sharing one SwiftUI UI into an iOS/iPadOS app.

---

## Status
 
| Field | Value |
|---|---|
| Status | `In Progress` |
| Last worked on | 2026-10-19 |
| Branch | `atlas/menubar-ui` |
| needs_review | false — prototype accepted by the user 2026-10-19; remaining polish tracked in Next Steps |
| Where I left off | Menu bar feedback light shipped (2026-10-19, `ec0ef08`): `SignalLight` (off/armed/hearing/executed/waiting/error, 5 priority tests) rendered by `MenuBarIconView` as an explicit 16 pt `NSImage` circle — hollow ring when off, filled in the state color when lit, no pictogram; hearing opacity widened to 0.50–1.0 with a sqrt on the level (both 2026-10-19 second pass). Palette color, `isTemplate = false`, 30 fps opacity motion (4 s breathing, voice-level follow, 300 ms green flash retriggered per action). Notch pill **parked**: `NotchPillController` moved to `atlas/attic/`, `showNotchPill` + its Settings section removed. `MicMonitor` now emits levels per capture chunk so hearing follows the voice at capture cadence. Full gate green: 342 compile actions, 56 tests/14 suites, `--diagnose` 0 blocking, `--laya-ref` 126/126. **Merged into `dev` 2026-10-19** (`--no-ff`, local only, not pushed) — user's call: working prototype that reports the intended status colors; evidence `atlas/evidence/menubar-merge.txt`. Focus now the engine (response time + accuracy, see Next Steps); menu bar polish is parked and still Unverified by eye (screencapture unreliable 2026-10-19; capture verification abandoned by agreement). Evidence: `atlas/evidence/menubar-light.txt`. Earlier: menu bar conversion 2026-10-18 (`atlas/evidence/menubar-ui.txt`); Phase A gate on `atlas/phase-a-verify`. |

---

## Last Failure

No build or test failure. The 2026-10-19 failure was tooling: `screencapture`
returned black frames until the Screen Recording permission was granted, and
pixel-based verification of the menu bar light was then abandoned by user
decision — recorded as **Unverified** in `atlas/evidence/menubar-light.txt`,
never as a pass.

---

## Next Steps

1. **Engine, response time — the active focus.** The menubar prototype is
   merged to `dev` (2026-10-19); polish waits. End-to-end command latency is
   ~1.1–1.6 s today: a 0.7 s VAD endpoint gate, ~1 s in the `floor()`-quantized
   partial throttle in `LiveTranscriber`, then final decode + dispatch. The
   theoretical floor is ~250–400 ms by routing on a stable partial prefix
   instead of endpoint silence. Same pass: `handleSegment` drops segments while
   `processing` and inside the 1.0 s `feedbackCooldown` — replace with a FIFO
   queue so "volume up … resume media … open app" fires continuously — and
   0.2 s gaps merge two commands into one segment.
2. **Engine, accuracy.** Keep `--laya-ref` 126/126 as the regression gate.
   Close A5: the AppModel live path still bypasses the A3/A4 compound router —
   `--dispatch "open safari and then search for cats"` returns one merged
   result while `--compound` splits it into 2 clauses. Last open Phase A item.
3. **Menu bar polish — later, needs an eyeball not a session.** Still
   Unverified by eye: hollow-ring Off, armed breathing, level-following, green
   flash, amber load. Notch pill parked at
   `atlas/attic/NotchPillController.swift` (restore = move back + re-add
   `showNotchPill` + its Settings section). Gesture model (hold-to-talk ~350 ms
   threshold, menubar tap-toggle) still deferred. Pixel-capture verification
   was abandoned 2026-10-19; do not revive it.
4. **Phase A is verified — done (2026-10-16).** `--laya-ref` 126/126,
   `--diagnose` 0 blocking issues, and the A-log phrases behave. The plan's own
   gate passes. Evidence: `evidence/phase-a-verify.txt`.
5. **Then work Phase B in order:** B1 (`ShortcutController`, the biggest "more
   actions" win) → B4 → B5 → B6 → B2 → B3 → B7 → Phase C.
6. **Resolve Blocker #2** (`docs/implementation-plan.md` still names
   `DecisionArbiter.swift` at lines 21 and 60, though arbitration lives in
   `ReflexSystemEngine.swift`). One-line plan fix; do it before A5.
7. **Replace or drop the lost upstream reference** (`docs/jev-voice-action-reference.md`,
   see Blockers). Phase B ports from it, so B1–B7 are unauditable against the
   original until it is restored or the plan is treated as the source.
8. **Decide on the upstream.** If the reference project will not be consumed
   further, re-plan B1–B7 from first principles instead of porting.

---

## Blockers

- **No dedicated test suite (self-imposed), largely addressed.** A
  `ReflexCoreTests` target exists and now runs **56 tests in 14 suites**, all
  passing (`evidence/tests.log`, 2026-10-19). Phase A–B files outside that net
  (the AppModel live path, the dispatcher side effects) remain the main project
  risk. See D1.
- **`atlas/docs/implementation-plan.md` still refers to `DecisionArbiter.swift`**
  at lines 21 and 60, but the arbitration logic lives in
  `ReflexSystemEngine.swift`. Verified 2026-10-16. One-line doc fix; resolve
  before A5.
- **The upstream reference doc is lost.**
  `atlas/docs/jev-voice-action-reference.md` is claimed by Inputs, Links,
  D6 and the self-containment table, but **does not exist** — not in the tree,
  not in any git commit, and the Desktop originals are gone
  (`evidence/integrity-audit-2026-10-02.txt` records them as gone). Phase A and
  B port from it, so B1–B7 cannot be audited against the source until it is
  restored. Resolves by: the user supplying a copy, or accepting
  `docs/implementation-plan.md` as the source of record. See D30.
- **Laya checkpoint pinning.** `reflex-questions.json` and the tokenizer in
  `Resources/` were exported against one specific `convaiinnovations/laya`
  build. Adding a new ML action kind needs a re-export or retrain; rules-first
  is the only fast path. See **Decisions**.

---

## Inputs & Locations

Everything load-bearing lives inside the project. Nothing points outside it.
The single source of truth for "where the models are" is
`ReflexWhisperKit.defaultModelsDirectory` in
`ReflexCore/Sources/ReflexCore/LiveTranscriber.swift`. The app
(`ReflexEnvironment.modelDirectory()`) and the CLI (`defaultModelsDirectory()`)
both delegate to it. Do not add a second resolver. See Doctor D17.

| Input | Location | Committed |
|---|---|---|
| App sources | `Reflex/` | yes |
| Core logic + CLI | `ReflexCore/Sources/` | yes |
| XcodeGen spec (source of truth for the project) | `project.yml` | yes |
| Generated Xcode project | `Reflex.xcodeproj/` | yes (regenerate with `xcodegen generate`) |
| Tokenizer, config, mel coefficients | `ReflexCore/Sources/ReflexCore/Resources/` | yes |
| Implementation plan | `docs/implementation-plan.md` | yes |
| Upstream voice-action reference | `docs/jev-voice-action-reference.md` | **MISSING** — claimed here but absent from the tree and from git history (see Blockers, D30) |
| CoreML models (4.8 GB) | `Models/` | **no** — see `Models/MANIFEST.md` |
| HF download cache | `.cache/huggingface/` | no — regenerable |
| Python toolchain venv (767 MB) | `tools/.venv/` | no — see `tools/requirements.txt` |
| SPM dependency pin | `ReflexCore/Package.resolved`, `Reflex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | yes |

**Environment variables**

| Variable | Effect | Default |
|---|---|---|
| `REFLEX_MODELS` | Overrides the models directory for both app and tools. | in-project `Models/` |
| `HF_HOME` | Hugging Face cache. Pinned in-project by `tools/project_env.py`. | `<repo>/.cache/huggingface` |

**External, cannot be relocated** — system Xcode 27 / Swift 6.4; XcodeGen
(`brew install xcodegen`); the WhisperKit SPM dependency; and the HF model
checkpoints (`openai/whisper`, `convaiinnovations/laya`,
`argmaxinc/whisperkit-coreml`) fetched only at conversion time.

`~/Library/Application Support/Reflex/session-logs.json` is runtime *output*
written by `SessionLog.swift` to the OS-standard location. It is not an input
and is intentionally not relocated.

---

## How to Run / Test

```bash
# Everything: macOS app, iOS app, SPM CLI, then verify all model bundles.
./files/build-and-verify.sh

# Individual steps
xcodegen generate                                    # project.yml -> .xcodeproj
open Reflex.xcodeproj                               # run the Reflex-macOS scheme

xcodebuild -project Reflex.xcodeproj -scheme Reflex-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/reflex-dd build

xcodebuild -project Reflex.xcodeproj -scheme Reflex-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/reflex-dd-ios \
  build CODE_SIGNING_ALLOWED=NO

swift build --package-path ReflexCore -c release
./ReflexCore/.build/out/Products/Release/reflex-cli --help
./ReflexCore/.build/out/Products/Release/reflex-cli --verify   # exits 1 if models are missing

# Model conversion (see Models/MANIFEST.md for the full matrix)
cd tools && python3.10 -m venv .venv && .venv/bin/pip install -r requirements.txt
./.venv/bin/python convert.py whisper --variant large-v3-turbo --quantize int8
./.venv/bin/python download_whisperkit_models.py small
```

**There is no lint step.** The gates that exist:

| Gate | What it proves |
|---|---|
| `./files/build-and-verify.sh` | All three artifacts build and every `.mlpackage` compiles. Fails on a missing model. |
| `reflex-cli --verify` | Every CoreML bundle compiles. Exits 1 if none are found. |
| `reflex-cli --diagnose` | Mic, Accessibility, browsers, and that the Whisper model resolves. **Must report 0 blocking issues.** Any change to a path resolver must leave this clean. |
| `reflex-cli --laya-ref tools/laya_reference.json` | Router accuracy. Currently 126/126. This is the plan's own gate and the closest thing to a regression suite. |

---

## Steps

The loop for a change to Reflex.

1. Read `ATLAS.md`. Confirm the branch is `atlas/<feature>`, created from `dev`.
2. `atlas/files/build-and-verify.sh` if you touched `atlas/project.yml`,
   `Reflex/`, or `ReflexCore/` — the `.xcodeproj` is
   generated from the spec, so never hand-edit it.
3. That script builds both app targets, the CLI and the test suite.
4. It runs `ReflexCore/.build/out/Products/Release/reflex-cli --verify`.
5. Exercise the change headlessly through the CLI before touching the UI.
   `--help` lists the verbs; `--diagnose` reports permissions and environment.
   Require **0 blocking issues** from `--diagnose` and **126/126** from
   `--laya-ref` before you call anything done.
6. Run the Definition of Done below. Every check needs a real evidence file.
7. Commit on `atlas/<feature>` with a structured message, set `needs_review`,
   and hand off for merge into `dev`.

---

## Decisions

- **If a new action kind needs ML support, then retrain or re-export Laya.**
  Otherwise add it rules-first in `RuleRouter` at confidence ≥0.9, which beats a
  weak Laya call in `DecisionArbiter`.
- **If dispatch confidence is below the floor, then do nothing.** Return
  `.noOp` rather than guessing. Guessing produced the `"50 times 20"`
  misfires.
- **If a model path is needed, then derive it from the repo, never `$HOME`.**
  Swift uses `#filePath`, Python uses `__file__`. An absolute home-relative
  path breaks the moment the project moves, which it just did — twice.
- **If a path is needed in more than one place, then there is exactly one
  resolver and everything else calls it.** Three hand-rolled copies of the
  models lookup is what let a stale `~/Development/Reflex` survive the move
  while two of the three looked correct. See Doctor D17.
- **If an audit greps for a path, then grep for the API, not the string.**
  `appendingPathComponent("Development/Reflex/Models")` never appears as
  `/Users/...`, so a literal-path grep passes clean over it. Search for
  `homeDirectoryForCurrentUser`, `NSHomeDirectory()`, `Path.home()`,
  `getpwuid`, `expanduser` — then read each hit.
- **If an asset is over ~50 MB, then keep it local and gitignored with a
  committed manifest.** `Models/MANIFEST.md`. Never commit weights unasked.
- **If a check cannot be verified, then record it as unverifiable.** Never
  report an assumed pass.
- **If a verification command can silently pass, then that is a bug.** Fix it
  before trusting it — this is why `--verify` now exits non-zero.

---

## Rule Ledger

| Rule | Born from (incident or evidence path) | Scope (project/global) | Status (unproven/proven) |
|---|---|---|---|
| Never grep for `/Users/` to prove self-containment; grep the home-directory APIs, then read every hit. | `atlas/evidence/integrity-audit-2026-10-02.txt`; Doctor D17 | project | proven |
| One resolver per asset; every caller delegates to it. | Doctor D4, D17 | project | proven |
| A verification command that can silently pass is a bug: make it exit non-zero and prove the failure. | Doctor D3, D18, D23 | project | proven |
| Keep any asset over ~50 MB local and gitignored, with a committed manifest. | Doctor D5 | project | proven |
| Record an unverifiable check as `Unverified`, never as Pass. | Doctor D22; Decisions | project | proven |
| Re-derive inherited results; a prior green DoD is a claim, not evidence. | Doctor D19, D23 | project | proven |
| Never hand-edit `Reflex.xcodeproj`; edit `project.yml` then run `xcodegen generate`. | Agent Instructions | project | proven |
| Keep framework-native files at the project root; only Atlas-owned files (`ATLAS.md`, `evidence/`, `docs/`, `files/`) live in `atlas/`. | Doctor D27 | project | proven |

---

## Definition of Done

Every check is run and evidenced. Pass/Fail reflects what actually ran.

| # | Check | Evidence | Result |
|---|---|---|---|
| 1 | macOS target builds | `evidence/build-macos.log` — `** BUILD SUCCEEDED **`, 342 compile actions | **Pass** (re-run 2026-10-19; falsifier: a log with 0 compile actions fails the script's `require_compile_actions`) |
| 2 | iOS/iPadOS target builds | `evidence/build-ios.log` — `** BUILD SUCCEEDED **` | **Pass** (re-run 2026-10-19) |
| 3 | SPM package and `reflex-cli` build in release | `evidence/build-cli.log` — release build, `Build complete!` | **Pass** (re-run from a fresh `.build` on 2026-10-19; 0 stale-path warnings) |
| 4 | Every CoreML bundle compiles via `reflex-cli --verify` | `evidence/verify-models.log` — `verify OK`, exit 0 | **Pass** (re-run 2026-10-19) |
| 5 | `--verify` genuinely fails when models are absent | `evidence/verify-models-negative.txt` — empty dir → exit 1, `No model packages found` | **Pass** (falsifier shown: the negative control fails as required) |
| 6 | Automated unit tests pass | `evidence/tests.log` — `Test run with 56 tests in 14 suites passed` | **Pass** (re-run 2026-10-19; the figure moved from 4 to 56 as coverage grew) |
| 7 | No load-bearing asset lives outside the project | `evidence/self-containment.txt`, `evidence/integrity-audit-2026-10-02.txt` | **Pass (2026-10-02, not re-derived 2026-10-16).** This change touches no path resolver. Falsifier: a home-directory API hit resolving a model path. |
| 8 | Gitignored heavy assets disclosed with committed placeholders | `Models/MANIFEST.md` (tracked); `Models/` gitignored via `Models/*` | **Pass.** Verified this session: `Models/` (4.8 GB) is gitignored, `Models/MANIFEST.md` is the only tracked file there and carries sizes + re-acquire commands. Note: `.gitignore` also force-includes `Models/.gitkeep`, which does not exist — dead rule (MANIFEST.md already guarantees the directory on clone). Noted under D5. |
| 9 | No secrets or credentials committed | `evidence/security-scan.txt` | **Pass** (created 2026-10-16; 0 secret hits, negative control 3 hits proves the scan can fail). Falsifier: any private-key/token/password pattern. |
| 10 | Referenced paths and artifacts all resolve | `evidence/artifacts-check.txt` | **Fail** — 23 paths checked, 1 missing (`atlas/docs/jev-voice-action-reference.md`). Falsifier met; recorded as D30. |
| 11 | ATLAS.md status, branch, next steps current | `evidence/atlas-status.txt` | **Pass** (updated 2026-10-16) |
| 12 | Changes committed with a structured message | `evidence/commit.txt` | **Pass** (see commit.txt) |
| 13 | Pushed to the correct branch | `evidence/git-push.txt`, `evidence/menubar-merge.txt` | **Not pushed.** Merged into `dev` locally 2026-10-19 at the user's request (prototype accepted); the branch strategy still pushes `atlas/<feature>` only after a full DoD pass, and row 10 fails. |

---

## Edge Cases

- **Models missing.** The app builds and launches but every model call fails
  with a pointed diagnostic rather than a crash. `reflex-cli --verify` exits 1
  and names exactly which bundles are absent.
- **A different Laya checkpoint.** `reflex-questions.json` and the tokenizer
  were exported against one specific build. A different checkpoint loads
  without error but transcribes wrong. Verify against the SHA-256 tree hashes
  in `Models/MANIFEST.md`.
- **Models missing or a resolver regressed.** Two different symptoms.
  `--verify` failing with "No model packages found" means the models really
  are absent. `--diagnose` reporting "Whisper model not found" while
  `--verify` passes means a *resolver* is looking in the wrong place — that is
  what D17 was, and it is the more deceptive of the two because the app still
  transcribes fine. Check the path in the message before touching the models.
- **macOS is sandbox-free.** `ENABLE_APP_SANDBOX: NO`, because it drives other
  apps via AppleScript and Accessibility. Shipping outside the developer's own
  machine requires revisiting that.
- **Microphone and Accessibility are runtime permissions**, not build settings.
  `--diagnose` reports them; the app cannot preflight them at build time.
- **The `.xcodeproj` is generated.** Hand edits are silently lost on the next
  `xcodegen generate`. Edit `project.yml`.
- **Two `Package.resolved` files exist** (SPM package and the Xcode workspace).
  They can drift. If a dependency resolves differently between the CLI and the
  app, diff them.
- **`git` tracks both `project.yml` and the generated `.xcodeproj`.** Regenerating
  produces a diff every time. This is intentional, but expect noise.

---

## Toolbox

| File | When to use | When not to use |
|---|---|---|
| `files/build-and-verify.sh` | Any change to `Reflex/`, `ReflexCore/`, `project.yml`, or `Models/`. One command builds both app targets and the CLI, then verifies all model bundles. Writes logs into `evidence/`. | To rebuild models — that is `tools/convert.py`. Not needed for doc-only changes. |
| `files/reflex.icon` | Redundant: byte-identical to `Reflex/reflex.icon`, which is the copy the build uses. Listed for completeness. | For any build or asset purpose — use `Reflex/reflex.icon`. Pending removal (D32). |

---

## Links

- `docs/implementation-plan.md` — the Phase A/B/C plan. The primary driver of
  Next Steps. **Read before starting any feature work.**
- `docs/jev-voice-action-reference.md` — the upstream action/workflow reference
  that Phase A and B port from. **Currently MISSING** (see Blockers, D30): the
  path is referenced but no such file exists. Restore it or treat the plan as
  the source of record.
- `docs/audit-2026-10-14.md` — the last Atlas audit, source of the "N5" clean-build rule.
- `docs/BROWSER_ROADMAP.md` — browser-command roadmap (Phase B input).
- `Models/MANIFEST.md` — model inventory, SHA-256 tree hashes, re-acquire
  commands, verification one-liner.
- `README.md` — human-facing overview and quick start.

---


## Atlas Doctor

Health of the Atlas integration itself. Checked 2026-10-16.

| # | Issue | Severity | Status | Suggested Fix | Last Checked |
|---|---|---|---|---|---|
| D1 | No test target anywhere in the project, so every Phase A–B file is unverified. | error | mostly addressed | `ReflexCoreTests` exists and runs **51 tests in 13 suites**, all passing (2026-10-16). Still uncovered: the AppModel live path and dispatcher side effects. Next: cover the A3 floor, the A4 compound split, and the `--laya-ref` 126/126 gate as tests. | 2026-10-16 |
| D2 | No git remote configured. | error | fixed | Remote now exists: `origin` = `git@github.com:Ulasti/Reflex.git`; `atlas/phase-a-wiring` tracks `origin/atlas/phase-a-wiring`. The push step is now verifiable. (Re-checked 2026-10-16.) | 2026-10-16 |
| D3 | `--verify` previously reported success with zero models present, because it silently skipped missing packages and always exited 0. | error | fixed | Rewrote `verifyCompilation()` to throw when nothing is found and to list what is missing; `--verify` now exits 1. Proven with a negative run against an empty directory. | 2026-10-02 |
| D4 | Six load-bearing absolute paths pointed at `~/Development/Reflex`, which no longer exists after relocation. | error | fixed | All rewritten to derive from the repo via `#filePath` / `__file__`. `Models/manifest.json` rebuilt with relative paths. | 2026-10-02 |
| D17 | A **seventh** path was missed: `LiveTranscriber.swift` still resolved models from `~/Development/Reflex/Models`, so `--diagnose` and the app's Diagnostics button reported a false "Whisper model not found". The original self-containment audit asserted "ALL rewritten" and reported zero, because it grepped for literal `/Users/` and this path is assembled from `appendingPathComponent`. | error | fixed | `ReflexWhisperKit.defaultModelsDirectory` now derives from `#filePath`. `ReflexEnvironment.modelDirectory()` and the CLI's `defaultModelsDirectory()` both delegate to it, so one resolver, not three. Proven: `--diagnose` → 0 blocking issues. Re-audited with an escape-hatch pattern that catches assembled paths. | 2026-10-02 |
| D18 | `files/build-and-verify.sh` model gate was dead code: `${PIPESTATUS[0]}` was redirected to `/dev/null` and swallowed with `\|\| true`. It only worked because `pipefail` aborted first. | warn | fixed | Replaced with an explicit `if ! ... \| tee` exit-status check plus an independent `grep -q "verify OK"` condition, so a silent pass fails the script. Same failure mode as D3. | 2026-10-02 |
| D19 | The 2026-10-02 evidence contained no clean-build proof: `build-macos.log` and `build-ios.log` were re-runs of an already-built tree (0 compile actions, 0 warnings). "BUILD SUCCEEDED" proved the tree still linked, not that current sources compile from scratch. | warn | fixed | `files/build-and-verify.sh` re-run from a cleared derived-data path on this branch. See `evidence/build-clean.log`. | 2026-10-02 |
| D5 | `Models/` (4.8 GB) was gitignored with no committed placeholder, violating the clone rule. | error | fixed | Added `Models/MANIFEST.md` with sizes, SHA-256 tree hashes, source URLs, re-acquire commands, and a verify one-liner. Fixed `.gitignore` to exclude `Models/*` rather than `Models/` so the negation actually takes effect. **2026-10-16: the row's `.gitkeep` claim is unmet — no such file exists; the `.gitignore` negation for it is a dead rule. MANIFEST.md already keeps the directory on clone, so the file is unnecessary. Corrected.** | 2026-10-16 |
| D6 | Planning context lived on the Desktop, outside the project. | error | fixed | `Reflex_Implementation_Plan.md` and `Jev_Voice_Action_Reference.md` moved to `docs/`, SHA-256 verified byte-identical before and after. **Superseded 2026-10-16: the reference doc is now missing entirely — see D30.** | 2026-10-16 |
| D7 | HF cache lived at `~/Documents/huggingface`, outside the project. | warn | fixed | Moved to `.cache/huggingface` and the download path itself was relocated via `tools/project_env.py`, which pins `HF_HOME`/`HF_XET_CACHE` in-project. Relocating the cache is preferred over moving weights. | 2026-10-02 |
| D8 | No README. | warn | fixed | Added `README.md` with layout, build steps, and the models caveat. | 2026-10-02 |
| D9 | Branch strategy was not implemented: only `main` existed, with no `dev`. | warn | fixed | Created `dev` and `atlas/integrate-reflex` from the Phase 1 commit. `main` untouched. | 2026-10-02 |
| D10 | All Phase 2 work was uncommitted — 51 paths, including the whole of `ReflexCore`. | warn | fixed | Committed on `atlas/integrate-reflex` with evidence. | 2026-10-02 |
| D11 | The plan references `DecisionArbiter.swift`; arbitration actually lives in `ReflexSystemEngine.swift`. | warn | fixed | Implemented confidence floor + addressed gate in `ReflexSystemEngine.swift` (A3). Plan drift corrected; no new DecisionArbiter.swift. | 2026-10-09 |
| D12 | Most other CLI verbs print errors but still exit 0, so they cannot gate a script. Only `--verify` was fixed. | warn | open | Make CLI failures exit non-zero across all verbs. Deliberately out of scope for this integration to avoid a risky sweeping refactor. | 2026-10-02 |
| D13 | A stale copy of the project sat in the Trash at `~/.Trash/Reflex-acjiwxacscamoxemtqezorowawnl/` (~800 MB incl. build output). | info | fixed | The Trash has since been emptied; the path no longer exists. Verified 2026-10-02. | 2026-10-02 |
| D14 | No `tests/` or `src/` directory. Atlas's canonical structure expects both. | info | open | Resolved by creating a real test target rather than empty directories — tracked as D1. `src/` will never exist here: this is a Swift/XcodeGen project whose sources live in `Reflex/` and `ReflexCore/Sources/`. Recorded so the next agent does not re-raise it. | 2026-10-02 |
| D15 | `tools/__pycache__` and `.DS_Store` are gitignored but were present in the working tree before integration. | info | fixed | Already covered by the existing `.gitignore` rules; confirmed no stray artifacts are staged. | 2026-10-02 |
| D16 | `~/.config/opencode/commands/atlas.md` hardcodes `/Users/emir/.config/opencode/skills/atlas/SKILL.md`, which the Atlas spec forbids in a wrapper. | info | ignored | **Accepted by the user, deliberately.** The hardcoded path is how OpenCode resolves this skill without matching another one. `<workspace>/SKILL.md` remains the pristine source of truth for cloning and for any other host; the OpenCode copy is a host-local install and is intentionally not byte-identical. Re-check only if `/atlas` stops resolving the skill. | 2026-10-02 |
| D20 | Skill copy drift: `~/.config/opencode/skills/atlas/SKILL.md` differed from `<workspace>/SKILL.md`. | warn | fixed | Re-installed during the v2 workspace upgrade; after the user's manual SKILL 2.1.0 update the two files are byte-identical (sha256 `0fae35d6…`). Verified by `diff` 2026-10-16. | 2026-10-16 |
| D21 | **Self-containment evidence corrupted:** an automated script (`atlas-self-containment-audit.sh`) overwrote `evidence/self-containment.txt` with false positives. It grepped for APIs but did **not classify by reading** — it counted 5 hits as "violations" including intentional code (`expanduser` on user arg), documentation lines in ATLAS.md, and the two intentional `NSHomeDirectory()` calls. The script violated "Classify, do not count" and "Search the API, not the string" (then read every hit). Restored from git. | error | fixed | Remove or fix the script so it classifies each hit by reading it, and asserts a number with classification. Script currently produces unfalsifiable "violations" that require manual re-audit to debunk. Evidence restored to the correct re-verified audit. | 2026-10-03 |
| D22 | **`--laya-ref` 126/126 claim had no evidence file.** Asserted in Status and How to Run/Test, but no `evidence/laya-ref.txt` existed. Per "inherited results are not results" and "re-derive inherited results," this was an inherited claim, not evidence. | warn | fixed | Ran `reflex-cli --laya-ref tools/laya_reference.json` → 126/126. **On 2026-10-16 the file was found missing again** (never committed; absent from every branch) — the earlier "saved to evidence/laya-ref.txt" claim could not be substantiated. Regenerated and committed this session: `evidence/laya-ref.txt`, `126/126 checks passed`. | 2026-10-16 |
| D23 | **DoD row 3 evidence degraded:** `evidence/build-cli.log` was 77 bytes, 0 compile actions, an incremental no-op. `build-clean.log` covers only macOS/iOS, not the SPM CLI release build. Binary existed (4.1 MB, mtime 22:08) and 0 sources were newer, so a release build did happen — but its log was overwritten. D19 failure mode recurred for the CLI. | warn | fixed | Cleared `ReflexCore/.build/out` and re-ran `swift build --package-path ReflexCore -c release` (32.83 s, 183 tasks planned). Log now shows real build work; `reflex-cli --verify` → `verify OK`. Evidence: `evidence/build-cli.log`. | 2026-10-03 |
| D24 | ATLAS.md lacked the v2 sections **Original Intent**, **Last Failure** and **Rule Ledger**. | info | fixed | Added all three. Original Intent frozen from the user's own Purpose line after explicit confirmation (2026-10-16). Evidence: `evidence/atlas-upgrade.txt`. | 2026-10-16 |
| D25 | Next Steps and Blockers named branches that do not exist (`atlas/integrate-reflex`, `atlas/fix-model-path-resolver`); D2 also claimed there was no remote. | warn | fixed | Next Steps rewritten around the real state: `dev` is at `a74e26b` and `atlas/phase-a-wiring` is 12 commits ahead. D2 marked fixed. Evidence: `evidence/atlas-upgrade.txt`. | 2026-10-16 |
| D26 | `## Definition of Done` header was empty and the DoD table sat orphaned under `## Decisions`. | warn | fixed | DoD table moved back under its own header; Rule Ledger inserted after Decisions per the v2 template. | 2026-10-16 |
| D27 | **Source wrapper split the repo from its own path assumptions.** A prior restructure moved the sources under `reflex-source/`, but `tools/project_env.py` (`MODELS_DIR`, `RESOURCES_DIR`) and `LiveTranscriber.swift` (`#filePath`) both derive the repo root assuming `Reflex/`, `ReflexCore/` and `Models/` sit at the root — so `REFLEX_MODELS` and the Python `MODELS_DIR` pointed at a non-existent `<root>/Models`, and `tools/convert.py`/`download_whisperkit_models.py` would write weights where the app does not read. `project.yml` was also inside `atlas/`, contradicting Atlas 2.1.0 (only Atlas-owned files belong in `atlas/`). | warn | fixed | Unwrapped back to the original root layout: `git mv reflex-source/{Reflex,ReflexCore,Models}` → repo root, `git mv atlas/project.yml` → root. Updated every path reference (`project.yml`, `atlas/files/build-and-verify.sh`, this file) and the `.gitignore` comment. Nothing deleted: the emptied wrapper and the orphan root `ReflexCore/Package.resolved` (which differed from the real one) were moved to a backup. The Swift and Python resolvers now reach the true repo root with no code change. Evidence: `evidence/atlas-layout-restructure.txt` and the refreshed build logs. | 2026-10-16 |
| D28 | `Models/manifest.json` (gitignored, written by `tools/convert.py`, read by nothing) still holds absolute `/Users/emir/…` paths and a `whisper-large-v3-turbo` key that no longer exists (the variants live under `Models/whisperkit/`). | info | open | Regenerate it from `tools/convert.py` so it uses `project_env.relative_to_repo` relative paths (D4), or drop the file. Harmless today because nothing reads it and it is not committed. | 2026-10-16 |
| D29 | After moving `ReflexCore/`, `ReflexCore/.build/out` held absolute paths from the old `reflex-source/ReflexCore/.build/…`, so `swift test` / `swift build` emitted ~530 "Stale file … is located outside of the allowed root paths" warnings (visible in `evidence/tests.log`, `evidence/build-cli.log`). | info | fixed | Cleared `ReflexCore/.build` (745 MB) and re-ran `atlas/files/build-and-verify.sh`: logs now contain 0 stale-path warnings, both app targets build (320 compile actions), 51 tests in 13 suites pass, release CLI Build complete, `reflex-cli --verify` OK. | 2026-10-16 |
| D30 | **Referenced upstream doc does not exist.** `docs/jev-voice-action-reference.md` is claimed by Inputs & Locations, Links, D6 and the self-containment table, but is absent from the tree and from git history; the Desktop originals are recorded gone. DoD row 10 therefore fails (1 of 23 referenced paths missing). | error | open | Restore the doc (user has a copy) or treat `docs/implementation-plan.md` as the source of record and drop the claims. Blocks Phase B auditability; recorded in Blockers. | 2026-10-16 |
| D31 | **DoD rows marked Pass cited evidence files that did not exist.** Rows 9, 10 and 12 named `evidence/security-scan.txt`, `evidence/artifacts-check.txt`, `evidence/commit.txt`; none were present. A Pass with no evidence file is unverifiable. | warn | fixed | Re-derived this session: `security-scan.txt` (0 secret hits, negative control 3 hits), `artifacts-check.txt` (23 checked, 1 missing → row 10 now correctly Fail), `commit.txt` written at commit. Rows re-stated with honest results. | 2026-10-16 |
| D32 | **`files/INDEX.md` out of sync, and a duplicated asset.** `reflex.icon` sits in `atlas/files/` byte-identical to `Reflex/reflex.icon`, which is the copy the build uses (xcodegen picks it up from `Reflex/`); the toolbox copy is unused. The INDEX row was missing entirely. | warn | open | Added the INDEX row. The `atlas/files/reflex.icon` copy is redundant: confirm removal (not performed without consent). | 2026-10-16 |

---
## Agent Instructions

**Read this file first. Update Status, Next Steps, Blockers, and evidence before
ending your session. Enforce the DoD and branch strategy. Do not assume any
context.**

- Never work on `main`. Branch `atlas/<feature>` (kebab-case) from `dev`,
  commit there with `type(scope): description - evidence: <path>`, and hand off
  for review. `main` only ever receives merges from `dev`.
- Never hand-edit `Reflex.xcodeproj`. Edit `project.yml`, then run
  `xcodegen generate`.
- Never derive a path from `$HOME` in Swift or Python. Use `#filePath` /
  `__file__` and `tools/project_env.py`.
- Never commit anything in `Models/`, `tools/.venv/`, `.cache/`, or
  `.build/`. Update `Models/MANIFEST.md` if the model set changes.
- Do not add a new ML action kind without confirming the Laya re-export, or
  the tokenizer and `reflex-questions.json` will silently disagree with the
  checkpoint.
- Run `./files/build-and-verify.sh` before claiming any change works. Then run
  `reflex-cli --diagnose` (must be 0 blocking issues) and
  `reflex-cli --laya-ref tools/laya_reference.json` (must be 126/126). If a
  check cannot be run, say so and record it as unverifiable — never report an
  assumed pass.
- **Never add a second model-path resolver.** `ReflexWhisperKit.defaultModelsDirectory`
  is the only one. Call it. If you think you need another, you do not.
- **Never grep for `/Users/` to prove self-containment.** That check has a
  demonstrated false negative (D17). Grep for the home-directory APIs instead.
- Update the Atlas Doctor table above whenever you detect or resolve an issue.
