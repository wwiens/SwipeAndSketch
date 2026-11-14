import XCTest
import simd
@testable import SwipeAndSketchCore

/// Drags and pattern previews seed moved copies of a solid on every frame. They must not push
/// the finished solids out of the cache (November 8, 2026), and a kept model's copies must stay.
final class SolidCacheMemoryTests: XCTestCase {
    func testDragSeedsDoNotPushOutBuiltSolids() throws {
        let cache = SolidCache()
        let bodies = try (0..<20).map { try box(Double($0) * 100, -10, Double($0) * 100 + 20, 10, depth: 10) }
        for body in bodies { _ = try cache.solid(for: body) }
        // About ten seconds of dragging the first solid at 60 frames a second.
        for frame in 1...600 {
            let transform = RigidTransform.move(SIMD3(Double(frame) * 0.1, 0, 0))
            let moved = try XCTUnwrap(bodies[0].transformed(by: transform))
            cache.seed(moved, from: bodies[0], by: transform)
        }
        for body in bodies { XCTAssertNotNil(cache.built(body), "A built solid was pushed out by drag frames") }
    }

    func testAKeptDragStaysWhenLaterDragsSeedMore() throws {
        let cache = SolidCache()
        let body = try box(depth: 10)
        let expected = try cache.solid(for: body).volume
        let transform = RigidTransform.move(SIMD3(5, 0, 0))
        let kept = try XCTUnwrap(body.transformed(by: transform))
        cache.seed(kept, from: body, by: transform)
        XCTAssertNotNil(cache.built(kept), "Seeded")
        cache.keep([kept])
        for frame in 1...400 {
            let step = RigidTransform.move(SIMD3(0, Double(frame) * 0.1, 0))
            cache.seed(try XCTUnwrap(kept.transformed(by: step)), from: kept, by: step)
        }
        XCTAssertEqual(try XCTUnwrap(cache.built(kept)).volume, expected, accuracy: 1e-6, "The kept move is still in memory")
    }

    func testReleasingMemoryKeepsTheMostRecentSolids() throws {
        let cache = SolidCache()
        let bodies = try (0..<10).map { try box(Double($0) * 100, -10, Double($0) * 100 + 20, 10, depth: 10) }
        for body in bodies { _ = try cache.solid(for: body) }
        cache.trim(keeping: 3)
        XCTAssertEqual(bodies.filter { cache.built($0) != nil }.count, 3)
        XCTAssertNotNil(cache.built(bodies[9]), "The latest built stays")
        cache.removeAll()
        XCTAssertTrue(bodies.allSatisfy { cache.built($0) == nil })
        XCTAssertEqual(try cache.solid(for: bodies[0]).volume, 20 * 20 * 10, accuracy: 1e-6, "Built again on request")
    }

    func testStepsOnTheSolidsOwnProfileValidateAsBefore() throws {
        var body = try box(depth: 20)
        let own = body.profile
        // Offset Face style steps carry the solid's own profile; the check is shared, not skipped.
        var step = ExtrusionCut(profile: own, depth: 5, operation: .join)
        step.facePoint = Point2(x: 0, y: 0)
        body.cuts = Array(repeating: step, count: 5)
        XCTAssertEqual(body.cutsAreValid, body.cuts.allSatisfy(\.isValid))
        var broken = own
        broken.outline = [own.outline[0], own.outline[0], own.outline[0]]
        var bad = step
        bad.profile = broken
        body.cuts.append(bad)
        XCTAssertFalse(body.cutsAreValid)
        XCTAssertEqual(body.cutsAreValid, body.cuts.allSatisfy(\.isValid))
    }

    func testSolidsKeptOnDiskAreReadBackTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = BuiltSolidStore(directory: directory)
        var bodies: [SolidBody] = []
        for index in 0..<8 {
            var body = try box(Double(index) * 100, -10, Double(index) * 100 + 20, 10, depth: 10)
            body.finishes = [EdgeFinish(kind: .fillet, edges: body.extrusionEdges.filter { $0.position == .side }, size: 2)]
            bodies.append(body)
        }
        let writer = SolidCache()
        let volumes = try bodies.map { try writer.solid(for: $0).volume }
        writer.keepOnDisk(bodies, disk: disk)
        let reader = SolidCache()
        reader.readFromDisk(bodies, disk: disk)
        for (body, volume) in zip(bodies, volumes) {
            XCTAssertEqual(try XCTUnwrap(reader.built(body), "Read from disk, not built").volume, volume, accuracy: 1e-6)
        }
    }
}
