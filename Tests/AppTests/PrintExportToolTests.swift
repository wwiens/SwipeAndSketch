import XCTest
import simd
@testable import SwipeAndSketch

/// Export 3MF and Send to Slicer through the session.
@MainActor final class PrintExportToolTests: CanvasTestCase {

    /// App preferences these tests change, put back afterwards (hosted tests share the app's settings).
    private static let preferenceKeys = ["fitClearance", "print.folderBookmark", "print.placement", "print.bedWidth", "print.bedDepth"]
    private var savedPreferences: [String: Any] = [:]
    override func setUp() async throws {
        try await super.setUp()
        savedPreferences = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
    }
    override func tearDown() async throws {
        for key in Self.preferenceKeys { UserDefaults.standard.set(savedPreferences[key], forKey: key) }
        try await super.tearDown()
    }
    func settled(_ session: ModelingSession) async throws {
        for _ in 0..<500 where session.isProjectBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isProjectBusy)
    }

    func testExport3MFIsNamedLaidOutAndPictured() async throws {
        let (session, controller) = boxScene()
        defer { withExtendedLifetime(controller) {} }
        session.chooseTool(.fitTest)
        let parts = session.printParts(.visible)
        XCTAssertEqual(parts.map(\.name), ["Body 01", "Body 02", "Body 03"])
        session.select(.body(session.workspace.bodies[1].id))
        XCTAssertEqual(session.printParts(.selected).map(\.name), ["Body 02"])
        session.printLayout = PrintLayout(placement: .arranged, bed: [256, 256])
        XCTAssertTrue(session.printFits(.visible))
        XCTAssertEqual(PrintLayout.stored.bed, [256, 256], "Remembered")
        session.printLayout.bed = [60, 60]
        XCTAssertFalse(session.printFits(.visible), "Too small a plate")
        session.printLayout.bed = [256, 256]

        XCTAssertNotNil(session.thumbnailProvider?(), "The canvas supplies a preview picture")
        session.sendToPrinter(.visible, toFolder: false)
        try await settled(session)
        let url = try XCTUnwrap(session.exportItem?.url)
        XCTAssertEqual(url.pathExtension, "3mf")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        XCTAssertNotNil(data.range(of: Data("Metadata/thumbnail.png".utf8)), "The preview is packaged")
        XCTAssertEqual(session.status, "Exported 3MF")
    }

    func testSendToSlicerSavesIntoThePrintFolderAndReplacesTheLastVersion() async throws {
        let (session, _) = boxScene()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Prints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session.rememberPrintFolder(folder)
        XCTAssertEqual(session.printFolderName, folder.lastPathComponent)
        session.printSheet = .send
        session.sendToPrinter(.visible, toFolder: true)
        XCTAssertNil(session.printSheet, "The sheet closes")
        try await settled(session)
        let file = folder.appendingPathComponent("Untitled Project.3mf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(session.status, "Sent Untitled Project.3mf to \(folder.lastPathComponent)")
        let first = try Data(contentsOf: file)
        session.chooseTool(.fitTest)
        session.sendToPrinter(.visible, toFolder: true)
        try await settled(session)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".3mf") }.count, 1, "Replaced, not duplicated")
        XCTAssertGreaterThan(try Data(contentsOf: file).count, first.count, "The newest version, with the coupon")
    }
}
