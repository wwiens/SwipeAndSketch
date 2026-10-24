import XCTest
import simd
@testable import SwipeAndSketchCore

/// STL and 3MF meshes imported as solids (October 24, 2026).
final class MeshImportTests: XCTestCase {
    func temporary(_ data: Data, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnExportedSTLComesBackAsTheSameSolid() throws {
        let block = try box(0, 0, 30, 20, depth: 10)
        let stl = try ModelExport.stl([block])
        let result = try MeshImport.read(try temporary(stl, "block.stl"), name: "block")
        XCTAssertEqual(result.bodies.count, 1)
        XCTAssertEqual(result.skipped, 0)
        let solid = try SolidKernel.solid(for: result.bodies[0])
        XCTAssertEqual(solid.volume, 6000, accuracy: 0.1)
        XCTAssertEqual(solid.faceCount, 6, "Flat sides merged into one face each")
        let workspace = try XCTUnwrap(STEPImport.adding(result, to: Workspace()))
        XCTAssertEqual(workspace.bodyNames[workspace.bodies[0].id], "block")
    }

    func testATextSTL() throws {
        // A tetrahedron, written out by hand.
        let corners: [SIMD3<Double>] = [[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]]
        let faces = [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]]
        var text = "solid tetra\n"
        for face in faces {
            text += "facet normal 0 0 0\nouter loop\n"
            for i in face { text += "vertex \(corners[i].x) \(corners[i].y) \(corners[i].z)\n" }
            text += "endloop\nendfacet\n"
        }
        text += "endsolid tetra\n"
        let result = try MeshImport.read(try temporary(Data(text.utf8), "tetra.stl"), name: "tetra")
        XCTAssertEqual(try SolidKernel.solid(for: result.bodies[0]).volume, 1000.0 / 6, accuracy: 0.01)
    }

    func testAnExported3MFComesBackWithItsParts() throws {
        let parts = [try box(0, 0, 10, 10, depth: 10), try box(30, 0, 40, 10, depth: 5)]
        let data = try ModelExport.threeMF(parts, title: "pair")
        let result = try MeshImport.read(try temporary(data, "pair.3mf"), name: "pair")
        XCTAssertEqual(result.bodies.count, 2)
        let volumes = try result.bodies.map { try SolidKernel.solid(for: $0).volume }.sorted()
        XCTAssertEqual(volumes[0], 500, accuracy: 0.1)
        XCTAssertEqual(volumes[1], 1000, accuracy: 0.1)
    }

    func testAnOpenMeshIsRefused() throws {
        // Three faces of a tetrahedron: not closed.
        var text = "solid open\n"
        for face: [SIMD3<Double>] in [[[0, 0, 0], [0, 10, 0], [10, 0, 0]], [[0, 0, 0], [10, 0, 0], [0, 0, 10]], [[0, 0, 0], [0, 0, 10], [0, 10, 0]], [[0, 0, 0], [0, 0, 10], [0, 10, 0]]] {
            text += "facet normal 0 0 0\nouter loop\n" + face.map { "vertex \($0.x) \($0.y) \($0.z)\n" }.joined() + "endloop\nendfacet\n"
        }
        XCTAssertThrowsError(try MeshImport.read(try temporary(Data(text.utf8), "open.stl"), name: "open"))
        XCTAssertThrowsError(try MeshImport.read(try temporary(Data("not a mesh".utf8), "junk.stl"), name: "junk"))
    }
}
