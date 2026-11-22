#!/bin/bash
# App in a Simulator against Mac bots, over real Bonjour and TCP.
# Usage: Scripts/e2e.sh [destination] [output dir]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1}"
OUT="${2:-build/e2e}"
rm -rf "$OUT"
mkdir -p "$OUT"

(cd Tools/BroBot && swift build >/dev/null)
BOT=Tools/BroBot/.build/debug/brobot
PIDS=()
cleanup() { for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

"$BOT" --lan --for 900 --name 0,1 --mood happy --code CAMP2345 --host --echo >"$OUT/brad.log" 2>&1 & PIDS+=($!)
"$BOT" --lan --for 900 --name 3,27 --mood love >"$OUT/roxy.log" 2>&1 & PIDS+=($!)
"$BOT" --lan --for 900 --name 9,7 --mood sus --code CAMP2345 --closed >"$OUT/dale.log" 2>&1 & PIDS+=($!)

status=0
xcodebuild test -project BroChat.xcodeproj -scheme BroChat -destination "$DEST" \
  -derivedDataPath build/dd -jobs "${AGENTGRID_CPU_SHARE:-4}" -parallel-testing-enabled NO \
  -resultBundlePath "$OUT/result.xcresult" >"$OUT/test.log" 2>&1 || status=$?
grep -E "error:|Test Case.*(passed|failed)|\*\* TEST" "$OUT/test.log" | sort -u || true

mkdir -p "$OUT/shots"
xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/raw" >/dev/null 2>&1 || true
python3 - "$OUT" <<'PY'
import json, pathlib, shutil, sys
out = pathlib.Path(sys.argv[1])
manifest = out / "raw/manifest.json"
if manifest.exists():
    for test in json.loads(manifest.read_text()):
        for item in test["attachments"]:
            name = item["suggestedHumanReadableName"].split("_")[0]
            if name[:2].isdigit():
                shutil.copy(out / "raw" / item["exportedFileName"], out / "shots" / f"{name}.png")
PY
exit "$status"
