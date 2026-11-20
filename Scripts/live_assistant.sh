#!/bin/zsh
# Sends real assistant requests through the app's engine (AssistantTests.testLiveRequests) on an
# iPad simulator and prints each request's trace.
#
#   Scripts/live_assistant.sh gemini [model] [effort] ["request|request|..."]
#
# The first argument is cloud, onDevice, claude, openai, or gemini. For claude, openai, and gemini,
# the key is read from a file of that name in LIVE_KEYS (default ~/.swipesketch-keys), holding just
# the key. The key is never printed or put on a command line. Usage is billed to that API account.
set -euo pipefail
cd "$(dirname "$0")/.."
backend=${1:?"Usage: Scripts/live_assistant.sh cloud|onDevice|claude|openai|gemini [model] [effort] [requests]"}
source_keys=${LIVE_KEYS:-$HOME/.swipesketch-keys}
# The simulator can't read the home folder's hidden folders, so the key is copied for this run
# into a private temporary folder (only you can open it) and removed when the script ends.
keys=$(mktemp -d /tmp/swipesketch-keys.XXXXXX)
chmod 700 "$keys"
trap 'rm -rf "$keys"' EXIT
if [[ -f "$source_keys/$backend" ]]; then cp "$source_keys/$backend" "$keys/$backend"; chmod 600 "$keys/$backend"; fi
device=${LIVE_DEVICE:-"platform=iOS Simulator,name=iPad Air 11-inch (M4)"}
log=build/live-$backend.log
mkdir -p build

TEST_RUNNER_LIVE_ASSISTANT=1 \
TEST_RUNNER_LIVE_BACKEND=$backend \
TEST_RUNNER_LIVE_KEYS=$keys \
TEST_RUNNER_LIVE_MODEL=${2:-} \
TEST_RUNNER_LIVE_EFFORT=${3:-} \
TEST_RUNNER_LIVE_REQUESTS=${4:-} \
TEST_RUNNER_LIVE_SCENE=${LIVE_SCENE:-} \
  xcodebuild test -project SwipeAndSketch.xcodeproj -scheme SwipeAndSketch -destination "$device" \
    -only-testing:SwipeAndSketchTests/AssistantTests/testLiveRequests > "$log" 2>&1 || true

# The trace lines, then the result.
grep -E "^(Live |▶︎|  ·|      ↳|  ⟵|  changes:|  ■|  checks:|  [0-9.]+ s on|  ✗|    details:)|Test Case .*(passed|failed|skipped)|error:" "$log" || tail -30 "$log"
