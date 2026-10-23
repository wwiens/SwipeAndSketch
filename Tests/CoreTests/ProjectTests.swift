import XCTest
@testable import SwipeAndSketchCore

final class ProjectTests: XCTestCase {
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
}
