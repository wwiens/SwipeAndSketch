import XCTest
import simd
@testable import SwipeAndSketchCore

/// Delete Face, Offset Face, and sizes changed from a selected face.
final class FaceEditTests: XCTestCase {
    func body(_ shape: SketchShape, depth: Double = 10) throws -> SolidBody {
        SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: shape.plane).first), depth: depth)
    }
    func box() throws -> SolidBody { try body(SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))) }
    func roundFace(_ solid: KernelSolid) throws -> Int { try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil }) }

    func testACylindersDiameterChangesItsOwnCircle() throws {
        let cylinder = try body(SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0)))
        let solid = try SolidKernel.solid(for: cylinder)
        let face = try roundFace(solid)
        XCTAssertEqual(FaceEditing.size(of: face, on: solid), .diameter(10, side: 1))
        let wider = try XCTUnwrap(FaceEditing.resizing(cylinder, face: face, at: SIMD3(5, 0, 5), to: 16))
        XCTAssertEqual(wider.profile.circle?.radius ?? 0, 8, accuracy: 1e-12, "Stored in the solid's own circle")
        XCTAssertTrue(wider.cuts.isEmpty)
        XCTAssertEqual(try SolidKernel.solid(for: wider).volume, .pi * 64 * 10, accuracy: 1e-6)
    }

    func testAHolesDiameterChangesTheHoleOrCut() throws {
        var plate = try box()
        let top = SketchPlane(origin: SIMD3(0, 0, 10), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        plate.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .init(x: 10, y: 5), on: top, depth: nil)))
        let solid = try SolidKernel.solid(for: plate)
        let face = try roundFace(solid)
        guard case .diameter(let d, let side) = FaceEditing.size(of: face, on: solid) else { return XCTFail("A round face") }
        XCTAssertEqual(side, -1, "A hole")
        let bigger = try XCTUnwrap(FaceEditing.resizing(plate, face: face, at: SIMD3(10 + d / 2, 5, 5), to: 5))
        XCTAssertEqual(bigger.cuts.count, 1, "The hole changed in place")
        XCTAssertEqual(bigger.cuts[0].hole?.diameter ?? 0, 5, accuracy: 1e-12)
        XCTAssertEqual(try SolidKernel.solid(for: bigger).volume, 2000 - .pi * 6.25 * 10, accuracy: 1e-3)
        // A cut circle, the same way.
        var cut = try box()
        let circle = SketchShape(kind: .circle, plane: top, start: .init(x: 10, y: 5), end: .init(x: 12, y: 5))
        cut.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: top).first), depth: -4))
        let cutSolid = try SolidKernel.solid(for: cut)
        let wall = try roundFace(cutSolid)
        let wider = try XCTUnwrap(FaceEditing.resizing(cut, face: wall, at: SIMD3(12, 5, 8), to: 6))
        XCTAssertEqual(wider.cuts[0].profile.circle?.radius ?? 0, 3, accuracy: 1e-12)
    }

    func testABoxsWidthAndHeightChangeItsProfileAndDepth() throws {
        let block = try box()
        let solid = try SolidKernel.solid(for: block)
        let right = try XCTUnwrap(solid.face(containing: SIMD3(20, 5, 5), normal: SIMD3(1, 0, 0)))
        XCTAssertEqual(FaceEditing.size(of: right, on: solid)?.value ?? 0, 20, accuracy: 1e-9)
        let wider = try XCTUnwrap(FaceEditing.resizing(block, face: right, at: SIMD3(20, 5, 5), to: 32))
        XCTAssertTrue(wider.cuts.isEmpty, "The profile's side moved")
        XCTAssertEqual(try SolidKernel.solid(for: wider).bounds.max.x, 32, accuracy: 1e-9)
        XCTAssertEqual(try SolidKernel.solid(for: wider).bounds.min.x, 0, accuracy: 1e-9)
        let top = try XCTUnwrap(solid.face(containing: SIMD3(10, 5, 10), normal: SIMD3(0, 0, 1)))
        let taller = try XCTUnwrap(FaceEditing.resizing(block, face: top, at: SIMD3(10, 5, 10), to: 25))
        XCTAssertEqual(taller.depth, 25)
        // The base moves by an Offset Face step instead (the sketch plane stays put).
        let bottom = try XCTUnwrap(solid.face(containing: SIMD3(10, 5, 0), normal: SIMD3(0, 0, -1)))
        let deeper = try XCTUnwrap(FaceEditing.resizing(block, face: bottom, at: SIMD3(10, 5, 0), to: 14))
        XCTAssertEqual(deeper.cuts.last?.operation, .offsetFace)
        XCTAssertEqual(try SolidKernel.solid(for: deeper).bounds.min.z, -4, accuracy: 1e-6)
    }

    func testAnUnnamedRoundFaceIsResizedByOffsetFaceAndFollowsMovesAndMirrors() throws {
        // A cylinder united onto a box: the boss's side is not in the box's own definition.
        var block = try box()
        let boss = try body(SketchShape(kind: .circle, plane: SketchPlane(origin: SIMD3(0, 0, 10), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
                                        start: .init(x: 10, y: 5), end: .init(x: 13, y: 5)), depth: 5)
        block.cuts.append(.merge(boss))
        let solid = try SolidKernel.solid(for: block)
        let face = try roundFace(solid)
        let wider = try XCTUnwrap(FaceEditing.resizing(block, face: face, at: SIMD3(13, 5, 12), to: 8))
        XCTAssertEqual(wider.cuts.count, 2)
        XCTAssertEqual(wider.cuts.last?.operation, .offsetFace)
        let built = try SolidKernel.solid(for: wider)
        XCTAssertEqual(built.volume, 2000 + .pi * 16 * 5, accuracy: 1e-3)
        let moved = try XCTUnwrap(wider.transformed(by: .move(SIMD3(100, 0, 0))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, built.volume, accuracy: 1e-6)
        let image = try XCTUnwrap(wider.mirrored(by: try XCTUnwrap(Reflection(across: .front))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, built.volume, accuracy: 1e-6)
    }

    func testDeletedFacesFollowTheSolid() throws {
        var plate = try box()
        let top = SketchPlane(origin: SIMD3(0, 0, 10), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        plate.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .init(x: 10, y: 5), on: top, depth: nil)))
        let solid = try SolidKernel.solid(for: plate)
        let wall = try roundFace(solid)
        let radius = try XCTUnwrap(solid.faceCylinder(wall)).radius
        let filled = try XCTUnwrap(FaceEditing.deleting(faces: [SIMD3(10 + radius, 5, 5)], of: plate))
        XCTAssertEqual(try SolidKernel.solid(for: filled).volume, 2000, accuracy: 1e-6)
        let image = try XCTUnwrap(filled.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, 2000, accuracy: 1e-6)
        XCTAssertNil(FaceEditing.deleting(faces: [SIMD3(10, 5, 10)], of: try box()), "A box's top cannot be taken off and closed")
    }
}
