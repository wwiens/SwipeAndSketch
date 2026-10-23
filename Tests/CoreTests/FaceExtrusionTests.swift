import XCTest
import simd
@testable import SwipeAndSketchCore

final class FaceExtrusionTests: XCTestCase {
    /// The flat face of `body` whose outward normal is `normal`.
    func face(of body: SolidBody, normal: SIMD3<Double>) throws -> Int {
        let solid = try SolidKernel.solid(for: body)
        return try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { simd_dot($0.normal, normal) > 0.9999 } ?? false })
    }

    func testTopFacePushedOutGrowsTheSolid() throws {
        var body = try box()
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(0, 0, 1))))
        XCTAssertEqual(source.profile.plane.normalAxis, .init(0, 0, 1), "Positive depth points out of the solid")
        XCTAssertEqual(source.profile.area, 2_400, accuracy: 1e-6)
        let operation = source.operation(depth: 5)
        XCTAssertEqual(operation.operation, .join)
        body.cuts = [operation]
        XCTAssertTrue(body.isValid)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 60 * 40 * 25, accuracy: 1e-6)
        XCTAssertEqual(solid.faceCount, 6, "Coplanar sides merge, so it is still a plain box")
    }

    func testSideFacePushedInCuts() throws {
        var body = try box()
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(1, 0, 0))))
        let operation = source.operation(depth: -10)
        XCTAssertEqual(operation.operation, .cut)
        body.cuts = [operation]
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 50 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: body).bounds.max.x, 20, accuracy: 1e-9)
    }

    func testFaceWithAHoleKeepsTheHole() throws {
        var body = try box()
        let lid = try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1)))
        body.cuts = [try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.simple, size: "M3"), at: .zero, on: lid, depth: nil))]
        let drilled = try SolidKernel.solid(for: body).volume
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(0, 0, 1))))
        XCTAssertEqual(source.profile.outline.count, 4, "The profile is the outer boundary")
        XCTAssertFalse(Geometry.contains(source.point, in: [.init(x: -1.7, y: -1.7), .init(x: 1.7, y: -1.7), .init(x: 1.7, y: 1.7), .init(x: -1.7, y: 1.7)]),
                       "The point naming the face is on material, not in the hole")
        body.cuts.append(source.operation(depth: 4))
        let radius = 3.4 / 2
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, drilled + (2_400 - .pi * radius * radius) * 4, accuracy: 1e-3,
                       "The hole continues through the added material")
    }

    func testCylinderCapUsesAnExactCircle() throws {
        let shape = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 10)
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(0, 0, 1))))
        XCTAssertEqual(source.profile.circle?.radius ?? 0, 10, accuracy: 1e-9)
        body.cuts = [source.operation(depth: 5)]
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, .pi * 100 * 15, accuracy: 1e-3)
    }

    func testFaceExtrusionValidationAndRoundTrip() throws {
        var body = try box()
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(0, 0, 1))))
        var wrongSign = source.operation(depth: 5)
        wrongSign.depth = -5
        body.cuts = [wrongSign]
        XCTAssertFalse(body.isValid, "Inward is always a cut")
        var through = source.operation(depth: -5)
        through.throughAll = true
        body.cuts = [through]
        XCTAssertFalse(body.isValid, "Face extrusions always have a depth")
        body.cuts = [source.operation(depth: 5)]
        let project = Project(workspace: Workspace(bodies: [body]))
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, project.workspace)
    }

    func testMissingFaceFailsToRebuild() throws {
        var body = try box()
        let source = try XCTUnwrap(FaceExtrusionSource(body: body, face: try face(of: body, normal: .init(0, 0, 1))))
        body.cuts = [source.operation(depth: 5)]
        body.depth = 10   // the top face moved, so the stored face is gone
        XCTAssertThrowsError(try SolidKernel.solid(for: body))
    }
}
