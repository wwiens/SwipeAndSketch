import XCTest
import simd
@testable import SwipeAndSketchCore

final class ExportTests: XCTestCase {
    func body() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        var box = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
        let hole = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 1.5, y: 0))   // an M3 clearance-size hole
        box.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true)]
        return box
    }

    func cylinder() throws -> SolidBody {
        let shape = SketchShape(kind: .circle, plane: .top, start: .init(x: 60, y: 0), end: .init(x: 70, y: 0))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 15)
    }

    /// Every undirected edge is shared by exactly two triangles, once in each direction.
    func assertManifold(_ triangles: [SIMD3<UInt32>], file: StaticString = #filePath, line: UInt = #line) {
        var directed: [UInt64: Int] = [:]
        for t in triangles { for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { directed[UInt64(a) << 32 | UInt64(b), default: 0] += 1 } }
        let bad = directed.filter { $0.value != 1 || directed[($0.key & 0xFFFF_FFFF) << 32 | ($0.key >> 32)] != 1 }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) open or non-manifold edges", file: file, line: line)
    }

    func signedVolume(_ vertices: [SIMD3<Float>], _ triangles: [SIMD3<UInt32>]) -> Double {
        triangles.reduce(0) { sum, t in
            let a = SIMD3<Double>(vertices[Int(t.x)]), b = SIMD3<Double>(vertices[Int(t.y)]), c = SIMD3<Double>(vertices[Int(t.z)])
            return sum + simd_dot(a, simd_cross(b, c)) / 6
        }
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testWeldedMeshesAreWatertightWithTheSolidsVolume() throws {
        let meshes = try ModelExport.meshes([body(), cylinder()])
        XCTAssertEqual(meshes.count, 2)
        for mesh in meshes { assertManifold(mesh.triangles) }
        XCTAssertEqual(signedVolume(meshes[0].vertices, meshes[0].triangles), 48_000 - .pi * 2.25 * 20, accuracy: 0.5)
        // Faceting within the 0.01 mm chordal tolerance: at most circumference × deflection × height.
        XCTAssertEqual(signedVolume(meshes[1].vertices, meshes[1].triangles), .pi * 100 * 15, accuracy: 2 * .pi * 10 * 0.01 * 15)
    }

    func testBinarySTLHeaderCountAndOutwardFacets() throws {
        let data = try ModelExport.stl([body(), cylinder()])
        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(data.count, 84 + Int(count) * 50)
        var vertices: [SIMD3<Float>] = [], triangles: [SIMD3<UInt32>] = []
        for t in 0..<Int(count) {
            let base = 84 + t * 50
            let floats = (0..<12).map { i in data.subdata(in: base + 4 * i..<base + 4 * i + 4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) } }
            for corner in 1...3 { vertices.append(SIMD3(floats[3 * corner], floats[3 * corner + 1], floats[3 * corner + 2])) }
            triangles.append(SIMD3(UInt32(3 * t), UInt32(3 * t + 1), UInt32(3 * t + 2)))
        }
        XCTAssertEqual(signedVolume(vertices, triangles), 48_000 - .pi * 2.25 * 20 + .pi * 100 * 15, accuracy: 12)
    }

    func testThreeMFIsAValidPackageWithOneMillimeterObjectPerSolid() throws {
        let data = try ModelExport.threeMF([body(), cylinder()], title: "Bracket & Pin")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).3mf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        func unzip(_ arguments: [String]) throws -> (status: Int32, output: Data) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }
        XCTAssertEqual(try unzip(["-tq", url.path]).status, 0, "The zip passes integrity checks")
        let listing = String(decoding: try unzip(["-Z1", url.path]).output, as: UTF8.self)
        XCTAssertEqual(Set(listing.split(separator: "\n").map(String.init)), ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"])
        let model = try unzip(["-p", url.path, "3D/3dmodel.model"]).output

        final class Reader: NSObject, XMLParserDelegate {
            var unit = "", title = "", inTitle = false
            var objects: [(vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>])] = []
            var items = 0
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                switch name {
                case "model": unit = a["unit"] ?? ""
                case "metadata": inTitle = a["name"] == "Title"
                case "object": objects.append(([], []))
                case "vertex": objects[objects.count - 1].vertices.append(SIMD3(Float(a["x"]!)!, Float(a["y"]!)!, Float(a["z"]!)!))
                case "triangle": objects[objects.count - 1].triangles.append(SIMD3(UInt32(a["v1"]!)!, UInt32(a["v2"]!)!, UInt32(a["v3"]!)!))
                case "item": items += 1
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { title += string } }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "metadata" { inTitle = false } }
        }
        let reader = Reader()
        let parser = XMLParser(data: model)
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "\(parser.parserError as Any)")
        XCTAssertEqual(reader.unit, "millimeter")
        XCTAssertEqual(reader.title, "Bracket & Pin")
        XCTAssertEqual(reader.objects.count, 2)
        XCTAssertEqual(reader.items, 2)
        for object in reader.objects { assertManifold(object.triangles) }
        XCTAssertEqual(signedVolume(reader.objects[1].vertices, reader.objects[1].triangles), .pi * 100 * 15, accuracy: 2 * .pi * 10 * 0.01 * 15)
        XCTAssertLessThan(data.count, model.count, "The model part is compressed")
    }

    func testNothingToExportFailsWithReason() {
        XCTAssertThrowsError(try ModelExport.stl([])) { error in
            XCTAssertEqual(error.localizedDescription, "There are no solids to export.")
        }
    }
}
