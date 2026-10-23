import XCTest
import simd
@testable import SwipeAndSketchCore

final class PatternTests: XCTestCase {
    private let axes: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

    /// A 10 × 4 × 5 mm block at (x, y) with a through hole in it.
    func block(at x: Double = 0, _ y: Double = 0) throws -> SolidBody {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: x, y: y), end: .init(x: x + 10, y: y + 4))
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [rectangle], on: .top).first), depth: 5)
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: x + 5, y: y + 2), end: .init(x: x + 6, y: y + 2))
        body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        return body
    }

    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let bounds = try SolidKernel.solid(for: body).bounds
        return (bounds.min, bounds.max)
    }

    func testTotalAndSpacingSpreadLinearCopies() {
        var spec = PatternSpec(center: .zero, axes: axes)
        spec.directions[0].count = 4
        spec.directions[0].distance = 30
        XCTAssertEqual(spec.instanceCount, 4)
        XCTAssertEqual(spec.placements(itemsCenter: .zero).map { $0.translation.x }, [10, 20, 30], "A total of 30 mm spreads four across it")
        spec.definition = .spacing
        XCTAssertEqual(spec.placements(itemsCenter: .zero).map { $0.translation.x }, [30, 60, 90], "Spacing is the gap between neighbors")
        // A second direction makes a grid.
        spec.directions[1].count = 2
        spec.directions[1].distance = -8
        XCTAssertEqual(spec.instanceCount, 8)
        let offsets = spec.placements(itemsCenter: .zero).map(\.translation)
        XCTAssertEqual(offsets.count, 7)
        XCTAssertTrue(offsets.contains(SIMD3(90, -8, 0)))
        // A direction with no distance is unused, whatever its count.
        spec.directions[2].count = 5
        XCTAssertEqual(spec.instanceCount, 8)
    }

    func testCircularTotalOfAWholeTurnDoesNotRepeatTheOriginal() {
        var spec = PatternSpec(center: .zero, axes: axes)
        spec.kind = .circular
        spec.count = 4
        XCTAssertEqual(spec.instanceCount, 1, "Nothing until the gizmo is turned")
        spec.angle = 360
        XCTAssertEqual(spec.angleStep, 90)
        spec.angle = 180
        XCTAssertEqual(spec.angleStep, 60, "Part of a turn puts the last copy at its end")
        spec.definition = .spacing
        spec.angle = 45
        XCTAssertEqual(spec.angleStep, 45)
    }

    func testLinearPatternCopiesSolidsAfterTheOriginal() throws {
        let original = try block(), other = try block(at: 0, 40)
        var workspace = Workspace()
        workspace.bodies = [original, other]
        var spec = PatternSpec(center: .zero, axes: axes)
        spec.directions[0].count = 3
        spec.directions[0].distance = 40
        let result = try XCTUnwrap(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec))
        XCTAssertEqual(result.bodies.count, 2)
        XCTAssertEqual(result.workspace.bodies.map(\.id), [original.id] + result.bodies + [other.id], "Copies follow their original")
        XCTAssertEqual(Set(result.workspace.bodies.map(\.id)).count, 4, "Each copy has its own id")
        for (index, id) in result.bodies.enumerated() {
            let copy = try XCTUnwrap(result.workspace.bodies.first { $0.id == id })
            XCTAssertEqual(copy.cuts.count, 1, "The hole comes along")
            XCTAssertEqual(try bounds(copy).min.x, Double(index + 1) * 20, accuracy: 1e-6)
            XCTAssertEqual(try SolidKernel.solid(for: copy).volume, try SolidKernel.solid(for: original).volume, accuracy: 1e-6)
        }
    }

    func testCircularPatternRotatedOrUniform() throws {
        let original = try block(at: 20, -2)
        var workspace = Workspace()
        workspace.bodies = [original]
        var spec = PatternSpec(center: .zero, axes: axes)
        spec.kind = .circular
        spec.count = 4
        spec.angle = 360
        let rotated = try XCTUnwrap(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec))
        XCTAssertEqual(rotated.bodies.count, 3)
        // A quarter turn about +Z carries the block from +x to +y, now 4 wide in x and 10 long in y.
        let quarter = try bounds(try XCTUnwrap(rotated.workspace.bodies.first { $0.id == rotated.bodies[0] }))
        XCTAssertEqual(quarter.min.x, -2, accuracy: 1e-6)
        XCTAssertEqual(quarter.max.x, 2, accuracy: 1e-6)
        XCTAssertEqual(quarter.min.y, 20, accuracy: 1e-6)
        XCTAssertEqual(quarter.max.y, 30, accuracy: 1e-6)
        spec.orientation = .uniform
        let uniform = try XCTUnwrap(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec))
        // Same place on the circle, same orientation: still 10 long in x, centered on (0, 25).
        let kept = try bounds(try XCTUnwrap(uniform.workspace.bodies.first { $0.id == uniform.bodies[0] }))
        XCTAssertEqual(kept.max.x - kept.min.x, 10, accuracy: 1e-6)
        XCTAssertEqual((kept.min.x + kept.max.x) / 2, 0, accuracy: 1e-6)
        XCTAssertEqual((kept.min.y + kept.max.y) / 2, 25, accuracy: 1e-6)
    }

    func testSketchPatternCopiesItsShapesOntoMovedPlanes() throws {
        var workspace = Workspace()
        let sketch = Sketch(id: UUID(), plane: .top)
        workspace.sketches = [sketch]
        var circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 3, y: 0))
        circle.sketch = sketch.id
        workspace.shapes = [circle]
        var spec = PatternSpec(center: .zero, axes: axes)
        spec.directions[1].count = 3
        spec.definition = .spacing
        spec.directions[1].distance = 15
        let result = try XCTUnwrap(Patterning.pattern(workspace, bodies: [], sketches: [sketch.id], spec: spec))
        XCTAssertEqual(result.sketches.count, 2)
        XCTAssertEqual(result.workspace.sketches.map(\.id), [sketch.id] + result.sketches)
        XCTAssertEqual(result.workspace.shapes.count, 3)
        for (index, id) in result.sketches.enumerated() {
            let copy = try XCTUnwrap(result.workspace.sketch(id))
            XCTAssertEqual(copy.plane.origin.y, Double(index + 1) * 15, accuracy: 1e-9)
            let shapes = result.workspace.shapes.filter { $0.sketch == id }
            XCTAssertEqual(shapes.map(\.kind), [.circle])
            XCTAssertEqual(shapes.first?.plane, copy.plane)
        }
    }

    func testPatternsNeedCopiesAndStayUnderTheLimit() throws {
        let original = try block()
        var workspace = Workspace()
        workspace.bodies = [original]
        var spec = PatternSpec(center: .zero, axes: axes)
        XCTAssertNil(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec), "No distance yet")
        spec.directions[0].count = 11
        spec.directions[0].distance = 200
        spec.directions[1].count = 10
        spec.directions[1].distance = 100
        XCTAssertEqual(spec.instanceCount, 110)
        XCTAssertNil(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec, checked: false), "Over the limit")
        spec.directions[0].count = 10
        XCTAssertEqual(Patterning.pattern(workspace, bodies: [original.id], sketches: [], spec: spec, checked: false)?.bodies.count, 99)
    }
}

