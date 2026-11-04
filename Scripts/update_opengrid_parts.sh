#!/bin/zsh
# Writes SwipeAndSketch/Core/OpenGridPartData.swift from the official openGrid files in
# Tests/Fixtures/OpenGrid (see the README there): each part's solid, centered on the origin.
# OpenGridTests.testPartsMatchTheOfficialFiles checks the result against the same files.
set -euo pipefail
cd "$(dirname "$0")/.."
OPENGRID_WRITE_PARTS="$PWD/SwipeAndSketch/Core/OpenGridPartData.swift" \
  swift test --filter OpenGridTests/testWritePartData 2>&1 | grep -E "error:|Executed|failed" || true
