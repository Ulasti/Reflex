# Reflex — On-Device Voice Command Router

Reflex listens for a spoken command, transcribes it entirely on-device, decides
what you meant, and performs the action. macOS first, with the same UI shared
into an iOS/iPadOS app.

Nothing leaves the machine: speech-to-text is Whisper compiled to CoreML, intent
routing is the Laya router, and both run on the Neural Engine.

## Status

Phase 1 scaffold plus a large uncommitted Phase 2 working set. See
[ATLAS.md](ATLAS.md) for the authoritative status, blockers, and next steps.

## Layout

| Path | What it is |
|---|---|
| `Reflex/` | SwiftUI app, shared by the macOS and iOS targets. |
| `ReflexCore/` | SPM package. All the real logic: audio, transcription, routing, dispatch. |
| `ReflexCore/Sources/ReflexCLI/` | `reflex-cli`, the headless driver used for testing without the UI. |
| `Models/` | Converted CoreML bundles. Gitignored. See [Models/MANIFEST.md](Models/MANIFEST.md). |
| `tools/` | Python toolchain that converts model weights into `.mlpackage` bundles. |
| `project.yml` | XcodeGen source of truth. `Reflex.xcodeproj` is generated from it. |
| `docs/` | Implementation plan and the upstream voice-action reference it maps onto. |
| `evidence/` | Build and verification logs referenced by the Definition of Done. |
| `files/` | Reusable scripts. See [files/INDEX.md](files/INDEX.md). |

## Build

Requires Xcode 27+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate                        # project.yml -> Reflex.xcodeproj
open Reflex.xcodeproj                   # then run the Reflex-macOS scheme
```

Or build everything from the command line:

```bash
./files/build-and-verify.sh
```

## Models

The app needs converted CoreML weights in `Models/`, which are **not** in git.
Fetch and verify them with the instructions in
[Models/MANIFEST.md](Models/MANIFEST.md). Without them the app builds but every
model call fails at runtime with a pointed diagnostic rather than a crash.

## Working on it

Read [ATLAS.md](ATLAS.md) first — it is the source of truth for status, branch
strategy, and the Definition of Done. Agent work goes on an `atlas/<feature>`
branch and is merged into `dev` after review.

Headless experimentation, without launching the UI:

```bash
swift build --package-path ReflexCore -c release
./ReflexCore/.build/out/Products/Release/reflex-cli --help
./ReflexCore/.build/out/Products/Release/reflex-cli --verify
```
