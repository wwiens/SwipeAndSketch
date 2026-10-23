# Contributing to Swipe & Sketch

Thanks for your interest. Bug reports, crash files, and small, focused pull requests are welcome. For anything larger, such as a new tool or a change to how an existing tool works, open an issue first so we can agree on the approach before you spend time on it.

## Building

1. Run `Scripts/build_kernel.sh`. It builds Open CASCADE and the kernel facade into `Vendor/SSKernel.xcframework`. The first run takes about 25 minutes.
2. Open `SwipeAndSketch.xcodeproj` in Xcode 27.
3. Under **Signing & Capabilities**, pick your own team and bundle identifier. Don't commit those changes.
4. If your team doesn't have the Private Cloud Compute entitlement, remove it locally from `SwipeAndSketch/SwipeAndSketch.entitlements`, and don't commit that either. The assistant then falls back to the on-device model. The app never calls the cloud model from a build without the entitlement (`PrivateCloudEntitlement`).

## Hardware

Swipe & Sketch needs an Apple Pencil. The Pencil draws, selects, and drags geometry; fingers navigate. There is no finger-drawing mode, and pull requests that add one won't be accepted. Simulator tests can't show how a change feels with a real Pencil or whether palm rejection still works, so say in your pull request whether you tried it on an iPad.

## Tests

```sh
swift test
```

```sh
xcodebuild test -project SwipeAndSketch.xcodeproj -scheme SwipeAndSketch \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

Add tests with your change: core tests in `Tests/CoreTests` for geometry and file behavior, hosted tests in `Tests/AppTests` for tools and canvas input.

## Ground rules

- **The Xcode project is maintained by hand.** Add new files to `SwipeAndSketch.xcodeproj` carefully, and never regenerate it.
- **Files:** `.swipesketch` files store millimeters and a format version. Never silently replace an unreadable or newer-version file with an empty model. See [Docs/ProjectFiles.md](Docs/ProjectFiles.md).
- **Editing:** a drag previews live and commits one undo step when the Pencil lifts. Numeric edits are validated before they change the document.
- **New modeling tools** get an `AssistantWorkbench` operation (so the assistant can use them) and a help topic in `HelpTopics.swift`.
- **Paid features** are gated only through `LicenseStore` and `LicenseAccess` (`Licensing.swift`). Pull requests that remove or bypass that gating won't be accepted.
- **Wording:** use standard CAD terms in the interface.
- **Look:** app chrome uses the Swipe & Sketch icons and colors in `Assets.xcassets` (`ss-*`), not SF Symbols.

## Licensing of contributions

Swipe & Sketch is distributed under the PolyForm Shield License 1.0.0, and the same code ships in the paid App Store app. For your contribution to be usable in both, you agree, by submitting a pull request, that:

1. You wrote the contribution, or otherwise have the right to submit it under these terms.
2. You grant Warren Wiens a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, copy, modify, distribute, sublicense, and relicense your contribution, as part of Swipe & Sketch or otherwise, including in commercial products. You also grant a patent license on the same terms as section 3 of the Apache License 2.0.
3. Your contribution will be published in this repository under the PolyForm Shield License 1.0.0.

You keep the copyright in your contribution.

## Conduct

Be kind and assume good intent. Harassment or personal attacks in issues or pull requests will get you blocked from the repository.
