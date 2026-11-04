import XCTest
import simd
@testable import SwipeAndSketchCore

/// Split Body: one solid becomes pieces that add up to it, nothing removed.
final class SplitTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top (x −30…30, y −20…20, z 0…20).
    func box() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
    }

    func plane(_ point: SIMD3<Double>, _ normal: SIMD3<Double>) -> SplitTool {
        SplitTool(source: .world(SketchPlane.through(point, normal: normal)!), plane: SketchPlane.through(point, normal: normal)!)
    }

    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func testAPlaneSplitsABoxIntoTwoHalvesThatAddUp() throws {
        let body = try box()
        let pieces = try XCTUnwrap(Splitting.pieces(of: body, with: [plane(.init(10, 0, 0), .init(1, 0, 0))]))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(try volume(pieces[0]), 20 * 40 * 20, accuracy: 1e-6, "In front of the plane: x 10…30")
        XCTAssertEqual(try volume(pieces[1]), 40 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: pieces[0]).bounds.min.x, 10, accuracy: 1e-6)
        XCTAssertTrue(pieces.allSatisfy { $0.id != body.id && $0.isValid && $0.cuts.last?.split != nil })
        XCTAssertTrue(try pieces.allSatisfy { try SolidKernel.solid(for: $0).isValidSolid })
    }

    func testAToolThatMissesLeavesTheSolidWhole() throws {
        XCTAssertNil(Splitting.pieces(of: try box(), with: [plane(.init(100, 0, 0), .init(1, 0, 0))]))
        // On a face, nothing is on the far side.
        XCTAssertNil(Splitting.pieces(of: try box(), with: [plane(.init(0, 0, 20), .init(0, 0, 1))]))
    }

    func testAnLShapeSplitsAlongItsOwnInnerFace() throws {
        let points = [Point2(x: 0, y: 0), .init(x: 40, y: 0), .init(x: 40, y: 10), .init(x: 10, y: 10), .init(x: 10, y: 30), .init(x: 0, y: 30)]
        let lines = points.indices.map { SketchShape(kind: .line, plane: .top, start: points[$0], end: points[($0 + 1) % points.count]) }
        let body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: lines, on: .top).first), depth: 5)
        let solid = try SolidKernel.solid(for: body)
        // The inner face at x = 10, facing +x.
        let face = try XCTUnwrap((0..<solid.faceCount).first {
            guard let plane = solid.facePlane($0) else { return false }
            return plane.normal.x > 0.99 && abs(plane.origin.x - 10) < 1e-6
        })
        let tool = try XCTUnwrap(SplitTool.reference(try XCTUnwrap(PlaneReference.face(face, of: body)), in: Workspace(bodies: [body])))
        let pieces = try XCTUnwrap(Splitting.pieces(of: body, with: [tool]))
        XCTAssertEqual(Set(try pieces.map { (try volume($0)).rounded() }), [30 * 10 * 5, 10 * 30 * 5])
    }

    func testARegionSplitsOutItsInsideAndSeveralToolsMakeMorePieces() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let region = SplitTool(source: .profile(circle.id.uuidString), plane: .top, profile: Geometry.profiles(in: [circle], on: .top).first)
        let pieces = try XCTUnwrap(Splitting.pieces(of: try box(), with: [region]))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(try volume(pieces[0]), .pi * 25 * 20, accuracy: 1e-6, "The core inside the circle")
        XCTAssertEqual(try volume(pieces[1]), 60 * 40 * 20 - .pi * 25 * 20, accuracy: 1e-6)
        // Two crossing planes quarter the box.
        let quarters = try XCTUnwrap(Splitting.pieces(of: try box(), with: [plane(.zero, .init(1, 0, 0)), plane(.zero, .init(0, 1, 0))]))
        XCTAssertEqual(quarters.count, 4)
        for quarter in quarters { XCTAssertEqual(try volume(quarter), 30 * 20 * 20, accuracy: 1e-6) }
    }

    func testASketchLineSplitsAlongThePlaneSquareToItsSketch() throws {
        let line = SketchShape(kind: .line, plane: .top, start: .init(x: -50, y: -50), end: .init(x: 50, y: 50))
        let tool = try XCTUnwrap(SplitTool.line(line))
        XCTAssertEqual(abs(tool.plane.normalAxis.z), 0, accuracy: 1e-12, "Upright, through the diagonal")
        let pieces = try XCTUnwrap(Splitting.pieces(of: try box(), with: [tool]))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(try volume(pieces[0]) + volume(pieces[1]), 60 * 40 * 20, accuracy: 1e-6)
    }

    func testSplitsRoundTripAndMoveWithTheirSolid() throws {
        let pieces = try XCTUnwrap(Splitting.pieces(of: try box(), with: [plane(.init(10, 0, 0), .init(1, 0, 0))]))
        let project = Project(workspace: Workspace(bodies: pieces))
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data), project)
        // Moving a piece carries its split plane: the same piece, 100 mm along.
        let moved = try XCTUnwrap(pieces[0].transformed(by: .move(.init(0, 100, 0))))
        XCTAssertEqual(try volume(moved), try volume(pieces[0]), accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: moved).bounds.min.y, 80, accuracy: 1e-6)
    }
}
