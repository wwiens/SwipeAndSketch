import XCTest
import simd
@testable import SwipeAndSketchCore

/// Reading a project for Shortcuts without opening it: the parts it exports, and files it must
/// refuse without ever changing them.
final class ProjectReaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Two solids, the second hidden and renamed "Lid".
    func workspace() throws -> Workspace {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))
        let profile = try XCTUnwrap(Geometry.profiles(in: [rectangle], on: .top).first)
        var space = Workspace(shapes: [rectangle], bodies: [SolidBody(profile: profile, depth: 10), SolidBody(profile: profile, depth: 5)])
        space = try XCTUnwrap(space.renaming(body: space.bodies[1].id, to: "Lid"))
        space.bodies[1].hidden = true
        return space
    }

    func file(_ project: Project, named name: String = "Bracket") throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("swipesketch")
        try ProjectCodec.create(project, at: url)
        return url
    }

    func testReadsTheProjectAndItsPrintParts() throws {
        let space = try workspace()
        let url = try file(Project(workspace: space))
        let before = try Data(contentsOf: url), date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let project = try ProjectReader.read(url)
        XCTAssertEqual(project.workspace, space)
        XCTAssertEqual(ProjectReader.name(of: url), "Bracket")
        XCTAssertEqual(project.workspace.printParts(includingHidden: false).map(\.name), ["Body 01"], "Visible solids, as the Export sheet")
        XCTAssertEqual(project.workspace.printParts(includingHidden: true).map(\.name), ["Body 01", "Lid"])

        let entries = PartsList.entries(project.workspace.printParts(includingHidden: true).map { ($0.body, $0.name) }, settings: FilamentSettings())
        XCTAssertEqual(entries.map(\.estimate.volume).reduce(0, +), 20 * 10 * 15, accuracy: 1e-3)
        let stl = try ModelExport.file(project.workspace.printParts(includingHidden: false), format: .stl, title: "Bracket", layout: PrintLayout(), thumbnail: nil)
        XCTAssertGreaterThan(stl.count, 84, "A binary STL with triangles")
        let threeMF = try ModelExport.file(project.workspace.printParts(includingHidden: true), format: .threeMF, title: "Bracket", layout: PrintLayout(), thumbnail: nil)
        XCTAssertEqual(threeMF.prefix(2), Data("PK".utf8))

        XCTAssertEqual(try Data(contentsOf: url), before, "Reading never writes")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, date)
    }

    func testRefusesFilesItCannotReadAndLeavesThemAlone() throws {
        let url = try file(Project(workspace: try workspace()))
        // A newer format than this version knows.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: url)
        XCTAssertThrowsError(try ProjectReader.read(url))
        XCTAssertEqual(try Data(contentsOf: url), future, "Left exactly as it was")

        let damaged = Data("{\"format\": \"noventix.SwipeAndSketch.project\", \"workspace\": ".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try ProjectReader.read(url))
        XCTAssertEqual(try Data(contentsOf: url), damaged)

        let gone = folder.appendingPathComponent("Gone.swipesketch")
        XCTAssertThrowsError(try ProjectReader.read(gone)) { error in
            XCTAssertEqual(error as? ProjectReader.Failure, .missing("Gone"))
            XCTAssertEqual(error.localizedDescription, "“Gone” could not be found. It may have been moved or deleted.")
        }
    }

    func testExportFileNamesAreSafe() {
        XCTAssertEqual(ModelExport.fileName("Lid 2/3: final", format: .threeMF), "Lid 2-3- final.3mf")
        XCTAssertEqual(ModelExport.fileName("", format: .stl), "Untitled Project.stl")
    }
}
