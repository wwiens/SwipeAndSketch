import XCTest
import simd
@testable import SwipeAndSketchCore

/// Delete Face on a solid with many holes sets the holes standing apart aside, removes the faces
/// from what is left, and puts the holes back (November 11, 2026). The solid must be the one the
/// feature would never have made: the same volume, faces, edges, and validity.
final class DeleteFaceApartTests: XCTestCase {
    private let top = SketchPlane(origin: SIMD3(0, 0, 8), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))

    /// 42 hexagon holes through an 8 mm plate, 100 × 80 mm (252 faces).
    private func honeycomb() throws -> [ExtrusionCut] {
        var cuts: [ExtrusionCut] = []
        for row in 0..<6 { for column in 0..<7 {
            let center = Point2(x: -36 + Double(column) * 12 + (row % 2 == 0 ? 0 : 6), y: -30 + Double(row) * 12)
            let lines = SketchTools.polygon(center: center, vertex: Point2(x: center.x + 3, y: center.y), sides: 6, plane: top)
            cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: lines, on: top).first), depth: -8, throughAll: true))
        } }
        return cuts
    }

    private func circle(_ x: Double, _ y: Double, radius: Double, depth: Double) throws -> ExtrusionCut {
        let shape = SketchShape(kind: .circle, plane: top, start: Point2(x: x, y: y), end: Point2(x: x + radius, y: y))
        return ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: top).first), depth: depth, throughAll: depth <= -8)
    }

    private func plate() throws -> SolidBody { try box(-50, -40, 50, 40, depth: 8) }

    private func assertSame(_ body: SolidBody, deleting points: [SIMD3<Double>], as expected: SolidBody,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let deleted = try XCTUnwrap(FaceEditing.deleting(faces: points, of: body), "Faces deleted", file: file, line: line)
        let a = try SolidKernel.solid(for: deleted), b = try SolidKernel.solid(for: expected)
        XCTAssertEqual(a.volume, b.volume, accuracy: 1e-6 * b.volume, "Volume", file: file, line: line)
        XCTAssertEqual(a.faceCount, b.faceCount, "Faces", file: file, line: line)
        XCTAssertEqual(a.edgeCount, b.edgeCount, "Edges", file: file, line: line)
        XCTAssertTrue(a.isValidSolid, "Valid", file: file, line: line)
    }

    func testAHoleBesideAHoneycombIsFilled() throws {
        var expected = try plate()
        expected.cuts = try honeycomb()
        var body = expected
        body.cuts.append(try circle(45, 35, radius: 2.5, depth: -8))
        try assertSame(body, deleting: [SIMD3(47.5, 35, 4)], as: expected)
    }

    func testAPocketWithTwoFacesIsFilled() throws {
        var expected = try plate()
        expected.cuts = try honeycomb()
        var body = expected
        body.cuts.append(try circle(-45, -35, radius: 2, depth: -3))
        try assertSame(body, deleting: [SIMD3(-43, -35, 6.5), SIMD3(-45, -35, 5)], as: expected)
    }

    func testAHoleHalfAMillimeterFromAHexagonIsFilled() throws {
        // The hexagon's flat side is 2.598 mm below its center; the round hole stops 0.5 mm short of it.
        var expected = try plate()
        expected.cuts = try honeycomb()
        var body = expected
        body.cuts.append(try circle(-36, -35.098, radius: 2, depth: -8))
        try assertSame(body, deleting: [SIMD3(-34, -35.098, 4)], as: expected)
    }

    func testRoundedCornersAreSquaredOff() throws {
        var expected = try plate()
        expected.cuts = try honeycomb()
        var body = SolidBody(profile: TemplateGeometry.roundedRectangle(width: 100, depth: 80, radius: 4, on: .top), depth: 8)
        body.cuts = expected.cuts
        let corners = [SIMD2(1.0, 1.0), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)].map { side in
            SIMD3(side.x * (46 + 4 * 0.5.squareRoot()), side.y * (36 + 4 * 0.5.squareRoot()), 4)
        }
        try assertSame(body, deleting: corners, as: expected)
    }
}
