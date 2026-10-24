import XCTest
import simd
@testable import SwipeAndSketchCore

/// Fillets and chamfers found from a face they made, then resized or taken out (October 23, 2026).
final class FinishEditingTests: XCTestCase {
    let block = 30.0 * 30 * 12

    /// Kernel edges of `solid` whose samples all satisfy `test`.
    func edges(_ solid: KernelSolid, where test: (SIMD3<Double>) -> Bool) -> [Int] {
        (0..<solid.edgeCount).filter { solid.edgeSamples($0, count: 5).allSatisfy(test) }
    }

    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    /// A 30 × 30 × 12 block with its four top edges rounded by `radius`.
    func rounded(_ radius: Double) throws -> SolidBody {
        let body = try box(-15, -15, 15, 15, depth: 12)
        let top = edges(try SolidKernel.solid(for: body)) { abs($0.z - 12) < 1e-6 }
        XCTAssertEqual(top.count, 4)
        return try XCTUnwrap(body.finishing(.fillet, edges: top, size: radius))
    }

    func testAFilletFaceFindsItsFilletWhichResizesAndComesOut() throws {
        let body = try rounded(2)
        XCTAssertEqual(body.finishes.count, 1, "Original edges keep their names")
        // On the round along the x = 15 edge, halfway around it.
        let onFillet = SIMD3(13 + 2 * 0.5.squareRoot(), 0, 10 + 2 * 0.5.squareRoot())
        XCTAssertEqual(body.finishSource(atFace: onFillet), .named(0))
        XCTAssertNil(body.finishSource(atFace: SIMD3(0, 0, 12)), "The top face is the block's own")
        XCTAssertNil(body.finishSource(atFace: SIMD3(15, 0, 5)), "So is a side")

        let bigger = try XCTUnwrap(body.resizingFinish(.named(0), to: 3))
        XCTAssertEqual(bigger.finishes[0].size, 3)
        XCTAssertLessThan(try volume(bigger), try volume(body))
        XCTAssertNil(body.resizingFinish(.named(0), to: 20), "Too big for a 12 mm block")
        XCTAssertNil(body.resizingFinish(.named(0), to: 0), "Out of range")

        let sharp = try XCTUnwrap(body.removingFinish(.named(0)))
        XCTAssertTrue(sharp.finishes.isEmpty)
        XCTAssertEqual(try volume(sharp), block, accuracy: 0.01)
    }

    func testAChamferStepAfterAHoleIsFoundAndTakenOut() throws {
        var body = try box(-15, -15, 15, 15, depth: 12)
        let top = try XCTUnwrap(SketchPlane.through(.init(0, 0, 12), normal: .init(0, 0, 1)))
        body.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HoleSpec(kind: .simple, size: "", diameter: 5), at: .zero, on: top, depth: nil)))
        let outer = edges(try SolidKernel.solid(for: body)) { abs($0.x - 15) < 1e-6 && abs($0.z - 12) < 1e-6 }
        let chamfered = try XCTUnwrap(body.finishing(.chamfer, edges: outer, size: 1))
        XCTAssertEqual(chamfered.cuts.count, 2, "Saved as a step after the hole")
        XCTAssertEqual(chamfered.finishSource(atFace: SIMD3(14.5, 0, 11.5)), .step(1))
        XCTAssertEqual(chamfered.finishKind(.step(1))?.kind, .chamfer)
        XCTAssertNil(chamfered.finishSource(atFace: SIMD3(2.5, 0, 6)), "The hole's wall")
        let removed = try XCTUnwrap(chamfered.removingFinish(.step(1)))
        XCTAssertEqual(removed, body)
    }

    func testTheNewerOfTwoFinishesIsFoundOnItsOwnFace() throws {
        let body = try rounded(2)
        let bottom = edges(try SolidKernel.solid(for: body)) { abs($0.x - 15) < 1e-6 && abs($0.z) < 1e-6 }
        XCTAssertEqual(bottom.count, 1)
        let both = try XCTUnwrap(body.finishing(.chamfer, edges: bottom, size: 1))
        XCTAssertEqual(both.finishes.count, 2, "Both on original edges, by name")
        XCTAssertEqual(both.finishSource(atFace: SIMD3(14.5, 0, 0.5)), .named(1), "The bottom chamfer")
        XCTAssertEqual(both.finishSource(atFace: SIMD3(13 + 2 * 0.5.squareRoot(), 0, 10 + 2 * 0.5.squareRoot())), .named(0), "The top round")
        // Without the round, the chamfer stays.
        let unrounded = try XCTUnwrap(both.removingFinish(.named(0)))
        XCTAssertEqual(unrounded.finishes.map(\.kind), [.chamfer])
        XCTAssertEqual(unrounded.finishSource(atFace: SIMD3(14.5, 0, 0.5)), .named(0))
        XCTAssertEqual(try volume(unrounded), block - 0.5 * 30, accuracy: 0.01)
    }

    func testTheAssistantChangesAndDeletesAFillet() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try rounded(2)]))
        XCTAssertEqual(try bench.editFinish(body: "Body 01", which: "1", size: 3), "Changed a fillet of Body 01 from 2 to 3 mm.")
        XCTAssertEqual(bench.workspace.bodies[0].finishes[0].size, 3)
        XCTAssertThrowsError(try bench.editFinish(body: "Body 01", which: "2", size: 1), "Only one")
        XCTAssertEqual(try bench.editFinish(body: "Body 01", which: "last", size: nil), "Deleted a 3 mm fillet from Body 01.")
        XCTAssertEqual(try volume(bench.workspace.bodies[0]), block, accuracy: 0.01)
        XCTAssertThrowsError(try bench.editFinish(body: "Body 01", which: "1", size: nil), "None left")
    }
}
