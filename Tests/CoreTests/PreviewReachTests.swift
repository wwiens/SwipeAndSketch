import XCTest
import simd
@testable import SwipeAndSketchCore

/// Live extrude previews skip solids a cut or join cannot reach (`ExtrusionCut.mayReach`) without
/// building them. Skipping must never change a result: whenever it says a solid is out of reach,
/// cutting it removes nothing and joining it cannot make one piece.
final class PreviewReachTests: XCTestCase {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func region(_ kind: ShapeKind, _ a: Point2, _ b: Point2, plane: SketchPlane) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: kind, plane: plane, start: a, end: b)], on: plane).first)
    }

    func testOutOfReachNeverChangesACutOrJoin() throws {
        var random = Seeded(state: 20_261_108)
        let target = try box(depth: 20)
        let solid = try SolidKernel.solid(for: target)
        // Three world planes, and a face plane turned 30° about z, a little off the origin.
        let turned = SketchPlane(origin: .init(3, -2, 5), xAxis: .init(cos(.pi / 6), sin(.pi / 6), 0), yAxis: .init(0, 0, 1))
        let planes: [SketchPlane] = [.top, .front, .right, turned]
        var skipped = 0, checked = 0
        for round in 0..<160 {
            let plane = planes[round % planes.count]
            let center = Point2(x: Double.random(in: -60...60, using: &random), y: Double.random(in: -50...50, using: &random))
            let size = Double.random(in: 1...15, using: &random)
            let kind: ShapeKind = round % 3 == 0 ? .circle : .rectangle
            let profile = try region(kind, center, center + Point2(x: size, y: kind == .circle ? 0 : size * 0.7), plane: plane)
            var cut = ExtrusionCut(profile: profile, depth: Double.random(in: -40...40, using: &random))
            if abs(cut.depth) < 0.5 { cut.depth = 0.5 }
            switch round % 5 {
            case 1: cut.symmetric = true
            case 2: cut.taper = Double.random(in: -30...30, using: &random)
            case 3: cut.throughAll = true
            default: break
            }
            XCTAssertTrue(cut.isValid, "round \(round)")
            guard !cut.mayReach(solid.bounds) else { continue }
            skipped += 1
            var cutBody = target
            cutBody.cuts = [cut]
            if let after = try? SolidKernel.solid(for: cutBody) {
                checked += 1
                XCTAssertEqual(after.volume, solid.volume, accuracy: 1e-6, "round \(round): a skipped cut removed material")
            }
            guard !cut.throughAll else { continue }
            var join = cut
            join.join = true
            var joinBody = target
            joinBody.cuts = [join]
            XCTAssertNil(try? SolidKernel.solid(for: joinBody), "round \(round): a skipped join made one piece")
        }
        XCTAssertGreaterThan(skipped, 30, "The sample should exercise the skip")
        XCTAssertGreaterThan(checked, 20)
    }

    func testTouchingAndInsideStayInReach() throws {
        let solid = try SolidKernel.solid(for: try box(depth: 20))
        // A boss standing on the top face (z = 20), drawn on a plane at that height.
        let lid = SketchPlane(origin: .init(0, 0, 20), xAxis: .init(1, 0, 0), yAxis: .init(0, 1, 0))
        let boss = ExtrusionCut(profile: try region(.circle, .zero, .init(x: 5, y: 0), plane: lid), depth: 5, operation: .join)
        XCTAssertTrue(boss.mayReach(solid.bounds))
        // A pocket from below the solid, reaching up into it.
        XCTAssertTrue(ExtrusionCut(profile: try region(.rectangle, .init(x: -5, y: -5), .init(x: 5, y: 5), plane: .top), depth: 6)
            .mayReach(solid.bounds))
        // Beside the solid, just past its side at x = 30: out of reach, but a widening taper brings it back.
        var beside = ExtrusionCut(profile: try region(.rectangle, .init(x: 31, y: -5), .init(x: 40, y: 5), plane: .top), depth: 10)
        XCTAssertFalse(beside.mayReach(solid.bounds))
        beside.taper = -20
        XCTAssertTrue(beside.mayReach(solid.bounds))
        // Through All reaches along the normal however far the sketch plane is.
        let far = SketchPlane(origin: .init(0, 0, 500), xAxis: .init(1, 0, 0), yAxis: .init(0, 1, 0))
        var through = ExtrusionCut(profile: try region(.circle, .zero, .init(x: 3, y: 0), plane: far), depth: 1, throughAll: true)
        XCTAssertTrue(through.mayReach(solid.bounds))
        through.throughAll = false
        XCTAssertFalse(through.mayReach(solid.bounds))
    }

    func testAppendedStepsAreCheckedLikeTheWholeSolid() throws {
        let body = try box(depth: 20)
        let hole = ExtrusionCut(profile: try region(.circle, .zero, .init(x: 4, y: 0), plane: .top), depth: 1, throughAll: true)
        var next = body
        next.cuts.append(hole)
        XCTAssertEqual(body.isValid(appending: [hole]), next.isValid)
        var bad = hole
        bad.throughAll = false
        bad.depth = .nan
        next.cuts[next.cuts.count - 1] = bad
        XCTAssertEqual(body.isValid(appending: [bad]), next.isValid)
        XCTAssertFalse(body.isValid(appending: [bad]))
        var full = body
        full.cuts = Array(repeating: hole, count: ExtrusionCut.maximumPerBody)
        XCTAssertFalse(full.isValid(appending: [hole]), "No more steps than a solid may hold")
    }
}
