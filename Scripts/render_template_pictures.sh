#!/bin/zsh
# Redraws the New Project gallery's template pictures (SwipeAndSketch/Assets.xcassets/Templates)
# and their record (Tests/Fixtures/TemplatePictures.json). Run it after adding a template or
# changing what one makes at its defaults; TemplateTests.testGalleryPicturesAreCurrent says when.
#
#   Scripts/render_template_pictures.sh [simulator UDID]
#
# Without a UDID it uses the first available iPad simulator running iOS 27.
set -euo pipefail
cd "$(dirname "$0")/.."

device=${1:-$(xcrun simctl list devices available | awk '/-- iOS 27/{f=1;next} /-- /{f=0} f && /iPad/' \
  | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)}
[[ -n $device ]] || { echo "No iOS 27 iPad simulator found; pass a UDID." >&2; exit 1; }

derived=$(mktemp -d)
trap 'rm -rf "$derived"' EXIT
# TEST_RUNNER_ variables reach the tests' environment without the prefix.
TEST_RUNNER_RENDER_TEMPLATE_PICTURES=1 xcodebuild test \
  -project SwipeAndSketch.xcodeproj -scheme SwipeAndSketch \
  -destination "id=$device" -derivedDataPath "$derived" \
  -only-testing:SwipeAndSketchTests/TemplatePictureTests/testRenderGalleryPictures -collect-test-diagnostics never \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)" || true

ls SwipeAndSketch/Assets.xcassets/Templates
