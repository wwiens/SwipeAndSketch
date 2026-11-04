import XCTest
import simd
@testable import SwipeAndSketchCore

/// Print-ready 3MF: named parts, plate layout, preview picture.
final class PrintExportTests: XCTestCase {
    struct Missing: Error {}
    func unzip(_ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Missing() }
        return data
    }

    /// The package written to a temporary file, and its model's object names and item transforms.
    func read(_ data: Data) throws -> (url: URL, names: [String], transforms: [String?], model: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".3mf")
        try data.write(to: url)
        let model = String(decoding: try unzip(["-p", url.path, "3D/3dmodel.model"]), as: UTF8.self)
        final class Reader: NSObject, XMLParserDelegate {
            var names: [String] = [], transforms: [String?] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                if name == "object" { names.append(a["name"] ?? "") }
                if name == "item" { transforms.append(a["transform"]) }
            }
        }
        let reader = Reader(), parser = XMLParser(data: Data(model.utf8))
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "Well-formed XML")
        return (url, reader.names, reader.transforms, model)
    }

    func testPartsAreNamedArrangedOnThePlateAndPictured() throws {
        let base = try box(-30, -20, 30, 20, depth: 20), lid = try box(-30, -20, 30, 20, depth: 5, at: 20)
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let data = try ModelExport.threeMF([.init(body: base, name: "Box"), .init(body: lid, name: "Lid & <Cap>")], title: "Enclosure",
                                           layout: PrintLayout(placement: .arranged, bed: [256, 256]), thumbnail: picture)
        let file = try read(data)
        XCTAssertEqual(file.names, ["Box", "Lid & <Cap>"])
        XCTAssertTrue(file.model.contains("name=\"Lid &amp; &lt;Cap&gt;\""))
        XCTAssertTrue(file.model.contains("<metadata name=\"CreationDate\">"))
        // Side by side: both rest on the plate (z moves by -min z), the lid moved up off the box.
        let moves = try file.transforms.map { try XCTUnwrap($0).split(separator: " ").compactMap { Double($0) } }
        XCTAssertEqual(moves.map { $0.count }, [12, 12])
        XCTAssertEqual(moves[0][11], 0, accuracy: 1e-9)
        XCTAssertEqual(moves[1][11], -20, accuracy: 1e-9)
        // Centered on the plate with 5 mm between them: 60 + 5 + 60 wide.
        let leftEdge = moves.map { $0[9] - 30 }.min()!, rightEdge = moves.map { $0[9] + 30 }.max()!
        XCTAssertEqual(leftEdge, 128 - 62.5, accuracy: 1e-6)
        XCTAssertEqual(rightEdge, 128 + 62.5, accuracy: 1e-6)
        XCTAssertEqual(moves[0][10] + 0, 128, accuracy: 1e-6, "Centered front to back")
        // The picture is in the package and linked as its thumbnail.
        XCTAssertEqual(try unzip(["-p", file.url.path, "Metadata/thumbnail.png"]), picture)
        let rels = String(decoding: try unzip(["-p", file.url.path, "_rels/.rels"]), as: UTF8.self)
        XCTAssertTrue(rels.contains("metadata/thumbnail"))
        let types = String(decoding: try unzip(["-p", file.url.path, "\\[Content_Types\\].xml"]), as: UTF8.self)
        XCTAssertTrue(types.contains("image/png"))
    }

    func testColoredSolidsCarryTheirColorAsBaseMaterials() throws {
        var red = try box(-30, -20, 0, 20, depth: 10), gray = try box(0, -20, 30, 20, depth: 10)
        red.color = .red
        let file = try read(try ModelExport.threeMF([.init(body: red, name: "Red"), .init(body: gray, name: "Gray")], title: "Colors",
                                                    layout: nil, thumbnail: nil))
        XCTAssertTrue(file.model.contains("<basematerials id=\"3\">"))
        XCTAssertTrue(file.model.contains("<base name=\"Gray\" displaycolor=\"#9E9E9EFF\"/>"))
        XCTAssertTrue(file.model.contains("<base name=\"Red\" displaycolor=\"#DB3833FF\"/>"))
        XCTAssertTrue(file.model.contains("name=\"Red\" pid=\"3\" pindex=\"1\""))
        XCTAssertTrue(file.model.contains("name=\"Gray\" pid=\"3\" pindex=\"0\""))
        // Without colors, no materials at all.
        let plain = try read(try ModelExport.threeMF([.init(body: gray, name: "Gray")], title: "Plain", layout: nil, thumbnail: nil))
        XCTAssertFalse(plain.model.contains("basematerials"))
    }

    func testAsModeledKeepsTheGroupTogetherOnThePlate() throws {
        let base = try box(-30, -20, 30, 20, depth: 20), lid = try box(-30, -20, 30, 20, depth: 5, at: 20)
        let boxes = [(min: SIMD3<Double>(-30, -20, -10), max: SIMD3<Double>(30, 20, 10)), (min: SIMD3<Double>(-30, -20, 10), max: SIMD3<Double>(30, 20, 15))]
        let result = PrintLayout.Placement.offsets(for: boxes, layout: PrintLayout(placement: .asModeled, bed: [250, 210]))
        XCTAssertEqual(result.offsets[0], result.offsets[1], "One move for the whole group")
        XCTAssertEqual(result.offsets[0], SIMD3(125, 105, 10))
        XCTAssertTrue(result.fits)
        let file = try read(try ModelExport.threeMF([.init(body: base, name: "Box"), .init(body: lid, name: "Lid")], title: "T",
                                                    layout: PrintLayout(placement: .asModeled, bed: [256, 256]), thumbnail: nil))
        XCTAssertEqual(file.transforms, ["1 0 0 0 1 0 0 0 1 128.0 128.0 0", "1 0 0 0 1 0 0 0 1 128.0 128.0 0"])
        XCTAssertThrowsError(try unzip(["-p", file.url.path, "Metadata/thumbnail.png"]), "No picture unless given") { _ in }
    }

    func testTooManyPartsAreReportedAsNotFitting() {
        let big = (min: SIMD3<Double>(0, 0, 0), max: SIMD3<Double>(150, 150, 10))
        let result = PrintLayout.Placement.offsets(for: [big, big, big, big, big], layout: PrintLayout(placement: .arranged, bed: [256, 256]))
        XCTAssertFalse(result.fits)
        XCTAssertTrue(PrintLayout.Placement.offsets(for: [big], layout: PrintLayout()).fits)
        // Each part keeps its own spot: none overlap.
        let spots = result.offsets.map { SIMD2($0.x, $0.y) }
        for i in spots.indices { for j in spots.indices where i < j { XCTAssertGreaterThanOrEqual(simd_distance(spots[i], spots[j]), 150) } }
    }
}
