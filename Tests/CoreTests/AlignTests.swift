import XCTest
import simd
@testable import SwipeAndSketchCore

/// Align: rigid motions that bring a feature of the moving solids onto a target.
final class AlignTests: XCTestCase {
    func face(_ body: SolidBody, normal: SIMD3<Double>) throws -> AlignFeature {
        let solid = try SolidKernel.solid(for: body)
        let index = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { simd_dot($0.normal, normal) > 0.9999 } ?? false })
        return .plane(try XCTUnwrap(PlaneReference.face(index, of: body)))
    }

    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try SolidKernel.solid(for: body).bounds }

    func testAFaceMeetsAFaceCenteredAndFlipTurnsItOver() throws {
        let cube = try box(0, 0, 10, 10, depth: 10), plate = try box(50, 0, 70, 20, depth: 5)
        let bottom = try face(cube, normal: .init(0, 0, -1)), top = try face(plate, normal: .init(0, 0, 1))
        let onTop = try XCTUnwrap(cube.transformed(by: try XCTUnwrap(Aligning.transform(from: bottom, to: top))))
        let b = try bounds(onTop)
        XCTAssertEqual(b.min.z, 5, accuracy: 1e-6, "Sits on the plate")
        XCTAssertEqual(b.max.z, 15, accuracy: 1e-6)
        XCTAssertEqual((b.min.x + b.max.x) / 2, 60, accuracy: 1e-6, "Centered on the face")
        XCTAssertEqual((b.min.y + b.max.y) / 2, 10, accuracy: 1e-6)
        let flipped = try XCTUnwrap(cube.transformed(by: try XCTUnwrap(Aligning.transform(from: bottom, to: top, flip: true))))
        XCTAssertEqual(try bounds(flipped).min.z, -5, accuracy: 1e-6, "Turned over, into the plate")
        let lifted = try XCTUnwrap(cube.transformed(by: try XCTUnwrap(Aligning.transform(from: bottom, to: top, offset: 2, angle: 45))))
        XCTAssertEqual(try bounds(lifted).min.z, 7, accuracy: 1e-6, "Offset along the target's normal")
        XCTAssertEqual(try bounds(lifted).max.x - bounds(lifted).min.x, 10 * 2.squareRoot(), accuracy: 1e-6, "Turned 45° about it")
    }

    func testCornerToCornerOnlyMovesTheSolid() throws {
        let cube = try box(0, 0, 10, 10, depth: 10), plate = try box(50, 0, 70, 20, depth: 5)
        let cubeCorners = AlignFeature.corners(of: cube), plateCorners = AlignFeature.corners(of: plate)
        XCTAssertEqual(cubeCorners.count, 8)
        XCTAssertEqual(plateCorners.count, 8)
        // The cube's bottom-front-left corner onto the plate's top-back-right corner.
        let from = AlignFeature.point(.init(0, 0, 0), source: .vertex(cube.id, .init(0, 0, 0)))
        let to = AlignFeature.point(.init(70, 20, 5), source: .vertex(plate.id, .init(70, 20, 5)))
        XCTAssertTrue(cubeCorners.contains(from.point)); XCTAssertTrue(plateCorners.contains(to.point))
        let motion = try XCTUnwrap(Aligning.transform(from: from, to: to, flip: true, offset: 3, angle: 45))
        XCTAssertEqual(motion, .move(.init(70, 20, 5)), "Points only move: flip, offset, and angle do not apply")
        let b = try bounds(try XCTUnwrap(cube.transformed(by: motion)))
        XCTAssertEqual(b.min, .init(70, 20, 5))
        XCTAssertEqual(b.max, .init(80, 30, 15))
        // A point goes only to a point.
        XCTAssertNil(Aligning.transform(from: from, to: try face(plate, normal: .init(0, 0, 1))))
    }

    func testRoundSolidsHaveNoCornersAndSketchShapesHavePoints() throws {
        let disc = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let cylinder = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [disc], on: .top).first), depth: 10)
        XCTAssertTrue(AlignFeature.corners(of: cylinder).isEmpty, "A rim's seam vertex is not a corner")
        XCTAssertEqual(AlignFeature.points(of: disc), [.zero], "A circle offers its center")
        let line = SketchShape(kind: .line, plane: .front, start: .init(x: 1, y: 2), end: .init(x: 3, y: 4))
        XCTAssertEqual(AlignFeature.points(of: line), [.init(1, 0, 2), .init(3, 0, 4)])
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 4, y: 3))
        XCTAssertEqual(Set(AlignFeature.points(of: rectangle)), [.init(0, 0, 0), .init(4, 0, 0), .init(4, 3, 0), .init(0, 3, 0)])
    }

    func testAPlaneTargetKeepsThePositionAlongIt() throws {
        let floating = try box(5, 5, 15, 15, depth: 10, at: 20)
        let bottom = try face(floating, normal: .init(0, 0, -1))
        let moved = try XCTUnwrap(floating.transformed(by: try XCTUnwrap(Aligning.transform(from: bottom, to: .plane(.world(.top))))))
        let b = try bounds(moved)
        XCTAssertEqual(b.min.z, 0, accuracy: 1e-6, "Down onto Top")
        XCTAssertEqual(b.min.x, 5, accuracy: 1e-6, "Not moved along it")
    }

    func testCirclesBecomeConcentricAndLinesCollinear() throws {
        let rod = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 3, y: 0))
        let cylinder = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [rod], on: .top).first), depth: 10)
        let solid = try SolidKernel.solid(for: cylinder)
        let topRim = try XCTUnwrap((0..<solid.edgeCount).compactMap { AlignFeature.edge($0, of: cylinder) }.first { $0.kind == .circle && $0.point.z > 9 })
        // A circle on Front, centered at (40, 0, 25): its axis is −y.
        let ring = try XCTUnwrap(AlignFeature.shape(SketchShape(kind: .circle, plane: .front, start: .init(x: 40, y: 25), end: .init(x: 45, y: 25))))
        let moved = try XCTUnwrap(cylinder.transformed(by: try XCTUnwrap(Aligning.transform(from: topRim, to: ring))))
        let b = try bounds(moved)
        XCTAssertEqual((b.min.x + b.max.x) / 2, 40, accuracy: 1e-6)
        XCTAssertEqual((b.min.z + b.max.z) / 2, 25, accuracy: 1e-6)
        XCTAssertEqual(b.max.y - b.min.y, 10, accuracy: 1e-6, "Its axis now runs along y")
        XCTAssertEqual(max(abs(b.min.y), abs(b.max.y)), 10, accuracy: 1e-6, "The rim sits on the circle")
        // A box's bottom front edge onto a diagonal sketch line.
        let block = try box(0, 0, 20, 10, depth: 5)
        let edges = try SolidKernel.solid(for: block)
        let edge = try XCTUnwrap((0..<edges.edgeCount).compactMap { AlignFeature.edge($0, of: block) }.first {
            $0.kind == .line && abs($0.point.y) < 1e-9 && abs($0.point.z) < 1e-9
        })
        let line = try XCTUnwrap(AlignFeature.shape(SketchShape(kind: .line, plane: .top, start: .init(x: 100, y: 100), end: .init(x: 130, y: 130))))
        let placed = try XCTUnwrap(block.transformed(by: try XCTUnwrap(Aligning.transform(from: edge, to: line))))
        let placedSolid = try SolidKernel.solid(for: placed)
        let moved2 = (0..<placedSolid.edgeCount).compactMap { AlignFeature.edge($0, of: placed) }
        XCTAssertTrue(moved2.contains { $0.kind == .line && simd_distance($0.point, .init(115, 115, 0)) < 1e-6 &&
            abs(abs(simd_dot($0.direction, simd_normalize(SIMD3(1, 1, 0)))) - 1) < 1e-9 }, "The edge lies along the line, midpoint to midpoint")
        XCTAssertNil(Aligning.transform(from: edge, to: ring), "Kinds must match")
    }
}
