import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// Pattern through the real Pencil pipeline.
@MainActor final class PatternToolTests: CanvasTestCase {
    func bounds(_ body: SolidBody) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try SolidKernel.solid(for: body).bounds }

    /// A Pencil drag through screen points.
    func drag(_ controller: CanvasController, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        controller.pencilBegan(at: first)
        for point in points.dropFirst() { controller.pencilMoved(to: point) }
        controller.pencilEnded(at: points.last!, cancelled: false)
        controller.refresh()
    }

    func testLinearPatternFromADraggedArrow() throws {
        let (session, controller) = boxScene()
        let original = session.workspace.bodies[0]
        session.select(.body(original.id))
        session.chooseTool(.pattern)
        controller.refresh()
        XCTAssertEqual(session.tool, .pattern)
        XCTAssertEqual(session.patternDraft?.bodies, [original.id], "The selected solid is the one to pattern")
        XCTAssertNotNil(controller.previewNode.childNode(withName: "pattern.items", recursively: false))
        let widget = try XCTUnwrap(controller.patternWidget())
        XCTAssertTrue(widget.arcs.isEmpty, "A linear pattern has arrows only")
        let arrow = try XCTUnwrap(widget.arrows.first { $0.axis == 0 })
        // Drag the x arrow 80 mm outward.
        let start = CGPoint(x: (arrow.base.x + arrow.tip.x) / 2, y: (arrow.base.y + arrow.tip.y) / 2)
        let reach = CGFloat(80 * arrow.pointsPerMillimeter)
        drag(controller, (0...8).map { CGPoint(x: start.x + arrow.direction.dx * reach * CGFloat($0) / 8, y: start.y + arrow.direction.dy * reach * CGFloat($0) / 8) })
        let draft = try XCTUnwrap(session.patternDraft)
        XCTAssertEqual(draft.spec.directions[0].distance, 80, accuracy: 1)
        XCTAssertEqual(session.patternPreview?.bodies.count, 3, "Three instances by default, the original included")
        XCTAssertEqual(session.workspace.bodies.count, 1, "A preview until Done")
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .patternDistance(0) }, "Its distance shows past the arrow")
        attach(controller, "Linear pattern preview")
        // Type the total, then the quantity: five across 140 mm, 35 mm apart.
        XCTAssertTrue(session.applyDimension(140, target: .patternDistance(0)))
        XCTAssertTrue(session.applyDimension(5, target: .patternCount))
        XCTAssertFalse(session.applyDimension(2.5, target: .patternCount), "A whole number")
        XCTAssertFalse(session.setPatternCount(101), "At most 100")
        XCTAssertEqual(session.patternPreview?.bodies.count, 5)
        session.confirmPattern()
        controller.refresh()
        XCTAssertEqual(session.tool, .select)
        XCTAssertNil(session.patternDraft)
        let bodies = session.workspace.bodies
        XCTAssertEqual(bodies.count, 5)
        XCTAssertEqual(bodies[0], original, "The original stays")
        for (index, body) in bodies.enumerated() {
            XCTAssertEqual(try bounds(body).min.x, -30 + Double(index) * 35, accuracy: 1e-6)
        }
        XCTAssertEqual(session.selection, .body(bodies[1].id), "The first copy is selected")
        XCTAssertEqual(session.itemGroups.first?.items.map(\.name), ["Body 01", "Body 02", "Body 03", "Body 04", "Body 05"])
        attach(controller, "Linear pattern")
        session.undo()
        XCTAssertEqual(session.workspace.bodies.count, 1, "The whole pattern was one step")
    }

    func testSpacingAndASecondDirectionMakeAGrid() throws {
        let (session, _) = boxScene()
        session.select(.body(session.workspace.bodies[0].id))
        session.chooseTool(.pattern)
        session.setPatternDefinition(.spacing)
        session.setPatternDistance(70, axis: 0)
        session.setPatternDistance(-50, axis: 1)
        XCTAssertTrue(session.setPatternCount(2))
        XCTAssertEqual(session.patternDraft?.linearAxis, 1, "The quantity follows the last direction dragged")
        XCTAssertEqual(session.patternPreview?.bodies.count, 6, "Three along x by two along y")
        session.confirmPattern()
        let corners = try session.workspace.bodies.map { try bounds($0).min }
        XCTAssertTrue(corners.contains { abs($0.x - 110) < 1e-6 && abs($0.y + 70) < 1e-6 }, "140 mm along x and 50 mm back along y")
    }

    func testCircularPatternAboutTheOriginTurnsCopies() throws {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: 40, y: -5), end: .init(x: 50, y: 5)))
        session.beginExtrusion()
        session.extrusionDepth = 10
        session.confirmExtrusion()
        session.select(.body(session.workspace.bodies[0].id))
        let controller = canvas(session)
        session.chooseTool(.pattern)
        session.setPatternKind(.circular)
        controller.refresh()
        var widget = try XCTUnwrap(controller.patternWidget())
        XCTAssertTrue(widget.arrows.isEmpty && !widget.arcs.isEmpty && widget.canPivot, "Rings and a center to drag")
        // Drag the gizmo center onto the origin.
        let origin = controller.project(SIMD3<Float>(0, 0, 0))
        drag(controller, (0...6).map { CGPoint(x: widget.center.x + (origin.x - widget.center.x) * CGFloat($0) / 6,
                                               y: widget.center.y + (origin.y - widget.center.y) * CGFloat($0) / 6) })
        XCTAssertEqual(session.patternDraft?.placedCenter, .origin)
        XCTAssertEqual(simd_length(session.patternDraft?.center ?? SIMD3(1, 1, 1)), 0, accuracy: 1e-9)
        XCTAssertFalse(session.isDraggingPatternCenter)
        // Turn the ring about the normal a little.
        widget = try XCTUnwrap(controller.patternWidget())
        let ring = try XCTUnwrap(widget.arcs.first { $0.axis == 2 })
        let middle = ring.points[ring.points.count / 2]
        let radius = hypot(middle.x - widget.center.x, middle.y - widget.center.y)
        let start = atan2(middle.y - widget.center.y, middle.x - widget.center.x)
        drag(controller, (0...6).map { step in
            let angle = start - 0.1 * CGFloat(step)
            return CGPoint(x: widget.center.x + cos(angle) * radius, y: widget.center.y + sin(angle) * radius)
        })
        XCTAssertEqual(session.patternDraft?.circularAxis, 2)
        XCTAssertGreaterThan(abs(session.patternDraft?.spec.angle ?? 0), 10, "The ring turned the pattern")
        XCTAssertTrue(controller.dimensionAnnotations().contains { $0.target == .patternAngle })
        // A whole turn of four.
        XCTAssertFalse(session.applyDimension(400, target: .patternAngle), "A total is at most a whole turn")
        XCTAssertTrue(session.applyDimension(360, target: .patternAngle))
        XCTAssertTrue(session.setPatternCount(4))
        attach(controller, "Circular pattern preview")
        session.confirmPattern()
        let bodies = session.workspace.bodies
        XCTAssertEqual(bodies.count, 4)
        // The quarter turn carries the block from +x to +y.
        let quarter = try bounds(bodies[1])
        XCTAssertEqual(quarter.min.x, -5, accuracy: 1e-6)
        XCTAssertEqual(quarter.max.x, 5, accuracy: 1e-6)
        XCTAssertEqual(quarter.min.y, 40, accuracy: 1e-6)
        XCTAssertEqual(quarter.max.y, 50, accuracy: 1e-6)
    }

    func testItemsArePickedOnTheCanvasAndInItems() throws {
        let (session, controller) = boxScene()
        session.addShape(.init(kind: .circle, plane: .top, start: .init(x: 80, y: 0), end: .init(x: 85, y: 0)))
        let body = session.workspace.bodies[0].id
        let sketch = try XCTUnwrap(session.workspace.shapes.last?.sketch)
        session.select(nil)
        session.chooseTool(.pattern)
        controller.refresh()
        XCTAssertNil(controller.patternWidget(), "No gizmo until something is picked")
        tap(controller, SIMD3(0, 0, 20))
        XCTAssertEqual(session.patternDraft?.bodies, [body], "A tap on the solid picks it")
        session.selectItem(.sketch(sketch))
        XCTAssertEqual(session.patternDraft?.sketches, [sketch], "So does its Items row")
        tap(controller, SIMD3(0, 0, 20))
        XCTAssertEqual(session.patternDraft?.bodies, [], "Tapping again unpicks it")
        session.setPatternDistance(30, axis: 1)
        let sketches = session.workspace.sketches.count
        XCTAssertEqual(session.patternPreview?.sketches.count, sketches + 2)
        session.confirmPattern()
        XCTAssertEqual(session.workspace.sketches.count, sketches + 2)
        XCTAssertEqual(session.workspace.shapes.filter { $0.kind == .circle }.count, 3)
        let index = try XCTUnwrap(session.workspace.sketches.firstIndex { $0.id == sketch })
        XCTAssertEqual(session.selection, .sketch(session.workspace.sketches[index + 1].id), "The first copy is selected, right after the original")
    }

    func testCancelLeavesTheModelAsItWas() {
        let (session, _) = boxScene()
        let before = session.workspace
        session.select(.body(before.bodies[0].id))
        session.chooseTool(.pattern)
        session.setPatternDistance(80, axis: 0)
        XCTAssertNotNil(session.patternPreview)
        session.cancelPattern()
        XCTAssertNil(session.patternDraft)
        XCTAssertNil(session.patternPreview)
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(session.workspace, before)
    }

    func testPreviewCopiesArePlacedPicturesSoDraggingStaysQuick() throws {
        let (session, controller) = boxScene()
        session.chooseTool(.fitTest)
        let plate = session.workspace.bodies[1]
        session.select(.body(plate.id))
        session.chooseTool(.pattern)
        session.setPatternDistance(120, axis: 0)
        XCTAssertTrue(session.setPatternCount(24))
        controller.refresh()
        let copies = try XCTUnwrap(session.patternPreview).bodies.filter { !session.workspace.bodies.map(\.id).contains($0.id) }
        XCTAssertEqual(copies.count, 23)
        // Each copy is drawn as the plate's picture, moved.
        let last = try XCTUnwrap(copies.last)
        let node = try XCTUnwrap(controller.content.childNode(withName: "body|" + last.id.uuidString, recursively: false))
        XCTAssertEqual(node.simdTransform.columns.3.x, 120, accuracy: 1e-3)
        XCTAssertEqual(session.patternGhosts[last.id]?.source, plate.id)
        // Every drag step rebuilds the preview; none rebuilds or re-meshes the copies.
        let start = Date()
        for step in 0..<10 {
            session.setPatternDistance(120 + Double(step) * 3, axis: 0)
            controller.refresh()
        }
        let perStep = Date().timeIntervalSince(start) / 10
        print("[pattern timing] 24 Fit Test plates, per drag step: \(Int(perStep * 1000)) ms")
        XCTAssertLessThan(perStep, 0.25)
        session.confirmPattern()
        XCTAssertEqual(session.workspace.bodies.count, 3 + 23)
        XCTAssertTrue(session.patternGhosts.isEmpty)
        XCTAssertEqual(try bounds(session.workspace.bodies[24]).min.x, try bounds(plate).min.x + 147, accuracy: 1e-6, "The last copy, before the peg piece")
    }
}
