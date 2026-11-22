import XCTest
import AppIntents
import simd
@testable import SwipeAndSketch

/// Shortcuts actions run directly: they read projects (the editor's open one as on screen) and
/// export them, and never change a project file.
@MainActor final class ShortcutsIntentTests: CanvasTestCase {
    private static let preferenceKeys = ["print.folderBookmark", "print.placement", "print.bedWidth", "print.bedDepth"] + FilamentSettings.keys
    private var savedPreferences: [String: Any] = [:]
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedPreferences = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        ShortcutsBridge.openSession = nil
        for key in Self.preferenceKeys { UserDefaults.standard.set(savedPreferences[key], forKey: key) }
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// A project file with two 60 × 40 × 20 boxes, the second hidden.
    func projectFile(named name: String = "Bracket") throws -> URL {
        let (session, _) = boxScene()
        var workspace = session.workspace
        var copy = workspace.bodies[0]
        copy.id = UUID()
        copy.hidden = true
        workspace.bodies.append(copy)
        let url = folder.appendingPathComponent(name).appendingPathExtension("swipesketch")
        try ProjectCodec.create(Project(workspace: workspace), at: url)
        return url
    }

    func entity(_ url: URL) -> ProjectEntity {
        ProjectEntity(RecentProject(id: RecentProjects.key(url), url: url, name: ProjectReader.name(of: url), date: .now, place: .iPad, sketches: 1, solids: 2), picture: nil)
    }

    func testExportGivesA3MFAnSTLAndAPartsListAndLeavesTheFileAlone() async throws {
        let url = try projectFile()
        let before = try Data(contentsOf: url)
        var intent = ExportProjectIntent(project: entity(url), format: .threeMF)
        let threeMF = try await intent.perform()
        let file = try XCTUnwrap(threeMF.value)
        XCTAssertEqual(file.filename, "Bracket.3mf")
        XCTAssertEqual(file.data.prefix(2), Data("PK".utf8))

        intent.format = .stl
        let stl = try await intent.perform()
        XCTAssertEqual(stl.value?.filename, "Bracket.stl")

        intent.format = .partsList
        intent.parts = .all
        let csvResult = try await intent.perform()
        let csv = try XCTUnwrap(csvResult.value)
        XCTAssertEqual(csv.filename, "Bracket Parts List.csv")
        let lines = String(decoding: csv.data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "Header, both solids (hidden too, with All), total")
        XCTAssertTrue(lines[1].hasPrefix("Body 01,60.00,40.00,20.00,48000.0,"))

        XCTAssertEqual(try Data(contentsOf: url), before, "Exporting never changes the project")
    }

    func testAProjectFileHandedOverWorksWithoutHome() async throws {
        let url = try projectFile(named: "Handed Over")
        var intent = GetPartsListIntent()
        intent.file = IntentFile(fileURL: url, filename: url.lastPathComponent)
        intent.parts = .visible
        let partsResult = try await intent.perform()
        let parts = try XCTUnwrap(partsResult.value)
        XCTAssertEqual(parts.map(\.name), ["Body 01"], "Visible solids by default")
        XCTAssertEqual(parts[0].x, 60)
        XCTAssertEqual(parts[0].z, 20)
        XCTAssertGreaterThan(parts[0].grams, 0)

        var none = GetPartsListIntent()
        none.parts = .visible
        // No project or file: the system asks which project (a needs-value request), nothing runs.
        do { _ = try await none.perform(); XCTFail("No project") } catch {
            XCTAssertTrue(String(describing: error).contains("missing parameter value"), String(describing: error))
        }
    }

    func testTheOpenProjectIsReadAsOnScreen() async throws {
        let url = try projectFile()
        let (session, controller) = boxScene()
        defer { withExtendedLifetime(controller) {} }
        session.chooseTool(.fitTest)
        XCTAssertEqual(session.workspace.bodies.count, 3, "Unsaved: the Fit Test coupon's two parts added")
        ShortcutsBridge.openSession = { RecentProjects.key($0) == RecentProjects.key(url) ? session : nil }
        var intent = GetPrintEstimateIntent()
        intent.project = entity(url)
        intent.parts = .visible
        let result = try await intent.perform()
        XCTAssertEqual(result.value?.parts, 3, "The editor's model, not the saved file's")
    }

    func testEstimateFollowsTheFilamentSettings() async throws {
        let url = try projectFile()
        var settings = FilamentSettings()
        settings.material = .petg
        settings.infill = 1
        settings.pricePerKilogram = 30
        settings.store()
        var intent = GetPrintEstimateIntent()
        intent.project = entity(url)
        intent.parts = .visible
        let estimateResult = try await intent.perform()
        let estimate = try XCTUnwrap(estimateResult.value)
        XCTAssertEqual(estimate.grams, 48 * 1.27, accuracy: 0.05, "Solid PETG: the whole 48 cm³")
        XCTAssertEqual(estimate.cost, 48 * 1.27 / 1000 * 30, accuracy: 0.01)
        XCTAssertEqual(estimate.parts, 1)
        XCTAssertTrue(estimate.summary.hasPrefix("About 61 g of PETG ("), estimate.summary)
    }

    func testSendToSlicerSavesIntoThePrintFolderOrSaysHowToChooseOne() async throws {
        let url = try projectFile()
        var intent = SendToSlicerIntent()
        intent.project = entity(url)
        intent.format = .stl
        intent.parts = .visible
        do { _ = try await intent.perform(); XCTFail("No folder yet") } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("There is no folder to save to yet."), error.localizedDescription)
        }
        let prints = folder.appendingPathComponent("Prints", isDirectory: true)
        try FileManager.default.createDirectory(at: prints, withIntermediateDirectories: true)
        try PrintFolder.remember(prints)
        let result = try await intent.perform()
        XCTAssertEqual(result.value?.filename, "Bracket.stl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prints.appendingPathComponent("Bracket.stl").path))
        _ = try await intent.perform()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: prints.path), ["Bracket.stl"], "Replaces the last version")
    }

    func testAProjectWithNoSolidsSaysSo() async throws {
        let url = folder.appendingPathComponent("Empty.swipesketch")
        try ProjectCodec.create(Project(), at: url)
        var intent = ExportProjectIntent(project: entity(url), format: .stl)
        intent.parts = .all
        do { _ = try await intent.perform(); XCTFail("Nothing to export") } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("“Empty” has no solids to use."), error.localizedDescription)
        }
    }
}
