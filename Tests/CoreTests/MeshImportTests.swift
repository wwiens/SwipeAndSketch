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

    // MARK: Damaged 3MF files

    /// A 3MF holding a tetrahedron (object 1) plus `extra` model XML, and any other entries.
    func threeMF(triangles extraTriangles: String = "", objects: String = "", items: String = "<item objectid=\"1\"/>",
                 entries: [(String, Data)] = []) -> Data {
        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>
        <object id="1" type="model"><mesh><vertices>
        <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
        </vertices><triangles>
        <triangle v1="0" v2="2" v3="1"/>\(extraTriangles)<triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/>
        </triangles></mesh></object>\(objects)</resources><build>\(items)</build></model>
        """
        var zip = ZipWriter()
        zip.add("3D/3dmodel.model", Data(model.utf8))
        for (path, content) in entries { zip.add(path, content) }
        return zip.finish()
    }

    /// Marks every empty entry of `data` as deflated (method 8), as some zip tools write them.
    func deflatingEmptyEntries(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        for i in 0..<(bytes.count - 30) {
            if u32(i) == 0x0403_4b50, u32(i + 22) == 0 { bytes[i + 8] = 8 }        // local header, size 0
            if u32(i) == 0x0201_4b50, u32(i + 24) == 0 { bytes[i + 10] = 8 }       // central header, size 0
        }
        return Data(bytes)
    }

    func testAnEmptyDeflatedEntryDoesNotStopTheImport() throws {
        let data = deflatingEmptyEntries(threeMF(entries: [("Metadata/empty.txt", Data())]))
        let files = try Zip.entries(data)
        XCTAssertEqual(files["Metadata/empty.txt"], Data())
        let result = try MeshImport.read(try temporary(data, "empty-entry.3mf"), name: "tetra")
        XCTAssertEqual(try SolidKernel.solid(for: result.bodies[0]).volume, 1000.0 / 6, accuracy: 0.01)
    }

    func testATriangleWithAMissingVertexIsLeftOutWhole() throws {
        // Leaving out only its bad corner would shift every later triangle by one corner.
        let data = threeMF(triangles: "<triangle v1=\"0\" v2=\"99\" v3=\"1\"/>")
        let result = try MeshImport.read(try temporary(data, "bad-index.3mf"), name: "tetra")
        XCTAssertEqual(try SolidKernel.solid(for: result.bodies[0]).volume, 1000.0 / 6, accuracy: 0.01)
    }

    func testComponentsThatMultiplyStopEarly() throws {
        // Ten levels each placing the one below ten times: 10¹⁰ tetrahedra if followed to the end.
        var objects = ""
        for level in 2...11 {
            objects += "<object id=\"\(level)\" type=\"model\"><components>"
            objects += String(repeating: "<component objectid=\"\(level - 1)\"/>", count: 10)
            objects += "</components></object>"
        }
        let data = threeMF(objects: objects, items: "<item objectid=\"11\"/>")
        let started = Date()
        XCTAssertThrowsError(try MeshImport.threeMF(data, name: "many"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
