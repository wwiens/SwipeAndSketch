# Release policy

Swipe & Sketch is free experimental CAD software for iPad, available to anyone. Every current and future feature is free. Optional Claude requests use the user's own API key; Anthropic bills that usage separately.

The app’s own code and contributions use the MIT License. Commercial and competing reuse are permitted with the copyright and license notice retained. The official name, logo, and app icon remain protected trademarks; forks need their own branding. Third-party material keeps its own licenses.

## Support

Bug reports, crash files, and focused contributions are welcome. Support and fixes are provided as time allows, without a guaranteed response time or fix schedule. The maintainer decides priorities and scope.

A useful report includes the app version, iPad model and iPadOS version, steps to reproduce, expected and actual results, and whether the problem happens again. Attach a small example project only when comfortable sharing it. Keep backups of important projects.

## Release blocker

A known data-loss defect blocks release. This includes lost or silently overwritten edits, damaged project files, and unreadable or future-version files being replaced with empty projects. Fix the defect and verify its reproduction before releasing.

Other known limitations can ship when described honestly. Experimental status does not waive the data-loss blocker.

## Verification

Before release, run core geometry and persistence tests, hosted app tests covering input, rendering, editing and document coordination, and simulator UI tests. Verify affected saving, reopening, undo/redo, preview and cancellation paths. Record failures and limitations.

Check real Apple Pencil input and palm rejection on an iPad separately. Simulator tests do not prove either behavior. Do not describe a check as passed unless it was performed.
