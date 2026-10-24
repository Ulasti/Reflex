#!/usr/bin/env bash
# Build and verify every Reflex artifact. Single command that produces the
# evidence the Definition of Done requires.
#
# Usage:
#   atlas/files/build-and-verify.sh          # everything: builds, tests, --verify
#   atlas/files/build-and-verify.sh --quick  # skip the iOS target
#
# Do NOT use this to rebuild models. That is tools/convert.py's job.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="atlas/evidence"
mkdir -p "$LOG_DIR"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

fail() { echo "FAIL: $1" >&2; exit 1; }

# A reused derived-data path turns the next build into an incremental no-op that
# proves nothing, which is how D23 kept recurring. Every run builds into its own
# timestamped path, so the macOS log always shows real compile work
# (atlas/docs/audit-2026-10-14.md, N5). Nothing is deleted: old run directories
# under $TMPDIR are left for the user (or the OS) to reclaim.
DD="${TMPDIR:-/tmp}/reflex-dd-verify-$(date +%Y%m%d-%H%M%S)"
echo "    derived data: $DD (delete when you no longer need it)"

# Exit non-zero unless the log actually contains compilation, not just a success
# line from a cache hit.
require_compile_actions() {
  local log="$1" actions
  actions=$(grep -cE "Compiling|SwiftCompile|CompileSwift|CompileC|builtin-Swift|^Ld " "$log" || true)
  [[ "${actions:-0}" -gt 0 ]] || fail "$log shows no compile actions - a no-op build is not evidence (D23)"
  echo "    compile actions: $actions"
}

# 1. Regenerate the Xcode project. Reflex.xcodeproj is generated from project.yml
#    by XcodeGen, so project.yml is the source of truth. The spec sits at the
#    repo root, next to the project it generates.
echo "==> [1/5] xcodegen generate"
xcodegen generate \
  > "$LOG_DIR/xcodegen.log" 2>&1 || fail "xcodegen (see $LOG_DIR/xcodegen.log)"

# 2. macOS app (the primary target).
echo "==> [2/5] xcodebuild Reflex-macOS (fresh derived data)"
xcodebuild -project Reflex.xcodeproj -scheme Reflex-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build \
  > "$LOG_DIR/build-macos.log" 2>&1 || fail "macOS build (see $LOG_DIR/build-macos.log)"
grep -q "BUILD SUCCEEDED" "$LOG_DIR/build-macos.log" || fail "macOS build did not report success"
require_compile_actions "$LOG_DIR/build-macos.log"

# 3. iOS/iPadOS app.
if [[ $QUICK -eq 0 ]]; then
  echo "==> [3/5] xcodebuild Reflex-iOS"
  xcodebuild -project Reflex.xcodeproj -scheme Reflex-iOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD-ios" \
    build CODE_SIGNING_ALLOWED=NO > "$LOG_DIR/build-ios.log" 2>&1 \
    || fail "iOS build (see $LOG_DIR/build-ios.log)"
else
  echo "==> [3/5] Reflex-iOS SKIPPED (--quick)"
  echo "skipped by --quick" > "$LOG_DIR/build-ios.log"
fi

# 4. ReflexCore unit tests. A suite no gate runs is not evidence, so the summary
#    line is required and any failure symbol fails the run.
echo "==> [4/5] swift test ReflexCore"
swift test --package-path reflexApp/ReflexCore > "$LOG_DIR/tests.log" 2>&1 \
  || fail "tests (see $LOG_DIR/tests.log)"
grep -q "Test run with" "$LOG_DIR/tests.log" || fail "swift test wrote no summary line"
if grep -qE "✘|error:" "$LOG_DIR/tests.log"; then
  fail "tests failed (see $LOG_DIR/tests.log)"
fi

# 5. SPM package + CLI, then verify every CoreML bundle actually compiles.
echo "==> [5/5] swift build ReflexCore + reflex-cli --verify"
swift build --package-path reflexApp/ReflexCore -c release > "$LOG_DIR/build-cli.log" 2>&1 \
  || fail "SPM build (see $LOG_DIR/build-cli.log)"
grep -q "Build complete!" "$LOG_DIR/build-cli.log" || fail "SPM build did not report success"

CLI="reflexApp/ReflexCore/.build/out/Products/Release/reflex-cli"
[[ -x "$CLI" ]] || fail "reflex-cli release binary not found at $CLI"

# --verify exits non-zero when models are missing or nothing was found.
# Assert that status explicitly instead of trusting `pipefail` alone: the
# previous gate *looked* like it checked the exit status and did not, which is
# the same failure mode as Atlas Doctor D3. See D18.
if ! "$CLI" --verify 2>&1 | tee "$LOG_DIR/verify-models.log"; then
  fail "model verification (see $LOG_DIR/verify-models.log)"
fi

# A second, independent condition: an exit status of 0 with no "verify OK" is a
# silent pass, which D3 was originally about.
grep -q "verify OK" "$LOG_DIR/verify-models.log" \
  || fail "--verify exited 0 without reporting 'verify OK' - silent pass"

echo
echo "All builds, tests and model checks succeeded. Evidence written to $LOG_DIR/."
echo "NOTE: models are gitignored. If --verify reports missing packages, see Models/MANIFEST.md."
