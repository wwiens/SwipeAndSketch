import XCTest
@testable import SwipeAndSketchCore

final class JoinTests: XCTestCase {
    var lid: SketchPlane { SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1))! }

    func profile(_ kind: ShapeKind, _ a: Point2, _ b: Point2, on plane: SketchPlane) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: kind, plane: plane, start: a, end: b)], on: plane).first)
    }

    func testBossOnAFaceMergesIntoOneSolid() throws {
        var body = try box()
        let boss = try profile(.rectangle, .init(x: -5, y: -5), .init(x: 5, y: 5), on: lid)
        body.cuts = [ExtrusionCut(profile: boss, depth: 6, operation: .join)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid, "One connected solid")
        XCTAssertEqual(solid.volume, 48_000 + 10 * 10 * 6, accuracy: 1e-6)
        XCTAssertEqual(solid.faceCount, 11, "6 box faces + 4 boss sides + boss top")
        XCTAssertEqual(solid.bounds.max.z, 26, accuracy: 1e-9)
    }

    func testOperationsReplayInTheOrderTheyWereMade() throws {
        var body = try box()
        let hole = try profile(.circle, .zero, .init(x: 3, y: 0), on: .top)
        let boss = try profile(.rectangle, .init(x: -6, y: -6), .init(x: 6, y: 6), on: lid)
        // Hole, then a boss over it: the boss closes the top of the hole.
        body.cuts = [ExtrusionCut(profile: hole, depth: 1, throughAll: true), ExtrusionCut(profile: boss, depth: 4, operation: .join)]
        let covered = try SolidKernel.solid(for: body).volume
        XCTAssertEqual(covered, 48_000 - .pi * 9 * 20 + 12 * 12 * 4, accuracy: 1e-3)
        // A second through-all hole afterwards goes through both.
        body.cuts.append(ExtrusionCut(profile: hole, depth: 1, throughAll: true))
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, covered - .pi * 9 * 4, accuracy: 1e-3)
    }

    func testBossThatMissesTheSolidFails() throws {
        var body = try box()
        let floating = try profile(.rectangle, .init(x: 50, y: 50), .init(x: 60, y: 60), on: lid)
        body.cuts = [ExtrusionCut(profile: floating, depth: 5, operation: .join)]
        XCTAssertThrowsError(try SolidKernel.solid(for: body))
    }

    func testJoinValidationAndRoundTrip() throws {
        var body = try box()
        let boss = try profile(.circle, .zero, .init(x: 4, y: 0), on: lid)
        var join = ExtrusionCut(profile: boss, depth: 5, operation: .join)
        join.throughAll = true
        body.cuts = [join]
        XCTAssertFalse(body.isValid, "Joins have a depth, never Through All")
        body.cuts = [ExtrusionCut(profile: boss, depth: 5, operation: .join)]
        XCTAssertTrue(body.isValid)
        let project = Project(workspace: Workspace(bodies: [body]))
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies[0].cuts[0].operation, .join)
        // Cuts alone still encode without the join key.
        body.cuts = [ExtrusionCut(profile: boss, depth: 5)]
        XCTAssertFalse(String(decoding: try ProjectCodec.encode(Project(workspace: Workspace(bodies: [body]))), as: UTF8.self).contains("join"))
    }
}
