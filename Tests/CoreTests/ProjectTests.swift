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

    /// A solid whose one hole has `points` points: `points²` of the polygon-check budget.
    static func solidWithHole(points: Int) -> SolidBody {
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -50, y: -50), end: .init(x: 50, y: 50))
        var profile = Geometry.profiles(in: [square], on: .top)[0]
        profile.holes = [ProfileHole(outline: (0..<points).map { i in
            let a = Double(i) / Double(points) * 2 * .pi
            return Point2(x: 10 * cos(a), y: 10 * sin(a))
        })]
        return SolidBody(profile: profile, depth: 5)
    }

    func testProjectsWhoseSolidsCarryLongDefinitionsStillSave() throws {
        // Splitting one plate of an 8-solid Raspberry Pi case took it past the old 20 million
        // budget and the project could no longer be saved (November 8, 2026). 10 × 2048² ≈ 42 million.
        let bodies = (0..<10).map { _ in Self.solidWithHole(points: 2_048) }
        let project = Project(workspace: Workspace(bodies: bodies))
        XCTAssertNoThrow(try ProjectCodec.validate(project))
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)).workspace, project.workspace)
        // The budget still bounds the checks: 24 × 2048² ≈ 101 million.
        let tooMany = Workspace(bodies: (0..<24).map { _ in Self.solidWithHole(points: 2_048) })
        XCTAssertThrowsError(try ProjectCodec.checkSize(tooMany)) { XCTAssertEqual($0 as? ProjectError, .tooLarge) }
        XCTAssertThrowsError(try ProjectCodec.validate(Project(workspace: tooMany))) { XCTAssertEqual($0 as? ProjectError, .tooLarge) }
    }

    func testFilesAreWrittenCompactAndIndentedOnesStillOpen() throws {
        var project = Project(workspace: workspace())
        project.preview = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<64).map { UInt8($0) })
        let data = try ProjectCodec.encode(project)
        XCTAssertFalse(data.contains(UInt8(ascii: "\n")), "No indentation")
        XCTAssertEqual(ProjectPreview.png(in: data), project.preview)
        XCTAssertEqual(try ProjectCodec.decode(data), project)
        // Files written before November 8, 2026 are indented.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let indented = try encoder.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(indented), project)
        XCTAssertEqual(ProjectPreview.png(in: indented), project.preview)
    }

    func testLeanFilesLeaveOutOnlyWhatReadsBackExactly() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 3, y: -2), end: .init(x: 8, y: -2))
        let round = try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first)
        XCTAssertEqual(round.outline, try XCTUnwrap(round.circle).outline(), "Drawn circles are their circle's points")
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -20, y: -20), end: .init(x: 20, y: 20))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [square], on: .top).first), depth: 10)
        body.cuts.append(ExtrusionCut(profile: round, depth: 1, throughAll: true))
        body.cuts.append(.offsetFaces(at: [SIMD3(0, 0, 10)], by: 1, of: body))
        var merged = body
        merged.id = UUID()
        body.cuts.append({ var step = ExtrusionCut(profile: body.profile, depth: 1); step.merged = merged; return step }())
        var moved = try XCTUnwrap(body.transformed(by: .rotate(degrees: 30, about: [0, 0, 1], through: [1, 2, 0])))
        moved.id = UUID()
        let project = Project(workspace: Workspace(bodies: [body, moved]))

        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data), project, "Reads back exactly")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bodies = try XCTUnwrap((json["workspace"] as? [String: Any])?["bodies"] as? [[String: Any]])
        let cuts = try XCTUnwrap(bodies[0]["cuts"] as? [[String: Any]])
        XCTAssertNil((cuts[0]["profile"] as? [String: Any])?["outline"], "A circle's own points are left out")
        XCTAssertNil(cuts[1]["profile"], "Offset Face carries the solid's own profile: left out")
        XCTAssertNil(cuts[2]["profile"], "So does the merge")
        let nested = try XCTUnwrap(cuts[2]["merged"] as? [String: Any])
        XCTAssertNil((nested["cuts"] as? [[String: Any]])?[1]["profile"], "Inside the merged solid too")
        let turned = try XCTUnwrap(bodies[1]["cuts"] as? [[String: Any]])
        XCTAssertNil((turned[0]["profile"] as? [String: Any])?["outline"], "Turning moves the plane, not the circle's points")
        XCTAssertNil(turned[1]["profile"], "Still the turned solid's own profile")
        // Points that are not exactly the circle's (here starting one further round) are kept.
        var shifted = round
        shifted.outline = Array(round.outline.dropFirst()) + [round.outline[0]]
        let shiftedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shifted)) as? [String: Any]
        XCTAssertNotNil(shiftedJSON?["outline"])
        XCTAssertEqual(try JSONDecoder().decode(SketchProfile.self, from: JSONEncoder().encode(shifted)), shifted)

        // A step coded on its own keeps its profile.
        let alone = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body.cuts[1])) as? [String: Any]
        XCTAssertNotNil(alone?["profile"])
        XCTAssertEqual(try JSONDecoder().decode(ExtrusionCut.self, from: JSONEncoder().encode(body.cuts[1])), body.cuts[1])

        // Files written before (every outline and profile written out) read the same.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var full = json
        full["schemaVersion"] = 1
        var fullBodies = bodies
        var fullCuts = cuts
        var first = try XCTUnwrap(fullCuts[0]["profile"] as? [String: Any])
        first["outline"] = try XCTUnwrap(round.circle).outline().map { ["x": $0.x, "y": $0.y] }
        fullCuts[0]["profile"] = first
        fullCuts[1]["profile"] = bodies[0]["profile"]
        fullBodies[0]["cuts"] = fullCuts
        var workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        workspace["bodies"] = fullBodies
        full["workspace"] = workspace
        let older = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        let read = try ProjectCodec.decode(older)
        XCTAssertEqual(read.schemaVersion, 1)
        XCTAssertEqual(read.workspace, project.workspace)
        let resaved = try JSONSerialization.jsonObject(with: ProjectCodec.encode(read)) as? [String: Any]
        XCTAssertEqual(resaved?["schemaVersion"] as? Int, 2, "Saved again as version 2")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
    }

    func testCirclesCountTheirPointsTowardThePolygonBudget() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let round = try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first)
        XCTAssertNotNil(round.circle)
        XCTAssertGreaterThan(round.outline.count, 64)
        XCTAssertEqual(ProjectCodec.polygonWork(of: round), round.outline.count, "Checked point by point")
        // A hole is checked against crossings, quadratically.
        let drilled = Self.solidWithHole(points: 100).profile
        XCTAssertEqual(ProjectCodec.polygonWork(of: drilled), 4 * 4 + 100 * 100)
        // Thousands of round bosses and holes, as an enclosure has, fit.
        var body = SolidBody(profile: round, depth: 5)
        for _ in 0..<250 { body.cuts.append(ExtrusionCut(profile: round, depth: 1, operation: .join)) }
        let bodies = (0..<20).map { _ -> SolidBody in var copy = body; copy.id = UUID(); return copy }
        XCTAssertNoThrow(try ProjectCodec.checkSize(Workspace(bodies: bodies)), "5,000 circles: 0.6 million, not 82 million")
    }

    func testAnEditChecksOnlyTheSolidsItChanged() throws {
        let good = Self.solidWithHole(points: 64)
        var broken = Self.solidWithHole(points: 64)
        broken.depth = .nan
        let known = Workspace(bodies: [good])
        XCTAssertTrue(Workspace(bodies: [good, Self.solidWithHole(points: 32)]).isValid(changedFrom: known))
        XCTAssertFalse(Workspace(bodies: [good, broken]).isValid(changedFrom: known), "A new solid is checked")
        var changed = good
        changed.depth = .infinity
        XCTAssertFalse(Workspace(bodies: [changed]).isValid(changedFrom: known), "A changed solid is checked")
        var history = WorkspaceHistory(workspace: known)
        history.commit(Workspace(bodies: [good, broken]))
        XCTAssertFalse(history.canUndo)
        XCTAssertThrowsError(try ProjectCodec.validate(Project(workspace: Workspace(bodies: [changed])), changedFrom: known)) {
            XCTAssertEqual($0 as? ProjectError, .invalidModel)
        }
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
