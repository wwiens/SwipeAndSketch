import XCTest
@testable import SwipeAndSketch

/// The New Project gallery's card pictures (October 22, 2026): drawn once, at each template's
/// defaults, into the asset catalog, so the gallery opens at once instead of building and drawing
/// every template on the iPad.
@MainActor final class TemplatePictureTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Redraws every picture into Assets.xcassets/Templates and records what each shows in
    /// Tests/Fixtures/TemplatePictures.json. Runs only from Scripts/render_template_pictures.sh.
    func testRenderGalleryPictures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_TEMPLATE_PICTURES"] == "1",
                          "Draws the gallery pictures; run Scripts/render_template_pictures.sh")
        let manager = FileManager.default
        let folder = root.appending(path: "SwipeAndSketch/Assets.xcassets/Templates")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: folder.appending(path: "Contents.json"))
        var manifest: [String: String] = [:]
        for template in TemplateCatalog.all {
            let parts = ModelPicture.parts(of: try template.workspace(template.pictureValues))
            let png = try XCTUnwrap(ModelPicture.image(parts: parts, side: 480)?.pngData(), template.id)
            let set = folder.appending(path: template.pictureName + ".imageset")
            try manager.createDirectory(at: set, withIntermediateDirectories: true)
            try png.write(to: set.appending(path: "picture.png"))
            try Data(#"{"images":[{"filename":"picture.png","idiom":"universal","scale":"2x"}],"info":{"author":"xcode","version":1}}"#.utf8)
                .write(to: set.appending(path: "Contents.json"))
            manifest[template.id] = try template.pictureFingerprint()
        }
        // Pictures of templates that are gone.
        let names = Set(TemplateCatalog.all.map { $0.pictureName + ".imageset" })
        for item in try manager.contentsOfDirectory(atPath: folder.path()) where item.hasSuffix(".imageset") && !names.contains(item) {
            try manager.removeItem(at: folder.appending(path: item))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: root.appending(path: "Tests/Fixtures/TemplatePictures.json"))
    }

    func testEveryTemplateHasAGalleryPicture() {
        for template in TemplateCatalog.all {
            XCTAssertNotNil(UIImage(named: template.pictureName), "\(template.id) has no picture; run Scripts/render_template_pictures.sh")
        }
    }
}
