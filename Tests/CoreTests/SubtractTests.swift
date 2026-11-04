import XCTest
import simd
@testable import SwipeAndSketchCore

/// Subtract: tool solids removed from target solids, kept as editable definitions.
final class SubtractTests: XCTestCase {
    func box(_ x0: Double, _ x1: Double, y: Double = 10, depth: Double = 10) throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: x0, y: -y), end: .init(x: x1, y: y))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: depth)
    }

    func testOverlappingToolsAreRemovedAndOthersIgnored() throws {
        let target = try box(0, 40), notch = try box(30, 50, y: 5), far = try box(100, 110)
        let (result, used) = Subtracting.subtract([notch, far], from: target)
        XCTAssertEqual(used, [notch.id])
        XCTAssertEqual(result.id, target.id)
        XCTAssertEqual(result.cuts.map(\.operation), [.subtract])
        XCTAssertEqual(try SolidKernel.solid(for: result).volume, 40 * 20 * 10 - 10 * 10 * 10, accuracy: 1e-6)
    }

    func testATargetSwallowedWholeIsRefusedAndMovingCarriesTheTool() throws {
        let small = try box(0, 10), big = try box(-50, 50, y: 50, depth: 50)
        XCTAssertTrue(Subtracting.subtract([big], from: small).used.isEmpty, "Nothing would be left")
        let (result, _) = Subtracting.subtract([try box(30, 50, y: 5)], from: try box(0, 40))
        let moved = try XCTUnwrap(result.transformed(by: .move(.init(0, 0, 25))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, try SolidKernel.solid(for: result).volume, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: moved).bounds.min.z, 25, accuracy: 1e-6)
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [moved])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [moved])
    }
}
