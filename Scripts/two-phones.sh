#!/bin/bash
# Two Simulators running the real app, talking to each other with no bots.
# Usage: Scripts/two-phones.sh [destination A] [destination B]
set -euo pipefail
cd "$(dirname "$0")/.."
A="${1:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1}"
B="${2:-platform=iOS Simulator,name=iPhone 16,OS=18.6}"
OUT=build/two-phones
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild build-for-testing -project BroChat.xcodeproj -scheme BroChat \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd >"$OUT/build.log" 2>&1
RUN=$(ls build/dd/Build/Products/*.xctestrun | head -1)

phone() {
  TEST_RUNNER_BRO_TWO_PHONES=1 xcodebuild test-without-building -xctestrun "$RUN" -destination "$2" \
    -only-testing:BroChatUITests/BroChatUITests/testTwoPhones \
    -resultBundlePath "$OUT/$1.xcresult" >"$OUT/$1.log" 2>&1
}

status=0
phone a "$A" & first=$!
phone b "$B" & second=$!
wait "$first" || status=1
wait "$second" || status=1
grep -hE "error:|Test Case.*(passed|failed|skipped)|\*\* TEST" "$OUT/a.log" "$OUT/b.log" || true
exit "$status"
