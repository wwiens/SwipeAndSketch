import XCTest
import simd
@testable import SwipeAndSketchCore

/// A removal that leaves a solid in separate pieces makes each piece its own solid (October 24, 2026).
final class PieceTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top (x −30…30, y −20…20, z 0…20).
    func box() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
    }

    /// A rectangle on `plane` as a profile.
    func profile(_ x: ClosedRange<Double>, _ y: ClosedRange<Double>, on plane: SketchPlane = .top) throws -> SketchProfile {
        let shape = SketchShape(kind: .rectangle, plane: plane, start: .init(x: x.lowerBound, y: y.lowerBound), end: .init(x: x.upperBound, y: y.upperBound))
        return try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first)
    }

    func solid(_ body: SolidBody) throws -> KernelSolid { try SolidKernel.solid(for: body) }

    /// The box with a through-all slot across it at x 8…12: 38 mm on the left, 18 mm on the right.
    func cutApart() throws -> (before: Workspace, after: Workspace, box: SolidBody) {
        let box = try box()
        var cut = box
        cut.cuts.append(ExtrusionCut(profile: try profile(8...12, -25...25), depth: 1, throughAll: true))
        return (Workspace(bodies: [box]), Workspace(bodies: [cut]), box)
    }

    func testACutThroughTheMiddleLeavesTwoSolids() throws {
        let (before, after, box) = try cutApart()
        XCTAssertEqual(try solid(after.bodies[0]).pieceCount, 2)
        let separated = after.separatingPieces(since: before)
        let bodies = separated.workspace.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0].id, box.id, "The larger piece keeps the solid's id")
        XCTAssertEqual(separated.added[box.id], [bodies[1].id])
        XCTAssertEqual(try solid(bodies[0]).volume, 38 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try solid(bodies[1]).volume, 18 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try solid(bodies[1]).bounds.min.x, 12, accuracy: 1e-6)
        XCTAssertTrue(try bodies.allSatisfy { try solid($0).pieceCount == 1 && solid($0).isValidSolid && $0.isValid })
        XCTAssertEqual(bodies.map { $0.cuts.last?.split?.keep }, [.piece, .piece])
        // Nothing changed since: nothing more to separate.
        XCTAssertTrue(separated.workspace.separatingPieces(since: separated.workspace).added.isEmpty)
    }

    func testACutThatLeavesOnePieceChangesNothing() throws {
        let box = try box()
        var drilled = box
        drilled.cuts.append(ExtrusionCut(profile: try profile(-5...5, -5...5), depth: 1, throughAll: true))
        let workspace = Workspace(bodies: [drilled])
        XCTAssertEqual(workspace.separatingPieces(since: Workspace(bodies: [box])).workspace, workspace)
    }

    func testAPieceMovesMirrorsAndSavesAsItself() throws {
        let (before, after, _) = try cutApart()
        let right = after.separatingPieces(since: before).workspace.bodies[1]
        let moved = try XCTUnwrap(right.transformed(by: .move(SIMD3(0, 100, 5))))
        XCTAssertEqual(try solid(moved).volume, 18 * 40 * 20, accuracy: 1e-6)
        XCTAssertEqual(try solid(moved).bounds.min.x, 12, accuracy: 1e-6)
        XCTAssertEqual(try solid(moved).bounds.min.y, 80, accuracy: 1e-6)
        let mirrored = try XCTUnwrap(right.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try solid(mirrored).bounds.max.x, -12, accuracy: 1e-6, "The mirror image keeps the same piece")
        XCTAssertEqual(try solid(mirrored).volume, 18 * 40 * 20, accuracy: 1e-6)
        let reread = try JSONDecoder().decode(SolidBody.self, from: try JSONEncoder().encode(right))
        XCTAssertEqual(reread, right)
        XCTAssertEqual(try solid(reread).volume, 18 * 40 * 20, accuracy: 1e-6)
    }

    func testSplitBodyMakesEachDisconnectedPartItsOwnSolid() throws {
        // A U: a 20 mm wide, 15 mm deep slot down from the top, so the arms join only at the bottom.
        let top = try XCTUnwrap(SketchPlane.through(SIMD3(0, 0, 20), normal: SIMD3(0, 0, 1)))
        var u = try box()
        u.cuts.append(ExtrusionCut(profile: try profile(-10...10, -25...25, on: top), depth: -15))
        let before = Workspace(bodies: [u])
        XCTAssertEqual(try solid(u).pieceCount, 1)
        // Split at z = 10: the bottom stays one piece, and above it the two arms are apart.
        let plane = try XCTUnwrap(SketchPlane.through(SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1)))
        let pieces = try XCTUnwrap(Splitting.pieces(of: u, with: [SplitTool(source: .world(plane), plane: plane)]))
        XCTAssertEqual(pieces.count, 2)
        let separated = Workspace(bodies: pieces).separatingPieces(since: before).workspace
        XCTAssertEqual(separated.bodies.count, 3)
        let volumes = try separated.bodies.map { try solid($0).volume }.sorted()
        XCTAssertEqual(volumes[0], 20 * 40 * 10, accuracy: 1e-6, "Each arm above z = 10: 20 × 40 × 10")
        XCTAssertEqual(volumes[1], 20 * 40 * 10, accuracy: 1e-6)
        XCTAssertEqual(volumes[2], 60 * 40 * 10 - 20 * 40 * 5, accuracy: 1e-6)
    }

    func testAMoveIsNotCheckedAgain() throws {
        let (before, after, _) = try cutApart()
        let separated = after.separatingPieces(since: before).workspace
        var moved = separated
        moved.bodies[1] = try XCTUnwrap(moved.bodies[1].transformed(by: .move(SIMD3(5, 0, 0))))
        XCTAssertEqual(moved.separatingPieces(since: separated).workspace, moved)
    }
}
