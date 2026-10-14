#if os(macOS)
import CoreGraphics
import Darwin
import Foundation

/// Display brightness through CoreDisplay's private C API (loaded via dlsym —
/// brightness has no public SET API; this is the same call MonitorControl-class
/// apps use). All active displays are driven together.
public enum BrightnessController {
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Double) -> Int32
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID) -> Double

    nonisolated(unsafe) private static let framework: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
    }()

    private static func load<T>(_ name: String) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Current brightness (percent) of the primary display, or nil if the
    /// private API is unavailable on this hardware/profile.
    public static func current() -> Int? {
        guard let fn: GetBrightnessFn = load("CoreDisplay_Display_GetUserBrightness") else {
            return nil
        }
        guard let display = activeDisplays().first else { return nil }
        return Int((fn(display) * 100).rounded())
    }

    /// Sets all active displays to `percent` (0...100). Returns the clamped
    /// value actually requested.
    @discardableResult
    public static func set(_ percent: Int) throws -> Int {
        let clamped = min(100, max(0, percent))
        guard let fn: SetBrightnessFn = load("CoreDisplay_Display_SetUserBrightness") else {
            throw BrightnessError.unavailableOnThisMac
        }
        let displays = activeDisplays()
        guard !displays.isEmpty else { throw BrightnessError.noDisplays }
        for display in displays {
            _ = fn(display, Double(clamped) / 100.0)
        }
        return clamped
    }

    /// Adjusts brightness by `delta` points (signed) against the primary
    /// display's current value. Returns the delta actually applied.
    @discardableResult
    public static func adjust(by delta: Int) throws -> Int {
        let current = current() ?? 50
        let next = min(100, max(0, current + delta))
        let applied = next - current
        if applied != 0 { _ = try set(next) }
        return applied
    }
}

public enum BrightnessError: LocalizedError {
    case unavailableOnThisMac
    case noDisplays

    public var errorDescription: String? {
        switch self {
        case .unavailableOnThisMac:
            "CoreDisplay brightness API is not available on this Mac."
        case .noDisplays:
            "No active displays found."
        }
    }
}
#endif
