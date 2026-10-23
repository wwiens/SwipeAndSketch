import XCTest
import simd
@testable import SwipeAndSketchCore

/// Extrude options: symmetric and tapered solids, cuts, and joins.
final class ExtrudeOptionsTests: XCTestCase {
    func square(_ half: Double = 10, on plane: SketchPlane = .top) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: .rectangle, plane: plane, start: .init(x: -half, y: -half), end: .init(x: half, y: half))], on: plane).first)
    }

    func testSymmetricSolidsKeepTheirNamedFacesAndEdges() throws {
        var body = SolidBody(profile: try square(), depth: 10)
        body.symmetric = true
        XCTAssertTrue(body.isValid)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertEqual(solid.bounds.min.z, -5, accuracy: 1e-9)
        XCTAssertEqual(solid.bounds.max.z, 5, accuracy: 1e-9)
        // A cap edge is named, so a fillet on it is saved by name and follows depth edits.
        let edge = try XCTUnwrap(solid.edge(near: SIMD3(0, -10, 5)))
        XCTAssertEqual(body.edgeNames([edge], of: solid).first??.position, .cap)
        var rounded = try XCTUnwrap(body.finishing(.fillet, edges: [edge], size: 2))
        XCTAssertEqual(rounded.finishes.count, 1, "By name")
        rounded.depth = 20
        XCTAssertEqual(try SolidKernel.solid(for: rounded).bounds.max.z, 10, accuracy: 1e-9)
        let top = try XCTUnwrap(solid.face(containing: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(body.extrusionFace(top, of: solid), ExtrusionFace(position: .cap, index: 0))
        // Encodes only when set, and round-trips.
        let data = try JSONEncoder().encode(body)
        XCTAssertEqual(try JSONDecoder().decode(SolidBody.self, from: data), body)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(SolidBody(profile: try square(), depth: 10)), as: UTF8.self).contains("symmetric"))
    }

    func testTaperedSolidsAndSymmetricTapers() throws {
        var body = SolidBody(profile: try square(), depth: 5)
        body.taper = 45
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 5.0 / 3 * (400 + 100 + 200), accuracy: 1e-3)
        body.symmetric = true
        body.depth = 10
        // Two frustums back to back, each 5 mm tall.
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 2 * 5.0 / 3 * (400 + 100 + 200), accuracy: 1e-3)
        body.taper = 89
        body.taper = 95
        XCTAssertFalse(body.isValid)
    }

    func testSymmetricAndTaperedCutsAndJoins() throws {
        var block = SolidBody(profile: try square(20), depth: 20)
        let middle = SketchPlane(origin: SIMD3(0, 0, 10), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        var cut = ExtrusionCut(profile: try square(5, on: middle), depth: 6)
        cut.symmetric = true
        block.cuts.append(cut)
        XCTAssertTrue(block.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: block).volume, 40 * 40 * 20 - 10 * 10 * 6, accuracy: 1e-6)
        var through = ExtrusionCut(profile: try square(5, on: middle), depth: 6, throughAll: true)
        through.symmetric = true
        XCTAssertFalse(through.isValid, "Through All has no options")
        let top = SketchPlane(origin: SIMD3(0, 0, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        var boss = ExtrusionCut(profile: try square(5, on: top), depth: 4, operation: .join)
        boss.taper = 30
        var bossed = SolidBody(profile: try square(20), depth: 20)
        bossed.cuts.append(boss)
        XCTAssertEqual(try SolidKernel.solid(for: bossed).bounds.max.z, 24, accuracy: 1e-9)
        XCTAssertLessThan(try SolidKernel.solid(for: bossed).volume, 40 * 40 * 20 + 10 * 10 * 4)
    }
}
