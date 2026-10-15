#!/usr/bin/env bash
# Build and verify every Reflex artifact. Single command that produces the
# evidence the Definition of Done requires.
#
# Usage:
#   ./files/build-and-verify.sh          # build all three + verify models
#   ./files/build-and-verify.sh --quick  # skip the iOS target
#
# Do NOT use this to rebuild models. That is tools/convert.py's job.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="evidence"
mkdir -p "$LOG_DIR"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Regenerate the Xcode project. Reflex.xcodeproj is generated from
#    project.yml by XcodeGen, so project.yml is the source of truth.
echo "==> [1/4] xcodegen generate"
xcodegen generate > "$LOG_DIR/xcodegen.log" 2>&1 || fail "xcodegen (see $LOG_DIR/xcodegen.log)"

# 2. macOS app (the primary target).
echo "==> [2/4] xcodebuild Reflex-macOS"
xcodebuild -project Reflex.xcodeproj -scheme Reflex-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/reflex-dd build \
  > "$LOG_DIR/build-macos.log" 2>&1 || fail "macOS build (see $LOG_DIR/build-macos.log)"
grep -q "BUILD SUCCEEDED" "$LOG_DIR/build-macos.log" || fail "macOS build did not report success"

# 3. iOS/iPadOS app.
if [[ $QUICK -eq 0 ]]; then
  echo "==> [3/4] xcodebuild Reflex-iOS"
  xcodebuild -project Reflex.xcodeproj -scheme Reflex-iOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/reflex-dd-ios \
    build CODE_SIGNING_ALLOWED=NO > "$LOG_DIR/build-ios.log" 2>&1 \
    || fail "iOS build (see $LOG_DIR/build-ios.log)"
else
  echo "==> [3/4] Reflex-iOS SKIPPED (--quick)"
  echo "skipped by --quick" > "$LOG_DIR/build-ios.log"
fi

# 4. SPM package + CLI, then verify every CoreML bundle actually compiles.
echo "==> [4/4] swift build ReflexCore + reflex-cli --verify"
swift build --package-path ReflexCore -c release > "$LOG_DIR/build-cli.log" 2>&1 \
  || fail "SPM build (see $LOG_DIR/build-cli.log)"

CLI="ReflexCore/.build/out/Products/Release/reflex-cli"

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
echo "All builds succeeded. Evidence written to $LOG_DIR/."
echo "NOTE: models are gitignored. If --verify reports missing packages, see Models/MANIFEST.md."
