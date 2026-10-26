import Foundation

/// Thread-safe box so a test can collect values inside a `@Sendable` callback.
///
/// `StreamSegmenter.onSegment` and friends are `@Sendable`, so they cannot
/// capture a mutable `var`. `NSLock` mirrors `AudioCaptureManager`.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
