#if os(macOS)
import Darwin
import Foundation

/// Minimal wrapper over MediaRemote — the same private now-playing engine that
/// feeds Control Center and the media keys — so playback commands route to the
/// app that is *actually* hosting audio right now (Safari casting a series,
/// Music, Spotify, a web app, ...). Symbols are resolved via dlsym at runtime,
/// so the package never needs a direct link against the private framework and
/// the iOS build stays clean.
public enum NowPlaying {
    public struct Status: Sendable, Equatable {
        public let bundleIdentifier: String
        public let title: String
        public let artist: String
        public let isPlaying: Bool

        /// Whether anything is registered as the system's now-playing source.
        public var isHosting: Bool { !bundleIdentifier.isEmpty }
    }

    /// CoreMediaRemote's `MRMediaRemoteCommand` values (ordinal order is stable
    /// in the private headers: play=0, pause=1, toggle=2, stop=3, next=4, prev=5).
    public enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias GetClientFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (AnyObject?) -> Void
    ) -> Void
    private typealias GetInfoFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (NSDictionary) -> Void
    ) -> Void
    private typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Void

    nonisolated(unsafe) private static let framework: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
    }()

    /// Resolves one C symbol out of the privately loaded framework.
    private static func load<T>(_ name: String) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// Who is the system playing through right now?
    public static func status() -> Status {
        var bundleIdentifier = ""
        if let fn: GetClientFn = load("MRMediaRemoteGetNowPlayingClient") {
            let semaphore = DispatchSemaphore(value: 0)
            fn(DispatchQueue.global(qos: .userInitiated)) { client in
                if let client = client as? NSObject,
                   let id = client.value(forKey: "bundleIdentifier") as? String,
                   !id.isEmpty {
                    bundleIdentifier = id
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.5)
        }

        var title = ""
        var artist = ""
        var isPlaying = false
        if let fn: GetInfoFn = load("MRMediaRemoteGetNowPlayingInfo") {
            let semaphore = DispatchSemaphore(value: 0)
            fn(DispatchQueue.global(qos: .userInitiated)) { info in
                let dict = info as? [String: Any] ?? [:]
                title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                isPlaying = rate != 0
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.5)
        }

        return Status(
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: artist,
            isPlaying: isPlaying
        )
    }

    /// Sends a transport command to whatever the system considers the
    /// now-playing source. Returns false if MediaRemote is unreachable.
    @discardableResult
    public static func send(_ command: Command) -> Bool {
        guard let fn: SendCommandFn = load("MRMediaRemoteSendCommand") else { return false }
        fn(command.rawValue, nil)
        return true
    }

    /// Friendly label for a bundle identifier (or the raw id when unknown).
    public static func appLabel(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Safari": "Safari"
        case "com.google.Chrome": "Chrome"
        case "com.microsoft.edgemac": "Edge"
        case "com.brave.Browser": "Brave"
        case "com.spotify.client": "Spotify"
        case "com.apple.Music": "Music"
        case "com.apple.TV": "TV"
        case "com.apple.quicktimeplayer": "QuickTime Player"
        default: bundleIdentifier
        }
    }
}
#endif
