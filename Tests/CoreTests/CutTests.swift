import XCTest
import simd
@testable import SwipeAndSketchCore

final class CutTests: XCTestCase {
    func profile(_ kind: ShapeKind, _ a: Point2, _ b: Point2, plane: SketchPlane = .top) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: kind, plane: plane, start: a, end: b)], on: plane).first)
    }

    func hole(radius: Double = 5, at center: Point2 = .zero, plane: SketchPlane = .top) throws -> SketchProfile {
        try profile(.circle, center, center + Point2(x: radius, y: 0), plane: plane)
    }

    func testThroughAllHoleFromTheSketchPlane() throws {
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try hole(), depth: 1, throughAll: true)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 60 * 40 * 20 - .pi * 25 * 20, accuracy: 1e-3)
    }

    func testThroughAllWorksFromAPlaneInsideTheSolid() throws {
        // The Front plane (y = 0) runs through the middle of the box: a sideways hole at z = 10.
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try hole(radius: 4, at: .init(x: 0, y: 10), plane: .front), depth: 1, throughAll: true)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 60 * 40 * 20 - .pi * 16 * 40, accuracy: 1e-3, "Both directions, full 40 mm width")
    }

    func testPocketCutsOnlyToItsDepthInEitherDirection() throws {
        var body = try box()
        let slot = try profile(.rectangle, .init(x: -10, y: -5), .init(x: 10, y: 5))
        body.cuts = [ExtrusionCut(profile: slot, depth: 6)]
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 48_000 - 20 * 10 * 6, accuracy: 1e-6, "Pocket up from the bottom face")
        body.cuts = [ExtrusionCut(profile: slot, depth: -6)]
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 48_000, accuracy: 1e-6, "Downward from the bottom misses the solid entirely")
    }

    func testCutsComposeWithFinishesAndEachOther() throws {
        var body = try box()
        body.finishes = [EdgeFinish(kind: .fillet, edges: body.extrusionEdges.filter { $0.position == .side }, size: 4)]
        let rounded = try SolidKernel.solid(for: body).volume
        body.cuts = [ExtrusionCut(profile: try hole(radius: 3, at: .init(x: -15, y: 0)), depth: 1, throughAll: true),
                     ExtrusionCut(profile: try hole(radius: 3, at: .init(x: 15, y: 0)), depth: 1, throughAll: true)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, rounded - 2 * .pi * 9 * 20, accuracy: 1e-3)
        // Finishes still find their named edges, and the holes' edges carry no names.
        let names = (0..<solid.edgeCount).compactMap { body.extrusionEdge(along: solid.edgeSamples($0)) }
        XCTAssertFalse(names.contains { $0.position == .side })
        XCTAssertEqual(Set(names.filter { $0.position != .side }).count, 8)
    }

    func testCutThatSplitsASolidKeepsBothPieces() throws {
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try profile(.rectangle, .init(x: -2, y: -30), .init(x: 2, y: 30)), depth: 1, throughAll: true)]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertEqual(solid.volume, 48_000 - 4 * 40 * 20, accuracy: 1e-3)
        XCTAssertFalse(solid.isValidSolid, "Two separate pieces are not one solid")
    }

    func testCutRemovingEverythingFails() throws {
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try profile(.rectangle, .init(x: -50, y: -50), .init(x: 50, y: 50)), depth: 1, throughAll: true)]
        XCTAssertThrowsError(try SolidKernel.solid(for: body))
    }

    func testIncrementalCacheMatchesAFreshBuild() throws {
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try hole(), depth: 12)]
        let cached = try SolidKernel.solid(for: body)
        XCTAssertTrue(try SolidKernel.solid(for: body) === cached, "Same body value returns the cached solid")
        var fresh = try SolidKernel.extrude(body.profile, depth: body.depth)
        var uncut = body; uncut.cuts = []
        fresh = try SolidKernel.apply(body.cuts[0], to: fresh, of: uncut)
        XCTAssertEqual(cached.volume, fresh.volume, accuracy: 1e-9)
        XCTAssertEqual(cached.volume, 48_000 - .pi * 25 * 12, accuracy: 1e-3)
    }

    func testCutValidationAndRoundTrip() throws {
        var body = try box()
        body.cuts = [ExtrusionCut(profile: try hole(), depth: 0)]
        XCTAssertFalse(body.isValid, "A depth cut needs a depth")
        body.cuts = [ExtrusionCut(profile: try hole(), depth: 0, throughAll: true)]
        XCTAssertTrue(body.isValid, "Through-all ignores depth")
        var bad = try hole(); bad.outline = []
        body.cuts = [ExtrusionCut(profile: bad, depth: 5)]
        XCTAssertFalse(body.isValid)

        body.cuts = [ExtrusionCut(profile: try hole(), depth: 5)]
        let project = Project(workspace: Workspace(bodies: [body]))
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data).workspace, project.workspace)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = Project.currentSchemaVersion + 1
        XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json))) { error in
            XCTAssertEqual(error as? ProjectError, .unsupportedVersion)
        }
    }
}
