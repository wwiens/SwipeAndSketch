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

    func testAFlatFaceMeasuresToTheFaceBehindWhereItWasTapped() throws {
        // A 100 × 60 plate with a window at x 60–80, y 10–30: its left end measures to the window
        // when tapped beside it and to the far end when tapped past it.
        var plate = try body(SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 100, y: 60)), depth: 5)
        let top = SketchPlane(origin: SIMD3(0, 0, 5), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let window = SketchShape(kind: .rectangle, plane: top, start: .init(x: 60, y: 10), end: .init(x: 80, y: 30))
        plate.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [window], on: top).first), depth: -10))
        let solid = try SolidKernel.solid(for: plate)
        let left = try XCTUnwrap(solid.face(containing: SIMD3(0, 30, 2.5), normal: SIMD3(-1, 0, 0)))
        XCTAssertEqual(FaceEditing.size(of: left, on: solid, at: SIMD3(0, 20, 2.5))?.value ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(FaceEditing.size(of: left, on: solid, at: SIMD3(0, 50, 2.5))?.value ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(FaceEditing.size(of: left, on: solid)?.value ?? 0, 60, accuracy: 1e-9, "Without a point, the nearest plane")
        let longer = try XCTUnwrap(FaceEditing.resizing(plate, face: left, at: SIMD3(0, 50, 2.5), to: 120))
        XCTAssertEqual(try SolidKernel.solid(for: longer).bounds.min.x, -20, accuracy: 1e-6, "Measured to the far end")
        let source = try XCTUnwrap(FaceExtrusionSource(body: plate, face: left, tapped: SIMD3(0, 50, 2.5)))
        XCTAssertEqual(source.size ?? 0, 100, accuracy: 1e-9)
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

    func testAFaceOffsetRecordsHowItWasBuiltAndRebuildsTheSameWay() throws {
        let body = try box()
        let raised = try XCTUnwrap(FaceEditing.offsetting(faces: [SIMD3(10, 5, 10)], by: 3, of: body))
        let step = try XCTUnwrap(raised.cuts.last)
        XCTAssertEqual(step.movedFaces?.intersection, false, "Extending the neighbours is tried first")
        XCTAssertEqual(try SolidKernel.solid(for: raised).volume, 20 * 10 * 13, accuracy: 1e-6)
        // Rebuilt from the saved step (no deadline), and through a save and reload.
        let rebuilt = try SolidKernel.applyFaceOffset(step, to: SolidKernel.solid(for: body), of: body)
        XCTAssertEqual(rebuilt.volume, 20 * 10 * 13, accuracy: 1e-6)
        let reloaded = try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: Workspace(bodies: [raised]))))
        XCTAssertEqual(reloaded.workspace.bodies.first?.cuts.last?.movedFaces?.intersection, false)
        // A step saved before the mode was recorded still reads and rebuilds.
        var older = step
        older.movedFaces?.intersection = nil
        let decoded = try JSONDecoder().decode(ExtrusionCut.self, from: JSONEncoder().encode(older))
        XCTAssertNil(decoded.movedFaces?.intersection)
        XCTAssertEqual(try SolidKernel.applyFaceOffset(decoded, to: SolidKernel.solid(for: body), of: body).volume, 20 * 10 * 13, accuracy: 1e-6)
    }

    func testLargeGridfinityPlateDepthResizeChangesItsTrim() throws {
        let plate = try Gridfinity.plate(columns: 6, rows: 6, magnets: false)
        let solid = try SolidKernel.solid(for: plate)
        let point = SIMD3<Double>(0, 126, 1.5)
        let face = try XCTUnwrap(solid.face(containing: point, normal: SIMD3(0, 1, 0)))
        XCTAssertGreaterThan(solid.faceCount, 64)
        let size = try XCTUnwrap(FaceEditing.size(of: face, on: solid, at: point)).value
        let started = ContinuousClock.now
        let resized = try XCTUnwrap(FaceEditing.resizing(plate, face: face, at: point, to: size + 5))
        let built = try SolidKernel.solid(for: resized)
        XCTAssertLessThan(started.duration(to: .now), .seconds(15), "Must not enter the complete-intersection stall")
        XCTAssertTrue(built.isValidSolid)
        XCTAssertEqual(built.bounds.max.y, 131, accuracy: 1e-5)
        XCTAssertEqual(built.bounds.min.y, -126, accuracy: 1e-5)
        XCTAssertGreaterThan(built.volume, solid.volume)
        XCTAssertEqual(resized.cuts.count, plate.cuts.count, "Edit the trim instead of adding an offset")
        XCTAssertEqual(resized.cuts.last?.operation, .cut)
        XCTAssertEqual(Array(resized.cuts.dropLast()), Array(plate.cuts.dropLast()), "All pocket geometry stays fixed")
    }

    func testMaximumMagnetPlateCanShrinkFromItsNegativeSideAndReload() throws {
        let plate = try Gridfinity.plate(columns: 8, rows: 8, magnets: true)
        let solid = try SolidKernel.solid(for: plate)
        let point = SIMD3<Double>(0, -168, 4.5)
        let face = try XCTUnwrap(solid.face(containing: point, normal: SIMD3(0, -1, 0)))
        let size = try XCTUnwrap(FaceEditing.size(of: face, on: solid, at: point)).value
        let resized = try XCTUnwrap(FaceEditing.resizing(plate, face: face, at: point, to: size - 0.1))
        let built = try SolidKernel.solid(for: resized)
        XCTAssertTrue(built.isValidSolid)
        XCTAssertEqual(built.bounds.min.y, -167.9, accuracy: 1e-5)
        XCTAssertEqual(built.bounds.max.y, 168, accuracy: 1e-5)
        XCTAssertEqual(Array(resized.cuts.dropLast()), Array(plate.cuts.dropLast()))
        let project = Project(workspace: Workspace(bodies: [resized]))
        let reloaded = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(reloaded.workspace.bodies, [resized])
        let moved = try XCTUnwrap(resized.transformed(by: .move(SIMD3(10, 20, 30))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, built.volume, accuracy: 1e-3)
    }
}
