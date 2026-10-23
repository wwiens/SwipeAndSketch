import XCTest
import simd
@testable import SwipeAndSketchCore

/// Scale: solids keep a scale step, sketches are scaled in their plane.
final class ScaleTests: XCTestCase {
    func workspace() throws -> (Workspace, UUID, UUID) {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))
        let profile = try XCTUnwrap(Geometry.profiles(in: [rectangle], on: .top).first)
        let body = SolidBody(profile: profile, depth: 10)
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 45, y: 0))
        var space = Workspace(shapes: [circle], bodies: [body])
        space.normalizeSketches()
        return (space, body.id, try XCTUnwrap(space.sketches.first?.id))
    }

    func testUniformScaleAboutTheBaseKeepsTheSolidOnThePlate() throws {
        let (space, bodyID, _) = try workspace()
        let axes = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0)]
        let result = try XCTUnwrap(Scaling.scale(space, bodies: [bodyID], sketches: [], about: SIMD3(10, 5, 0), axes: axes,
                                                 factors: SIMD3(repeating: 1.5), copy: false))
        let body = try XCTUnwrap(result.workspace.bodies.first)
        XCTAssertEqual(body.id, bodyID)
        XCTAssertEqual(body.cuts.last?.operation, .scale)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertEqual(solid.volume, 2000 * 3.375, accuracy: 1e-6)
        XCTAssertEqual(solid.bounds.min.z, 0, accuracy: 1e-9)
        XCTAssertEqual(solid.bounds.max.x, 25, accuracy: 1e-9)
        XCTAssertEqual(body.baseScale ?? 0, 1.5, accuracy: 1e-12)
        // It still moves and mirrors as one solid.
        let moved = try XCTUnwrap(body.transformed(by: .move(SIMD3(0, 0, 7))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).bounds.min.z, 7, accuracy: 1e-9)
        let image = try XCTUnwrap(body.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try SolidKernel.solid(for: image).bounds.min.x, -25, accuracy: 1e-9)
    }

    func testStretchAlongOneAxisAndCopies() throws {
        let (space, bodyID, _) = try workspace()
        let result = try XCTUnwrap(Scaling.scale(space, bodies: [bodyID], sketches: [], about: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                                 factors: SIMD3(1, 1, 2), copy: true))
        XCTAssertEqual(result.workspace.bodies.count, 2, "The original stays")
        let copy = try XCTUnwrap(result.workspace.bodies.last)
        XCTAssertNotEqual(copy.id, bodyID)
        XCTAssertEqual(try SolidKernel.solid(for: copy).bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertNil(copy.baseScale, "A stretch has no single factor")
    }

    func testSketchesScaleInTheirPlaneOnlyByOneFactor() throws {
        let (space, _, sketchID) = try workspace()
        let result = try XCTUnwrap(Scaling.scale(space, bodies: [], sketches: [sketchID], about: SIMD3(40, 0, 0), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                                 factors: SIMD3(repeating: 2), copy: false))
        let circle = try XCTUnwrap(result.workspace.shapes.first)
        let plane = circle.plane
        XCTAssertEqual(simd_distance(plane.point(circle.start), SIMD3(40, 0, 0)), 0, accuracy: 1e-9, "The center stays put")
        XCTAssertEqual(ShapeDimension.diameter.value(of: circle), 20, accuracy: 1e-9)
        XCTAssertNil(Scaling.scale(space, bodies: [], sketches: [sketchID], about: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                   factors: SIMD3(1, 2, 1), copy: false))
    }

    func testAfterAScaleLaterStepsAreNotScaled() throws {
        let (space, bodyID, _) = try workspace()
        var body = try XCTUnwrap(Scaling.scale(space, bodies: [bodyID], sketches: [], about: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                               factors: SIMD3(repeating: 2), copy: false)?.workspace.bodies.first)
        // A 4 mm hole through the top after scaling stays 4 mm.
        let top = SketchPlane(origin: SIMD3(0, 0, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        body.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: 4), at: .init(x: 20, y: 10), on: top, depth: nil)))
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 16_000 - .pi * 4 * 20, accuracy: 1e-3)
        XCTAssertEqual(body.scaleFactor(after: body.cuts.count - 1), 1)
        XCTAssertEqual(body.scaleFactor(after: -1), 2)
    }
}
