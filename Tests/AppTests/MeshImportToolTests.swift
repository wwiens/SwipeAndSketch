import XCTest
import simd
@testable import SwipeAndSketch

/// Import Mesh: an STL file brought in as a solid, as one undo step (October 24, 2026).
@MainActor final class MeshImportToolTests: CanvasTestCase {
    func testAnSTLImportsAsASolidInAGroup() async throws {
        let session = ModelingSession(inMemory: true)
        let stl = try ModelExport.stl([try XCTUnwrap(Primitives.body(.cylinder, sizes: [20, 10], on: .top, at: .zero))])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knob-\(UUID().uuidString).stl")
        try stl.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        session.importMesh(from: url)
        for _ in 0..<500 where session.isProjectBusy { try await Task.sleep(for: .milliseconds(20)) }
        let body = try XCTUnwrap(session.workspace.bodies.first)
        XCTAssertTrue(body.isImported)
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, .pi * 100 * 10, accuracy: 15, "Faceted, as the STL is")
        XCTAssertNotNil(body.group, "In a group named after the file")
        XCTAssertTrue(session.status.hasPrefix("Imported 1 solid"), session.status)
        session.undo()
        XCTAssertTrue(session.workspace.bodies.isEmpty)
    }
}
