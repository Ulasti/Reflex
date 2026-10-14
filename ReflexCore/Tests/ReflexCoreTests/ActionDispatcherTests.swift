import Foundation
import Testing
@testable import ReflexCore

#if os(macOS)

/// `runTool` is the one subprocess chokepoint: osascript, pmset, mdfind and
/// screencapture all go through it. Finding M1 is a deadlock in it.
@Suite("ActionDispatcher.runTool")
struct RunToolTests {
    @Test("returns the command's stdout")
    func returnsStdout() throws {
        let output = try ActionDispatcher.runTool("/bin/echo", arguments: ["hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("a nonzero exit throws with the merged output")
    func nonzeroExitThrows() {
        #expect(throws: ActionExecutionError.self) {
            try ActionDispatcher.runTool("/bin/sh", arguments: ["-c", "echo boom; exit 3"])
        }
    }

    /// M1 (`docs/audit-2026-10-14.md`): `waitUntilExit()` runs before the pipe
    /// is drained, so once the child writes past the ~64 KB pipe buffer it
    /// blocks on write and the parent blocks in `wait()`.
    ///
    /// The child is a Perl one-liner that writes 200704 bytes (49 × 4 KB) and
    /// arms a 5 s alarm that `_exit`s without flushing. That matters: a blocked
    /// child that never dies keeps the pipe open and hangs the test runner
    /// instead of failing a test. With the bug the write stalls after one pipe
    /// buffer, the alarm kills the child, and `runTool` returns 65536 bytes —
    /// a clean failure. With the fix the parent drains continuously, Perl
    /// finishes in under a second and the alarm never fires.
    ///
    /// The call runs on a bare `Thread`, not the cooperative pool, because a
    /// regression would occupy a pool thread forever.
    @Test("output larger than the pipe buffer is neither truncated nor deadlocked")
    func largeOutputDoesNotDeadlock() async {
        let producer = """
            $|=1;
            $SIG{ALRM} = sub { POSIX::_exit(9) };
            alarm 5;
            my $chunk = "y" x 4096;
            for (1..49) { print $chunk }
            """

        let output = LockedBox<String?>(nil)
        Thread {
            output.withLock {
                $0 = try? ActionDispatcher.runTool("/usr/bin/perl", arguments: ["-MPOSIX", "-e", producer])
            }
        }.start()

        await withKnownIssue("audit M1: runTool waits for exit before draining the pipe") {
            var waited = 0
            while output.withLock({ $0 == nil }), waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            #expect(output.withLock { $0 }?.count == 200_704)
        }
    }
}

/// `system_control` phrase handling. The router must never send a phrase that
/// `systemOperation(for:)` cannot map, because a miss becomes a runtime
/// `parseFailure` the user hears as "I didn't catch that".
@Suite("ActionDispatcher.systemControl")
struct SystemControlTests {
    @Test("known phrases map to their operation", arguments: [
        ("lock the screen", ActionDispatcher.SystemOperation.lockScreen),
        ("reveal the desktop", ActionDispatcher.SystemOperation.showDesktop),
        ("set dark mode", ActionDispatcher.SystemOperation.darkMode(true)),
        ("turn on light mode", ActionDispatcher.SystemOperation.darkMode(false)),
        ("empty the trash", ActionDispatcher.SystemOperation.emptyTrash),
        ("empty the bin", ActionDispatcher.SystemOperation.emptyTrash),
    ])
    func maps(phrase: String, expected: ActionDispatcher.SystemOperation) {
        #expect(ActionDispatcher.systemOperation(for: phrase) == expected)
    }

    @Test("every phrase the router sends here is dispatchable")
    func routedPhrasesAreDispatchable() {
        let phrases = [
            "lock the screen", "reveal the desktop", "set dark mode", "turn on light mode",
            "empty the trash", "empty the bin", "clear the trash",
        ]
        for phrase in phrases {
            #expect(RuleRouter().classify(phrase)?.target == "system_control", "\(phrase) should route here")
            #expect(ActionDispatcher.systemOperation(for: phrase) != nil, "\(phrase) has no operation")
        }
    }

    @Test("\"turn off the screen\" is dispatchable")
    func screenOffIsDispatchable() {
        withKnownIssue("audit M3: systemControl has no branch for \"turn off the screen\"") {
            #expect(ActionDispatcher.systemOperation(for: "turn off the screen") != nil)
        }
    }

    @Test("\"unlock the screen\" must not lock it")
    func unlockDoesNotLock() {
        withKnownIssue("audit M3: \"unlock the screen\" contains \"lock\", so the fuzzy match locks the screen") {
            #expect(ActionDispatcher.systemOperation(for: "unlock the screen") != .lockScreen)
        }
    }

    @Test("an unhandled phrase reports a parse failure rather than guessing")
    func unhandledThrows() {
        #expect(ActionDispatcher.systemOperation(for: "increase the font size") == nil)
    }
}

#endif
