import XCTest
import simd
@testable import SwipeAndSketchCore

/// Union: several solids become one, the last picked being the target.
final class UnionTests: XCTestCase {
    func box(_ x0: Double, _ x1: Double, depth: Double = 10) throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: x0, y: -10), end: .init(x: x1, y: 10))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: depth)
    }

    func testAChainOfTouchingSolidsUnitesInAnyPickedOrder() throws {
        let a = try box(0, 10), b = try box(10, 20), c = try box(20, 30)
        // C touches only B, but B joins first, so C can follow.
        let (result, untouched) = Unioning.union(a, with: [c, b])
        XCTAssertTrue(untouched.isEmpty)
        XCTAssertEqual(result.id, a.id, "The target keeps its identity")
        XCTAssertEqual(result.cuts.map(\.operation), [.merge, .merge])
        let solid = try SolidKernel.solid(for: result)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 3 * 10 * 20 * 10, accuracy: 1e-6)
    }

    func testSolidsThatNeverTouchAreReported() throws {
        let a = try box(0, 10), far = try box(50, 60), b = try box(5, 15)
        let (result, untouched) = Unioning.union(a, with: [far, b])
        XCTAssertEqual(untouched, [far.id])
        XCTAssertEqual(try SolidKernel.solid(for: result).volume, 15 * 20 * 10, accuracy: 1e-6, "Overlap counts once")
    }

    // MARK: Intersect

    func testIntersectKeepsOnlyTheSharedVolume() throws {
        let a = try box(0, 20), b = try box(10, 30), c = try box(15, 40)
        let result = try XCTUnwrap(Intersecting.intersect(a, with: [b, c]))
        XCTAssertEqual(result.id, a.id, "The target keeps its identity")
        XCTAssertEqual(result.cuts.map(\.operation), [.intersect, .intersect])
        XCTAssertEqual(try SolidKernel.solid(for: result).volume, 5 * 20 * 10, accuracy: 1e-6)
        // It moves and mirrors as one solid, carrying the others' definitions.
        let moved = try XCTUnwrap(result.transformed(by: .move(SIMD3(0, 0, 5))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).bounds.min.z, 5, accuracy: 1e-6)
        let reflection = try XCTUnwrap(Reflection(across: .right))
        let image = try XCTUnwrap(result.mirrored(by: reflection))
        let bounds = try SolidKernel.solid(for: image).bounds
        XCTAssertEqual(bounds.min.x, -20, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.x, -15, accuracy: 1e-6)
    }

    func testIntersectOfSolidsThatDoNotOverlapIsRefused() throws {
        XCTAssertNil(Intersecting.intersect(try box(0, 10), with: [try box(20, 30)]))
        XCTAssertNil(Intersecting.intersect(try box(0, 10), with: [try box(10, 20)]), "Touching is not overlapping")
    }
}
