import XCTest
import ImageIO
@testable import SwipeAndSketchCore

final class ProjectTests: XCTestCase {
    func testLinkedNotesRoundTripMissingTargetsAndSafeVersioning() throws {
        let original = workspace()
        let body = try XCTUnwrap(original.bodies.first)
        let sketch = try XCTUnwrap(original.sketches.first)
        let bodyNote = ObjectNote(kind: .body, objectID: body.id, objectName: "Body 01")
        let sketchNote = ObjectNote(kind: .sketch, objectID: sketch.id, objectName: "Sketch 01")
        var linked = try XCTUnwrap(original.replacingNotes("Print flat", objectNote: bodyNote))
        linked = try XCTUnwrap(linked.replacingNotes("Leave 0.3 mm clearance", objectNote: sketchNote))
        linked = try XCTUnwrap(linked.replacingNotes("Project requirements"))
        XCTAssertEqual(linked.version, 3, "Editing project notes must not downgrade linked-note files")
        // Cleared notes give the file back to readers that predate them.
        let projectOnly = try XCTUnwrap(original.replacingNotes("Requirements"))
        XCTAssertEqual(projectOnly.version, 2)
        XCTAssertEqual(try XCTUnwrap(projectOnly.replacingNotes("")).version, 1)
        var history = WorkspaceHistory(workspace: try XCTUnwrap(original.replacingNotes("Print flat", objectNote: bodyNote)))
        XCTAssertTrue(history.deleteObjectNote(bodyNote.id))
        XCTAssertEqual(history.workspace.version, 1)
        XCTAssertTrue(original.hasSameModel(as: linked))
        let project = Project(workspace: linked)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)), project)
        XCTAssertEqual(project.copyForNewFile().workspace.objectNotes, linked.objectNotes)
        var oldReaderFile = linked; oldReaderFile.version = 2
        XCTAssertThrowsError(try ProjectCodec.encode(Project(workspace: oldReaderFile)))
        let renamed = try XCTUnwrap(linked.renaming(body: body.id, to: "Bracket"))
        XCTAssertEqual(renamed.name(for: renamed.objectNotes[0]), "Bracket")
        XCTAssertEqual(renamed.objectNotes[0].objectName, "Bracket")
        var missing = renamed
        missing.bodies.removeAll()
        missing.shapes.removeAll(); missing.normalizeSketches()
        XCTAssertNil(missing.name(for: missing.objectNotes[0]))
        XCTAssertEqual(missing.objectNotes[0].text, "Print flat")
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: missing))).workspace, missing)
        var duplicate = linked; duplicate.objectNotes.append(duplicate.objectNotes[0])
        XCTAssertFalse(duplicate.notesAreValid)
        duplicate = linked
        var sameTarget = duplicate.objectNotes[0]; sameTarget.id = UUID()
        duplicate.objectNotes.append(sameTarget)
        XCTAssertFalse(duplicate.notesAreValid)
        var oversized = linked
        oversized.notes = String(repeating: "x", count: Workspace.maximumNotesBytes)
        XCTAssertThrowsError(try ProjectCodec.encode(Project(workspace: oversized)))
    }

    func testLinkedNoteHistoryChangesOnlyMetadataAndGroupsText() throws {
        let original = workspace()
        let note = ObjectNote(kind: .body, objectID: original.bodies[0].id, objectName: "Body 01")
        var history = WorkspaceHistory(workspace: original)
        XCTAssertTrue(history.updateNotes("First", objectNote: note, amending: false))
        let saved = try XCTUnwrap(history.workspace.objectNotes.first)
        XCTAssertTrue(history.updateNotes("Second", objectNote: saved, amending: true))
        XCTAssertTrue(original.hasSameModel(as: history.workspace))
        history.undo(); XCTAssertEqual(history.workspace, original)
        history.redo(); XCTAssertEqual(history.workspace.objectNotes[0].text, "Second")
        XCTAssertTrue(history.deleteObjectNote(saved.id))
        XCTAssertTrue(history.workspace.objectNotes.isEmpty)
        history.undo(); XCTAssertEqual(history.workspace.objectNotes[0].text, "Second")
        var changed = history.workspace; changed.bodies[0].depth += 1
        XCTAssertFalse(original.hasSameModel(as: changed))
    }

    func testNotesOnlyHistoryAndModelComparison() throws {
        let original = workspace()
        var history = WorkspaceHistory(workspace: original)
        XCTAssertTrue(history.updateNotes("First", amending: false))
        XCTAssertTrue(history.updateNotes("Second", amending: true))
        XCTAssertTrue(original.hasSameModel(as: history.workspace))
        var changed = history.workspace
        changed.bodies[0].depth += 1
        XCTAssertFalse(original.hasSameModel(as: changed))
        changed = history.workspace
        changed.shapes[0].end.x += 1
        XCTAssertFalse(original.hasSameModel(as: changed))
        XCTAssertFalse(history.updateNotes(String(repeating: "x", count: Workspace.maximumNotesBytes + 1), amending: true))
        XCTAssertEqual(history.workspace.notes, "Second")
        history.undo(); XCTAssertEqual(history.workspace, original)
        history.redo(); XCTAssertEqual(history.workspace.notes, "Second")
    }

    func testNotebookRoundTripCopyAndLegacyCompatibility() throws {
        var original = workspace()
        let legacy = try ProjectCodec.encode(Project(workspace: original))
        XCTAssertEqual(try ProjectCodec.decode(legacy).workspace.notes, "")
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        let oldWorkspace = try XCTUnwrap(oldJSON["workspace"] as? [String: Any])
        XCTAssertEqual(oldWorkspace["version"] as? Int, 1)
        XCTAssertNil(oldWorkspace["notes"])

        original.notes = "Requirements\n• Fit: 0.3 mm\n日本語 ✏️\nhttps://example.com/part"
        original.version = 2
        let project = Project(workspace: original)
        let restored = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(restored, project)
        XCTAssertEqual(restored.copyForNewFile().workspace.notes, original.notes)
        XCTAssertEqual(restored.workspace.shapes, original.shapes)
        XCTAssertEqual(restored.workspace.bodies, original.bodies)
        // Readers shipped before notes require workspace version 1, so they refuse this file.
        XCTAssertEqual(restored.workspace.version, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectCodec.encode(project)) as? [String: Any])
        var saved = try XCTUnwrap(json["workspace"] as? [String: Any])
        saved["version"] = 99; json["workspace"] = saved
        XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testNotebookSizeAndVersionAreValidated() throws {
        var workspace = Workspace(notes: String(repeating: "é", count: Workspace.maximumNotesBytes / 2))
        XCTAssertNoThrow(try ProjectCodec.encode(Project(workspace: workspace)))
        workspace.notes += "a"
        XCTAssertThrowsError(try ProjectCodec.encode(Project(workspace: workspace)))
        workspace.notes = "Do not silently discard this note"
        workspace.version = 1
        XCTAssertThrowsError(try ProjectCodec.encode(Project(workspace: workspace)))
    }

    func workspace() -> Workspace {
        let circle = SketchShape(kind: .circle, plane: .right, start: .init(x: 12.345678901, y: -7.5), end: .init(x: 25.123456789, y: -7.5))
        let rectangle = SketchShape(kind: .rectangle, plane: .front, start: .zero, end: .init(x: 40, y: 25))
        let profile = Geometry.profiles(in: [circle], on: .right)[0]
        return Workspace(shapes: [circle, rectangle], bodies: [SolidBody(profile: profile, depth: -15.123456789)])
    }
    func testNativeRoundTripPreservesExactGeometryUnitsAndStableIDs() throws {
        let original = Project(workspace: workspace())
        let data = try ProjectCodec.encode(original)
        XCTAssertEqual(try ProjectCodec.decode(data), original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["units"] as? String, "millimeter")
        XCTAssertEqual(json["coordinateSystem"] as? String, "right-handed-z-up")
        XCTAssertNotNil(try ProjectCodec.decode(data).workspace.bodies[0].profile.circle)
    }
    func testFutureSchemaUnitsAndInvalidGeometryAreRejected() throws {
        let project = Project(workspace: workspace())
        let data = try ProjectCodec.encode(project)
        for (key, value) in [("schemaVersion", 99 as Any), ("units", "inch" as Any), ("format", "another.format" as Any)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json[key] = value
            XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json)))
        }
        var invalid = project
        invalid.workspace.bodies[0].profile.circle?.radius *= 2
        XCTAssertThrowsError(try ProjectCodec.encode(invalid))
        invalid = project; invalid.workspace.shapes[0].end.x = .infinity
        XCTAssertThrowsError(try ProjectCodec.encode(invalid))
        XCTAssertThrowsError(try ProjectCodec.decode(Data("truncated".utf8)))
    }
    func testCopyHasIndependentIdentityAndRetainsDeletedSourceExtrusion() throws {
        var project = Project(workspace: workspace())
        project.workspace.shapes.removeAll()
        let copy = project.copyForNewFile()
        XCTAssertNotEqual(copy.id, project.id)
        XCTAssertEqual(copy.workspace, project.workspace)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(copy)), copy)
    }
    func testCreatingNewFileNeverReplacesAnExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.swipesketch")
        let project = Project(workspace: workspace())
        try ProjectCodec.create(project, at: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ProjectCodec.create(Project(), at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testOversizedHoleOutlinesAreRejectedBeforeTheirQuadraticChecks() throws {
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -50, y: -50), end: .init(x: 50, y: 50))
        var profile = Geometry.profiles(in: [square], on: .top)[0]
        let points = (0..<5_000).map { i -> Point2 in
            let a = Double(i) / 5_000 * 2 * .pi
            return Point2(x: 10 * cos(a), y: 10 * sin(a))
        }
        profile.holes = [ProfileHole(outline: points)]
        let project = Project(workspace: Workspace(bodies: [SolidBody(profile: profile, depth: 5)]))
        XCTAssertThrowsError(try ProjectCodec.validate(project)) { XCTAssertEqual($0 as? ProjectError, .tooLarge) }
    }

    func testThePreviewPictureIsFoundWithoutDecodingTheModel() throws {
        // A PNG whose base64 has slashes, which JSON writes as "\/".
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png += Data((0..<300).map { UInt8($0 % 256) })
        var project = Project()
        XCTAssertNil(ProjectPreview.png(in: try ProjectCodec.encode(project)), "Files without a picture")
        project.preview = png
        let data = try ProjectCodec.encode(project)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\\/"), "The escape is exercised")
        XCTAssertEqual(ProjectPreview.png(in: data), png)
        XCTAssertEqual(try ProjectCodec.decode(data), project)
        XCTAssertEqual(project.copyForNewFile().preview, png, "Save As keeps the picture")
        // Only a real PNG counts, and an oversized one is refused.
        project.preview = Data("not a picture".utf8)
        XCTAssertNil(ProjectPreview.png(in: try ProjectCodec.encode(project)))
        project.preview = Data(count: ProjectPreview.maximumBytes + 1)
        XCTAssertThrowsError(try ProjectCodec.encode(project))
    }

    /// A picture's size is read from its header before it is decoded: one claiming more than the app
    /// saves, however few bytes it takes, is refused.
    func testPreviewPicturesAreDecodedOnlyAtASensibleSize() throws {
        func png(width: Int, height: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let picture = try XCTUnwrap(ProjectPreview.image(from: try png(width: 960, height: 960)))
        XCTAssertEqual(picture.width, 960)
        let huge = try png(width: 20_000, height: 1)
        XCTAssertLessThan(huge.count, ProjectPreview.maximumBytes, "Small in bytes")
        XCTAssertNil(ProjectPreview.image(from: huge))
        XCTAssertNil(ProjectPreview.image(from: Data("not a picture".utf8)))
    }
}
