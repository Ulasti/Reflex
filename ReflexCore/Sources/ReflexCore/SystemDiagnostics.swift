#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Startup health preflight ("Reflex --diagnose"). Probes every permission and
/// dependency Reflex needs, tells you exactly what's missing, and offers to
/// open the right System Settings pane — so mac automation denials (a top
/// source of per-command failures) surface before you speak, not after.
public enum SystemDiagnostics {
    public enum Status: Equatable {
        case ok
        case warn(String)   // functional but degraded
        case fail(String)   // blocking: must fix
        case info(String)   // informational

        public var isBlocking: Bool {
            if case .fail = self { return true }
            return false
        }
    }

    public struct Check {
        public let name: String
        public let status: Status
        public let howToFix: String?
    }

    public struct Report {
        public let checks: [Check]
        /// True when every blocking check passed and nothing requires action.
        public let ready: Bool

        public var blockingCount: Int {
            checks.filter { $0.status.isBlocking }.count
        }
    }

    /// Runs the preflight. `probeMic` additionally records a half-second clip to
    /// verify the mic actually delivers audio (not just that the permission
    /// exists). `browserBundleIDs` lets callers scope the probe (default:
    /// every supported browser).
public static func run(
        probeMic: Bool = true,
        modelDirectory: URL = ReflexWhisperKit.defaultModelsDirectory,
        browserBundleIDs: [String] = BrowserController.browserBundleIDs
    ) -> Report {
        var checks: [Check] = []

        // ---- WhisperKit model present? (marker-based install check)
        let wkInstalled = ReflexWhisperKit.isInstalled(in: modelDirectory)
        checks.append(Check(
            name: "Whisper model",
            status: wkInstalled
                ? .ok
                : .fail("whisper-small models not found in \(modelDirectory.path)"),
            howToFix: wkInstalled ? nil
                : "Run `reflex-cli --wk-install small` (or `tools/download_whisperkit_models.py`)."
        ))

        // ---- Microphone permission (TCC).
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            checks.append(Check(name: "Microphone permission", status: .ok, howToFix: nil))
        case .denied:
            checks.append(Check(
                name: "Microphone permission",
                status: .fail("denied"),
                howToFix: "Allow the app controlling Reflex in System Settings → Privacy & Security → Microphone."
            ))
        case .restricted:
            checks.append(Check(
                name: "Microphone permission",
                status: .fail("restricted (parental/management restriction)"),
                howToFix: "Unrestrict mic access for this app via your MDM/system controls."
            ))
        case .notDetermined:
            checks.append(Check(
                name: "Microphone permission",
                status: .warn("not determined — will prompt on first command"),
                howToFix: "Say a command or run `reflex-cli --record 1` once to trigger the prompt."
            ))
        @unknown default:
            checks.append(Check(name: "Microphone permission", status: .warn("unknown state"), howToFix: nil))
        }

        // ---- Mic actually delivers audio? (ground-truth, not just permission)
        if probeMic && micStatus == .authorized {
            let (ok, detail) = probeMicrophone()
            checks.append(Check(
                name: "Microphone audio",
                status: ok ? .ok : .fail(detail),
                howToFix: ok ? nil : "Choose an active input in System Settings → Sound → Input."
            ))
        } else if probeMic {
            // Skip the recorded probe until permission is granted.
            checks.append(Check(
                name: "Microphone audio",
                status: .info("skipped — mic not authorized"),
                howToFix: nil
            ))
        }

        // ---- Accessibility (System Events keystrokes / scripting).
        let axOK = AXIsProcessTrusted()
        checks.append(Check(
            name: "Accessibility",
            status: axOK ? .ok : .fail("not granted — keystrokes, typing and System Events fail"),
            howToFix: axOK ? nil
                : "Grant Accessibility to the terminal/app running Reflex in System Settings → Privacy & Security → Accessibility."
        ))

        // ---- Browser automation (Apple Events to each browser).
        for bundleID in browserBundleIDs {
            let (running, ok, detail) = probeBrowserAutomation(bundleID: bundleID)
            let label = bundleName(bundleID)
            let status: Status = ok
                ? (running ? .ok : .info(detail))
                : .fail(detail)
            checks.append(Check(
                name: "Browser automation — \(label)",
                status: status,
                howToFix: ok ? nil
                    : "Allow Automation for \(label) in System Settings → Privacy & Security → Automation (or click Allow on the prompt), then re-run."
            ))
        }

        // ---- System default https handler resolves to a browser we can drive.
        let defaultBrowser = BrowserController.preferredBundleID()
        let supported = BrowserController.browserBundleIDs.contains(defaultBrowser)
        checks.append(Check(
            name: "Default browser",
            status: supported
                ? .ok
                : .warn("\(bundleName(defaultBrowser)) is the default https handler but isn't automatable"),
            howToFix: supported ? nil
                : "Switch the default browser to Safari, Chrome, Edge, Brave or Opera in System Settings → Desktop & Dock → Default web browser."
        ))

        let blocking = checks.filter { $0.status.isBlocking }
        let ready = blocking.isEmpty
        return Report(checks: checks, ready: ready)
    }

    /// Records ~0.5 s and reports whether real audio samples arrived and
    /// whether they carry signal (i.e. not digital silence).
    private static func probeMicrophone() -> (ok: Bool, detail: String) {
        let manager = AudioCaptureManager()
        manager.storeSamples = true
        do {
            try manager.start()
        } catch {
            return (false, "couldn't open input: \(error.localizedDescription)")
        }
        Thread.sleep(forTimeInterval: 0.5)
        let samples = manager.stop()
        var sum = 0.0
        for s in samples { sum += Double(s * s) }
        let rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()
        if samples.count < 2000 {
            return (false, "mic returned silence/\(samples.count) samples (\(String(format: "%.3f", rms)) RMS) — check your input device")
        }
        return (true, "\(samples.count) samples, \(String(format: "%.3f", rms)) RMS")
    }

    /// Probes whether Apple Events to a running browser are authorized. Only
    /// browsers currently running are tested — probing a closed app would
    /// launch it, which a health check must never do. Missing/closed browsers
    /// report as informational "not running" (automation only matters once you
    /// actually use that browser).
    private static func probeBrowserAutomation(bundleID: String) -> (running: Bool, ok: Bool, detail: String) {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        guard running else {
            return (false, true, "not running — skipped")
        }
        // Minimal Apple Event that requires automation permission but does nothing.
        let script = """
        tell application id "\(bundleID)"
            try
                if (count of windows) is 0 then return "0"
                return "1"
            on error
                return "ERR"
            end try
        end tell
        """
        do {
            let out = try ActionDispatcher.runTool("/usr/bin/osascript", arguments: ["-e", script])
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "ERR" {
                return (true, false, "browser reported an error reading its window state")
            }
            return (true, true, "automation allowed")
        } catch let ActionExecutionError.unexpectedExit(_, _, output) where output.contains("not allowed") {
            return (true, false, "automation denied — Apple Events to this browser blocked")
        } catch {
            return (true, false, "osascript failed: \(error.localizedDescription)")
        }
    }

    private static func bundleName(_ bundleID: String) -> String {
        let names = [
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Chrome",
            "com.microsoft.edgemac": "Edge",
            "com.brave.Browser": "Brave",
            "com.operasoftware.Opera": "Opera",
        ]
        return names[bundleID] ?? bundleID
    }
}
#endif
        return names[bundleID] ?? bundleID
