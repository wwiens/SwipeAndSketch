# Help walkthrough integration

The native help card follows the website handoff `docs/app-guide-and-walkthroughs.md`
(October 30, 2026 snapshot). It keeps the built-in Text overview and loads a compact,
scripted canvas lesson only when Walkthrough is selected. Playback needs a connection;
the catalog cache does not provide offline lessons.

## Discovery and trust

`Walkthroughs.swift` discovers the newest activated catalog for `canvas-menus-v3` using
the public HTTPS endpoint. No publishing credentials or owner operations belong in the app.
Every catalog entry's page and embed URL is validated, including lessons without a native
topic mapping. All mapped IDs must exist and IDs retain their case. Native selection uses
`topics[HelpTopic.rawValue]`, with the default first and alternatives in server order;
content tags do not select lessons.

The last validated response is cached atomically. Network, HTTP and compatibility failures
retain that response; an explicit `available: false` clears it. Each playback URL pins its
release. A later compatible catalog refresh recreates the player with the new release's
navigation policy. The handoff's lesson counts are descriptive snapshots, not compatibility
checks: the existing v5 test fixture has 217 entries while the handoff lists 214. Newer,
unmapped app topics retain Text help. The retired `moveShape` mapping is ignored.

## Player and lifecycle

`WalkthroughPlayer.swift` loads only HTTPS player pages on the exact trusted origin and
release path. Runtime scripts and data load as web subresources; child-frame navigation is
blocked. User-activated external HTTPS links use the system browser. Bridge events must
come from this web view's expected top-level player URL and origin. Progress fields require
integers, a supported speed and a consistent completion index. Neither project state nor
modeling operations cross the bridge.

Every player navigation starts a readiness deadline. HTTP errors, navigation failure,
web-process termination, missing readiness and `load_failed` offer Try Again and Show Text.
Messages arriving after failure or teardown cannot restore readiness. Pause uses
`callAsyncJavaScript` with a separate structured argument when help closes, changes to Text,
opens All controls, or the app leaves the foreground. A page that becomes ready in the
background is also paused. Retry loads the selected lesson from its start. Closing help
resets the card to Text; opening Walkthrough again starts the topic's default lesson.

## Verification

`WalkthroughTests` covers catalog mappings and cache behavior, URL validation, strict event
parsing, and real WebKit navigation/messages using local simulated HTTPS page responses.
The local bridge fixture is a protocol test, not the website renderer. UI tests cover Text
help, card controls, backgrounding, and portrait/landscape placement. Existing canvas tests
cover geometry rendering and the Pencil input pipeline; walkthroughs do not edit geometry.

Before release, verify the deployed website on an iPad: a mini lesson, both analytic starter
projects and a prepared project; play/pause, replay, previous/next, all five speeds and seek
to zero/completion; close/background pause; offline and failed-geometry fallback; and old
pinned URLs after activation of a new release. Website deployment/activation and physical
Apple Pencil feel and palm rejection require separate checks. The handoff's written tutorial
dimensions remain authoritative for those tutorials; project lessons may use different sizes.
