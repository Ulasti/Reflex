# Reflex — On-Device Voice Command Router

Reflex listens for a spoken command, transcribes it entirely on-device with Whisper, decides what you meant using the Laya intent router, and performs the action. macOS first, with the same SwiftUI code shared into iOS/iPadOS. Nothing leaves the machine — speech-to-text and intent routing both run on the Neural Engine.

## Install

**Requirements:** macOS 14+, Xcode 27+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
# 1. Clone
git clone https://github.com/Ulasti/Reflex.git
cd Reflex

# 2. Generate Xcode project
xcodegen generate

# 3. Download CoreML models (one-time, ~4.8 GB)
# See Models/MANIFEST.md for the exact commands

# 4. Open and run
open Reflex.xcodeproj
# Select the "Reflex-macOS" scheme and press ▶️ Run
```

The app lives in your menu bar. Grant Microphone and Accessibility permissions when prompted.

## Quick Examples

| You say… | Reflex does… |
|---|---|
| "Open Safari" | Launches/activates Safari |
| "Remind me to call mom tomorrow" | Creates a Reminders entry |
| "Make a folder called invoices and move the PDFs into it" | Creates `~/invoices` and moves matching files |
| "Play some jazz" | Starts playing jazz in your music app |
| "What is the capital of France?" | Shows the answer in a popover |
| "URGENT: delete the staging database right now" | Asks for confirmation, then runs the destructive action |
| "Create the backend project and open my coding split" | Runs your custom multi-step workflow |

All transcription and intent routing happens locally on the Neural Engine — no network calls.

## License

MIT License — see [LICENSE](LICENSE) for details.