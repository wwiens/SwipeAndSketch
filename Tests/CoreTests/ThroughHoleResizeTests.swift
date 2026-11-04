import XCTest
import simd
@testable import SwipeAndSketchCore

final class ThroughHoleResizeTests: XCTestCase {
    func testThroughHolesStillCrossTheWholeBodyAfterItsDepthIncreases() throws {
        for plane in [SketchPlane.top, .front, .right] {
            for sign in [1.0, -1.0] {
                let rectangle = SketchShape(kind: .rectangle, plane: plane, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
                let profile = try XCTUnwrap(Geometry.profiles(in: [rectangle], on: plane).first)
                var body = SolidBody(profile: profile, depth: sign * 20)
                let entry = try XCTUnwrap(SketchPlane.through(plane.normalAxis * sign * 20, normal: plane.normalAxis * sign))
                let spec = HoleSpec(kind: .simple, size: "Ø10", diameter: 10)
                body.cuts = [try XCTUnwrap(ExtrusionCut.hole(spec, at: .zero, on: entry, depth: nil))]
                XCTAssertEqual(try SolidKernel.solid(for: body).volume, (2400 - .pi * 25) * 20, accuracy: 0.001)
                let saved = body.cuts[0]
                body.depth = sign * 30
                let solid = try SolidKernel.solid(for: body)
                XCTAssertTrue(solid.isValidSolid)
                XCTAssertEqual(solid.volume, (2400 - .pi * 25) * 30, accuracy: 0.001, "plane \(plane), sign \(sign)")
                XCTAssertEqual(body.cuts[0], saved, "Rebuild does not rewrite stored geometry or IDs")
                let roundTrip = try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: Workspace(bodies: [body]))))
                XCTAssertEqual(try SolidKernel.solid(for: roundTrip.workspace.bodies[0]).volume, solid.volume, accuracy: 0.001)
            }
        }
    }
}
