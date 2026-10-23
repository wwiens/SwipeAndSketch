import XCTest
import simd
@testable import SwipeAndSketchCore

/// Delete Hole: the step that made a hole comes out of the solid's definition.
final class HoleRemovalTests: XCTestCase {
    let block = 30.0 * 30 * 12

    /// A 30 × 30 × 12 block with Hole-tool holes of `diameter` at `centers`.
    func drilled(_ diameter: Double, at centers: [Point2] = [.zero]) throws -> SolidBody {
        var body = try box(-15, -15, 15, 15, depth: 12)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1)))
        for center in centers {
            body.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: diameter), at: center, on: top, depth: nil)))
        }
        return body
    }

    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func testAHoleToolHoleIsTakenOutAndTheOtherStays() throws {
        let body = try drilled(5, at: [Point2(x: -6, y: 0), Point2(x: 6, y: 0)])
        XCTAssertNil(body.removingHole(around: SIMD3(0, 0, 6)), "Solid material, not a hole")
        let removal = try XCTUnwrap(body.removingHole(around: SIMD3(6, 0, 6)))
        XCTAssertEqual(removal.source, .cut(1))
        XCTAssertEqual(removal.body.cuts.count, 1)
        XCTAssertEqual(try volume(removal.body), block - .pi * 6.25 * 12, accuracy: 0.05)
    }

    func testAnExtrudedCircleCutAndAHoleDrawnInTheOutline() throws {
        // A circle cut extruded down through the block.
        var cut = try box(-15, -15, 15, 15, depth: 12)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1)))
        let circle = SketchShape(kind: .circle, plane: top, start: .zero, end: Point2(x: 4, y: 0))
        cut.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [circle], on: top).first), depth: -12))
        let removed = try XCTUnwrap(cut.removingHole(around: SIMD3(0, 0, 6)))
        XCTAssertEqual(try volume(removed.body), block, accuracy: 0.05)

        // A plate drawn as a square with a circle inside: the hole is part of its outline.
        let square = SketchShape(kind: .rectangle, plane: .top, start: Point2(x: -15, y: -15), end: Point2(x: 15, y: 15))
        let ring = SketchShape(kind: .circle, plane: .top, start: .zero, end: Point2(x: 4, y: 0))
        let profile = try XCTUnwrap(Geometry.profiles(in: [square, ring], on: .top).first { $0.holes?.isEmpty == false })
        let plate = SolidBody(profile: profile, depth: 12)
        let filled = try XCTUnwrap(plate.removingHole(around: SIMD3(0, 0, 6)))
        XCTAssertEqual(filled.source, .outlineHole(entry: nil, hole: 0))
        XCTAssertNil(filled.body.profile.holes)
        XCTAssertEqual(try volume(filled.body), block, accuracy: 0.05)
    }

    func testAThreadInTheHoleGoesWithIt() throws {
        let body = try drilled(6.8)
        let solid = try SolidKernel.solid(for: body)
        let wall = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCylinder($0) != nil })
        let threaded = try XCTUnwrap(body.threading(try XCTUnwrap(body.threadSpec(onFace: wall, of: solid, clearance: 0.2))))
        let removal = try XCTUnwrap(threaded.removingHole(around: SIMD3(0, 0, 6)))
        XCTAssertEqual(removal.threads, 1)
        XCTAssertTrue(removal.body.cuts.isEmpty, "The hole and its thread")
        XCTAssertEqual(try volume(removal.body), block, accuracy: 0.05)
    }

    func testARimChamferIsLeftOffAndOtherFinishesStay() throws {
        let body = try drilled(6, at: [Point2(x: -6, y: 0), Point2(x: 6, y: 0)])
        let solid = try SolidKernel.solid(for: body)
        // The top rims of both holes, and one outer edge of the block.
        let rims = (0..<solid.edgeCount).filter { edge in
            let samples = solid.edgeSamples(edge, count: 5)
            return samples.allSatisfy { abs($0.z - 12) < 1e-6 } && samples.allSatisfy { abs($0.x) < 10 && abs($0.y) < 4 }
        }
        XCTAssertEqual(rims.count, 2)
        let outer = try XCTUnwrap((0..<solid.edgeCount).first { edge in solid.edgeSamples(edge, count: 3).allSatisfy { abs($0.x - 15) < 1e-6 && abs($0.z - 12) < 1e-6 } })
        let chamfered = try XCTUnwrap(body.finishing(.chamfer, edges: rims + [outer], size: 0.5))
        let removal = try XCTUnwrap(chamfered.removingHole(around: SIMD3(6, 0, 6)))
        XCTAssertEqual(removal.finishedEdges, 1, "The removed hole's rim")
        XCTAssertEqual(removal.body.cuts.last?.finish?.edges.count, 2, "The other hole's rim and the outer edge keep theirs")
        XCTAssertTrue(try SolidKernel.solid(for: removal.body).isValidSolid)
    }

    func testTheAssistantDeletesAHole() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try drilled(5)]))
        let reply = try bench.deleteHole(body: "Body 01", face: "hole")
        XCTAssertEqual(reply, "Deleted a hole in Body 01.")
        XCTAssertEqual(try volume(bench.workspace.bodies[0]), block, accuracy: 0.05)
        XCTAssertThrowsError(try bench.deleteHole(body: "Body 01", face: "hole"), "None left")
    }
}
