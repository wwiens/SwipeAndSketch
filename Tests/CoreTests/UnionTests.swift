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

    // MARK: Carried solids as exact shapes (November 8, 2026)

    /// A 10 × 20 × 10 block at x 20…30 with `holes` small holes down through it.
    func drilled(holes: Int) throws -> SolidBody {
        var body = try box(20, 30)
        for index in 0..<holes {
            let x = 21 + Double(index % 4) * 2.5, y = -8 + Double(index / 4) * 4
            let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: x, y: y), end: .init(x: x + 0.5, y: y))
            body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        }
        return body
    }

    func testALongHistoryIsCarriedAsItsExactShape() throws {
        let target = try box(0, 21), tool = try drilled(holes: 12)
        XCTAssertTrue(tool.isWorthStoringAsShape)
        XCTAssertFalse(try drilled(holes: 3).isWorthStoringAsShape, "Short histories stay as they are")
        let united = Unioning.union(target, with: [tool]).result
        let workspace = Workspace(bodies: [united])
        XCTAssertTrue(workspace.hasCarriedHistories)
        let volume = try SolidKernel.solid(for: united).volume

        let stored = workspace.storingCarriedSolidsAsShapes(build: true)
        XCTAssertFalse(stored.hasCarriedHistories)
        let carried = try XCTUnwrap(stored.bodies[0].cuts[0].merged)
        XCTAssertNotNil(carried.imported, "The tool is its shape now")
        XCTAssertEqual(carried.id, tool.id)
        XCTAssertEqual(stored.importedShapes.count, 1)
        XCTAssertTrue(stored.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: stored.bodies[0]).volume, volume, accuracy: 1e-6)
        XCTAssertEqual(stored.storingCarriedSolidsAsShapes(build: true), stored, "Nothing left to store")

        // In a file, then moved and mirrored as one solid.
        let read = try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: stored)))
        XCTAssertEqual(read.workspace, stored)
        let moved = try XCTUnwrap(stored.bodies[0].transformed(by: .move(SIMD3(0, 0, 5))))
        XCTAssertEqual(try SolidKernel.solid(for: moved).bounds.min.z, 5, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, volume, accuracy: 1e-6)
        let image = try XCTUnwrap(stored.bodies[0].mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        let bounds = try SolidKernel.solid(for: image).bounds
        XCTAssertEqual(bounds.min.x, -30, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.x, 0, accuracy: 1e-6)
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, volume, accuracy: 1e-6)

        // Only the steps given: an edit's own new steps.
        XCTAssertEqual(workspace.storingCarriedSolidsAsShapes(build: true, steps: []), workspace)

        // Without the solid built, nothing is built to store it.
        let unbuilt = Unioning.union(try box(-10, 21), with: [try drilled(holes: 11)]).result
        XCTAssertEqual(unbuilt.cuts.count, 1)
        var fresh = unbuilt
        fresh.cuts[0].merged?.cuts.append(ExtrusionCut(profile: try box(29, 29.7).profile, depth: 1, throughAll: true))
        XCTAssertEqual(Workspace(bodies: [fresh]).storingCarriedSolidsAsShapes(build: false), Workspace(bodies: [fresh]))
    }

    func testStoringAsShapesIsNotAnUndoStep() throws {
        let united = Unioning.union(try box(0, 21), with: [try drilled(holes: 12)]).result
        var history = WorkspaceHistory(workspace: Workspace(bodies: [try box(-30, -20)]))
        history.commit(Workspace(bodies: [united]))
        let stored = history.workspace.storingCarriedSolidsAsShapes(build: true)
        XCTAssertTrue(history.replaceStorage(stored))
        XCTAssertEqual(history.workspace, stored)
        history.undo()
        XCTAssertEqual(history.workspace.bodies.count, 1)
        XCTAssertNil(history.workspace.bodies[0].cuts.first, "Back to the step before")
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
