# Release policy

Swipe & Sketch is experimental CAD software for iPad. The agreed App Store plan is a free download, a full 14-day trial, and a $19.99 USD one-time purchase to continue creating and editing, with localized storefront prices. There is one complete product and no subscription or separate feature tiers.

Every current and future tool, template, import, export, and assistant editing feature shipped in this app is included during the trial and after purchase. After the trial, opening, viewing, sharing, and full-quality export remain available without purchase. Access changes must preserve accepted edits and recovery saves. Optional Claude requests use the user's own API key; Anthropic bills that usage separately.

The app’s own code and contributions use the MIT License. Commercial and competing reuse are permitted with the copyright and license notice retained. The official name, logo, and app icon remain protected trademarks; forks need their own branding. Third-party material keeps its own licenses.

## Support

Bug reports, crash files, and focused contributions are welcome. Support and fixes are provided as time allows, without a guaranteed response time or fix schedule. The maintainer decides priorities and scope.

The one-time purchase does not promise perpetual development, compatibility with every future iPadOS version, personal CAD training, or a feature delivery schedule. Existing purchases and trial periods already granted must be honored when changing pricing or trial policy.

A useful report includes the app version, iPad model and iPadOS version, steps to reproduce, expected and actual results, and whether the problem happens again. Attach a small example project only when comfortable sharing it. Keep backups of important projects.

## Release blocker

A known data-loss defect blocks release. This includes lost or silently overwritten edits, damaged project files, and unreadable or future-version files being replaced with empty projects. Fix the defect and verify its reproduction before releasing.

Other known limitations can ship when described honestly. Experimental status does not waive the data-loss blocker.

Purchase and restoration failures that prevent legitimate access also block the paid release. Before introducing the purchase system, audit earlier public access promises and distributed builds and resolve any transition policy explicitly.

## Verification

Before release, run core geometry and persistence tests, hosted app tests covering input, rendering, editing and document coordination, and simulator UI tests. Verify affected saving, reopening, undo/redo, preview and cancellation paths. Record failures and limitations.

For the purchase release, also complete the purchase acceptance checks, including StoreKit sandbox purchase/restore, expiration during editing and saving, offline access, and retrieval of projects after the trial.

Check real Apple Pencil input and palm rejection on an iPad separately. Simulator tests do not prove either behavior. Do not describe a check as passed unless it was performed.
