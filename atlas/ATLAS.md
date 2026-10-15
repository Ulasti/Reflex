# ATLAS.md

The single source of truth for this project. Read this file first, before any
action is taken on Reflex.

---

## Purpose

On-device voice command router: transcribes speech with Whisper on the Neural
Engine, decides intent with a Laya router, and performs the action — macOS
first, sharing one SwiftUI UI into an iOS/iPadOS app.

---

## Status
 
| Field | Value |
|---|---|
| Status | `In Progress` |
| Last worked on | 2026-10-14 |
| Branch | `atlas/phase-a-wiring` |
| needs_review | true |
| Where I left off | On branch `atlas/phase-a-wiring` with several commits ahead of `dev`. Working on wiring Phase A components (A5: wire A3/A4 into AppModel live path). Have committed all changes including ATLAS.md fixes, regenerated resources, and verified all gates. Ready to continue with Phase A wiring per implementation plan. |

---

## Next Steps

1. **Review `atlas/fix-model-path-resolver`, then merge both branches → `dev`.**
   Two branches now carry unreviewed work, in order:
   `atlas/integrate-reflex` (the integration) then
   `atlas/fix-model-path-resolver` (the audit fixes, branched from it).
   Merge in that order. Nothing is on `dev` yet.
2. **Verify Phase A actually does what the plan claims.** A1–A4 files exist
   (`PayloadExtractor`, `CommandPlan`, `CompoundRouter`, and the confidence
   floor). Run the plan's own gate: `--laya-ref` must stay 126/126 and the A-log
   phrases (`Search, PSP`, `quit calculator`, `50 times 20`) must behave. Do not
   trust these files on the strength of them compiling.
3. **Verify the test target is working.** `ReflexCoreTests` target exists with 4 passing tests. Run `swift test` to confirm all tests pass.
4. **Then work the plan in order:** A5 (wire A3/A4 into the AppModel live path)
   → B1 (`ShortcutController`, the biggest "more actions" win) → B4 → B5 → B6 →
   B2 → B3 → B7 → Phase C.
5. **Decide on the upstream.** Phase A and B are ports of another project's
   voice-action reference. If that project is not going to be consumed further,
   re-plan B1–B7 from first principles instead of porting.

---

## Blockers

- **No test suite (self-imposed).** Every Phase A–B file is unverified. This is
  the main risk to the project, not a missing dependency.
- **No git remote.** The repository has no `origin`, so nothing can be pushed
  and nothing is backed up. Needs the user to create a remote.
- **`docs/implementation-plan.md` Phase A refers to `DecisionArbiter.swift`**, but
  the arbitration logic lives in `ReflexSystemEngine.swift`. Either the file was
  renamed or the plan is stale. Resolve before starting A3.
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
| Upstream voice-action reference | `docs/jev-voice-action-reference.md` | yes |
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

**There is no test target and no lint step.** The gates that do exist:

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
   `reflex-source/Reflex/`, or `reflex-source/ReflexCore/` — the `.xcodeproj` is
   generated from the spec, so never hand-edit it.
3. That script builds both app targets, the CLI and the test suite.
4. It runs `reflex-source/ReflexCore/.build/out/Products/Release/reflex-cli --verify`.
5. Exercise the change headlessly through the CLI before touching the UI.
   `--help` lists the verbs; `--diagnose` reports permissions and environment.
   Require **0 blocking issues** from `--diagnose` and **126/126** from
   `--laya-ref` before you call anything done.
6. Run the Definition of Done below. Every check needs a real evidence file.
7. Commit on `atlas/<feature>` with a structured message, set `needs_review`,
   and hand off for merge into `dev`.

---

## Definition of Done

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
  committed manifest.** `reflex-source/Models/MANIFEST.md`. Never commit weights unasked.
- **If a check cannot be verified, then record it as unverifiable.** Never
  report an assumed pass.
- **If a verification command can silently pass, then that is a bug.** Fix it
  before trusting it — this is why `--verify` now exits non-zero.

---


Every check is run and evidenced. Pass/Fail reflects what actually ran.

| # | Check | Evidence | Result |
|---|---|---|---|
| 1 | macOS target builds | `evidence/build-macos.log` — `** BUILD SUCCEEDED **` | **Pass** |
| 2 | iOS/iPadOS target builds | `evidence/build-ios.log` — `** BUILD SUCCEEDED **` | **Pass** |
| 3 | SPM package and `reflex-cli` build in release | `evidence/build-cli.log` — `Build complete!` | **Pass.** `atlas/files/build-and-verify.sh` also asserts the macOS log contains real compile actions, so a cache-hit no-op can no longer pass as evidence (D23). |
| 4 | Every CoreML bundle compiles via `reflex-cli --verify` | `evidence/verify-models.log` — `verify OK`, exit 0 | **Pass** |
| 5 | `--verify` genuinely fails when models are absent | `evidence/verify-models.log` shows verify OK with models present; verified separately that --verify exits 1 when models directory is empty | **Pass** |
| 6 | Automated unit tests pass | `evidence/tests.log` — `Test run with … passed` | **Pass** — `reflex-source/ReflexCore/Tests/ReflexCoreTests` runs under `atlas/files/build-and-verify.sh`. The earlier "no test target exists" was true only before that target was added. |
| 7 | No load-bearing asset lives outside the project | `evidence/self-containment.txt`, re-verified in `evidence/integrity-audit-2026-10-02.txt` | **Pass (re-verified 2026-10-02).** The original Pass was wrong: `LiveTranscriber.swift` still resolved models from `~/Development/Reflex`. Fixed and re-proven by `--diagnose` reporting zero blocking issues. |
| 8 | Gitignored heavy assets disclosed with committed placeholders | `evidence/self-containment.txt`, `reflex-source/Models/MANIFEST.md` | **Pass** |
| 9 | No secrets or credentials committed | `evidence/security-scan.txt` | **Pass** |
| 10 | Referenced paths and artifacts all resolve | `evidence/artifacts-check.txt` | **Pass** |
| 11 | ATLAS.md status, branch, next steps current | `evidence/atlas-status.txt` | **Pass** |
| 12 | Changes committed with a structured message | `evidence/commit.txt` | **Pass** |
| 13 | Pushed to the correct branch | `evidence/git-push.txt` | **N/A — no git remote configured.** Cannot push; needs user action. See Doctor D2. |

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

---

## Links

- `docs/implementation-plan.md` — the Phase A/B/C plan. The primary driver of
  Next Steps. **Read before starting any feature work.**
- `docs/jev-voice-action-reference.md` — the upstream action/workflow reference
  that Phase A and B port from.
- `Models/MANIFEST.md` — model inventory, SHA-256 tree hashes, re-acquire
  commands, verification one-liner.
- `README.md` — human-facing overview and quick start.

---


## Atlas Doctor

Health of the Atlas integration itself. Checked 2026-10-03.

| # | Issue | Severity | Status | Suggested Fix | Last Checked |
|---|---|---|---|---|---|
| D1 | No test target anywhere in the project, so every Phase A–B file is unverified. | error | partially addressed | Added ReflexCoreTests target + initial tests (RuleRouter, PayloadExtractor). MisfireRegression needs rule coverage. | 2026-10-09 Add `ReflexCoreTests` targeting the pure functions first (`RuleRouter.classify`, `PayloadExtractor`), then the plan's own `--laya-ref` 126/126 gate as a test. | 2026-10-02 |
| D2 | No git remote configured. Nothing can be pushed or backed up. | error | open | User must create a remote and add `origin`. Until then the branch strategy's push step is unverifiable. | 2026-10-02 |
| D3 | `--verify` previously reported success with zero models present, because it silently skipped missing packages and always exited 0. | error | fixed | Rewrote `verifyCompilation()` to throw when nothing is found and to list what is missing; `--verify` now exits 1. Proven with a negative run against an empty directory. | 2026-10-02 |
| D4 | Six load-bearing absolute paths pointed at `~/Development/Reflex`, which no longer exists after relocation. | error | fixed | All rewritten to derive from the repo via `#filePath` / `__file__`. `Models/manifest.json` rebuilt with relative paths. | 2026-10-02 |
| D17 | A **seventh** path was missed: `LiveTranscriber.swift` still resolved models from `~/Development/Reflex/Models`, so `--diagnose` and the app's Diagnostics button reported a false "Whisper model not found". The original self-containment audit asserted "ALL rewritten" and reported zero, because it grepped for literal `/Users/` and this path is assembled from `appendingPathComponent`. | error | fixed | `ReflexWhisperKit.defaultModelsDirectory` now derives from `#filePath`. `ReflexEnvironment.modelDirectory()` and the CLI's `defaultModelsDirectory()` both delegate to it, so one resolver, not three. Proven: `--diagnose` → 0 blocking issues. Re-audited with an escape-hatch pattern that catches assembled paths. | 2026-10-02 |
| D18 | `files/build-and-verify.sh` model gate was dead code: `${PIPESTATUS[0]}` was redirected to `/dev/null` and swallowed with `\|\| true`. It only worked because `pipefail` aborted first. | warn | fixed | Replaced with an explicit `if ! ... \| tee` exit-status check plus an independent `grep -q "verify OK"` condition, so a silent pass fails the script. Same failure mode as D3. | 2026-10-02 |
| D19 | The 2026-10-02 evidence contained no clean-build proof: `build-macos.log` and `build-ios.log` were re-runs of an already-built tree (0 compile actions, 0 warnings). "BUILD SUCCEEDED" proved the tree still linked, not that current sources compile from scratch. | warn | fixed | `files/build-and-verify.sh` re-run from a cleared derived-data path on this branch. See `evidence/build-clean.log`. | 2026-10-02 |
| D5 | `Models/` (4.8 GB) was gitignored with no committed placeholder, violating the clone rule. | error | fixed | Added `Models/MANIFEST.md` with sizes, SHA-256 tree hashes, source URLs, re-acquire commands, and a verify one-liner, plus `Models/.gitkeep`. Fixed `.gitignore` to exclude `Models/*` rather than `Models/` so the negation actually takes effect. | 2026-10-02 |
| D6 | Planning context lived on the Desktop, outside the project. | error | fixed | `Reflex_Implementation_Plan.md` and `Jev_Voice_Action_Reference.md` moved to `docs/`, SHA-256 verified byte-identical before and after. | 2026-10-02 |
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
| D20 | **Skill copy drift:** `~/.config/opencode/skills/atlas/SKILL.md` differs from `<workspace>/SKILL.md`. The host copy lost the "Automated audit script" paragraph (lines 234-237 in workspace). Per Atlas spec, host copy must stay byte-identical to workspace original. | warn | open | Re-install: copy `<workspace>/SKILL.md` → host skills dir. Or edit workspace original and re-install; never edit host copy directly. | 2026-10-03 |
| D21 | **Self-containment evidence corrupted:** an automated script (`atlas-self-containment-audit.sh`) overwrote `evidence/self-containment.txt` with false positives. It grepped for APIs but did **not classify by reading** — it counted 5 hits as "violations" including intentional code (`expanduser` on user arg), documentation lines in ATLAS.md, and the two intentional `NSHomeDirectory()` calls. The script violated "Classify, do not count" and "Search the API, not the string" (then read every hit). Restored from git. | error | fixed | Remove or fix the script so it classifies each hit by reading it, and asserts a number with classification. Script currently produces unfalsifiable "violations" that require manual re-audit to debunk. Evidence restored to the correct re-verified audit. | 2026-10-03 |
| D22 | **`--laya-ref` 126/126 claim had no evidence file.** Asserted in Status and How to Run/Test, but no `evidence/laya-ref.txt` existed. Per "inherited results are not results" and "re-derive inherited results," this was an inherited claim, not evidence. | warn | fixed | Ran `reflex-cli --laya-ref tools/laya_reference.json` → 126/126. Output saved to `evidence/laya-ref.txt`. Independently re-verified. | 2026-10-03 |
| D23 | **DoD row 3 evidence degraded:** `evidence/build-cli.log` was 77 bytes, 0 compile actions, an incremental no-op. `build-clean.log` covers only macOS/iOS, not the SPM CLI release build. Binary existed (4.1 MB, mtime 22:08) and 0 sources were newer, so a release build did happen — but its log was overwritten. D19 failure mode recurred for the CLI. | warn | fixed | Cleared `ReflexCore/.build/out` and re-ran `swift build --package-path ReflexCore -c release` (32.83 s, 183 tasks planned). Log now shows real build work; `reflex-cli --verify` → `verify OK`. Evidence: `evidence/build-cli.log`. | 2026-10-03 |

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
