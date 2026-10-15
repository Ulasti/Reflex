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

    /// M1 (`atlas/docs/audit-2026-10-14.md`) was `waitUntilExit()` before draining the
    /// pipe; fixed by draining first, so this is now a plain assertion.
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

        // The 5 s alarm is a guard: if the drain regresses, the producer blocks
        // on a full pipe and, without the alarm, would keep the test runner
        // alive forever instead of failing one test.
        var waited = 0
        while output.withLock({ $0 == nil }), waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(output.withLock { $0 }?.count == 200_704)
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
        #expect(ActionDispatcher.systemOperation(for: "turn off the screen") != nil)
    }

    @Test("\"unlock the screen\" must not lock it")
    func unlockDoesNotLock() {
        #expect(ActionDispatcher.systemOperation(for: "unlock the screen") != .lockScreen)
    }

    @Test("an unhandled phrase reports a parse failure rather than guessing")
    func unhandledThrows() {
        #expect(ActionDispatcher.systemOperation(for: "increase the font size") == nil)
    }
}

#endif
