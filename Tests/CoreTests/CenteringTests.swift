import XCTest
@testable import SwipeAndSketchCore

/// Phase 2 centering aids: alignment with guide points and rectangles drawn from their center.
final class CenteringTests: XCTestCase {
    /// Guides of a 60 × 40 face centered on the origin.
    let guides = [SketchGuide(point: .init(x: -30, y: -20), kind: .corner), SketchGuide(point: .init(x: 30, y: 20), kind: .corner),
                  SketchGuide(point: .init(x: 0, y: 20), kind: .midpoint), SketchGuide(point: .init(x: -30, y: 0), kind: .midpoint),
                  SketchGuide(point: .zero, kind: .center)]

    func snap(_ x: Double, _ y: Double, start: Point2? = nil, align: Bool = false) -> SnapResult {
        SketchSnap.snap(.init(x: x, y: y), start: start, shapes: [], plane: .top, grid: 1, tolerance: 0.8, align: align, guides: guides)
    }

    func testVerticalAlignmentWithAGuideKeepsTheOtherAxisOnTheGrid() {
        let result = snap(0.6, 11.3)
        XCTAssertEqual(result.point, .init(x: 0, y: 11))
        XCTAssertEqual(result.label, "Vertical")
        XCTAssertEqual(result.alignedTo, [.init(x: 0, y: 20)], "The center and top midpoint tie in x; the nearer one draws the guide")
    }

    func testTwoAlignmentsLockToTheirCrossing() {
        // Vertical through the top midpoint (x = 0) and horizontal through the left midpoint (y = 0)
        // is the face center, even when the Pencil is just outside snapping distance of the dot.
        let crossing = SketchSnap.snap(.init(x: 0.5, y: -0.6), shapes: [], plane: .top, grid: 1, tolerance: 0.7,
                                       guides: [SketchGuide(point: .init(x: 0, y: 20), kind: .midpoint),
                                                SketchGuide(point: .init(x: -30, y: 0), kind: .midpoint)])
        XCTAssertEqual(crossing.point, .zero)
        XCTAssertEqual(crossing.label, "Aligned")
        XCTAssertEqual(crossing.alignedTo.count, 2)
    }

    func testPointSnapsStillWinAndLineStartAlignmentIsUnchanged() {
        XCTAssertEqual(snap(29.6, 19.7).label, "Endpoint")
        let line = SketchSnap.snap(.init(x: 12.3, y: 5.4), start: .init(x: 12, y: 50), shapes: [], plane: .top, grid: 1, tolerance: 0.8)
        XCTAssertEqual(line.point.x, 12)
        XCTAssertEqual(line.label, "Vertical")
        let nothing = SketchSnap.snap(.init(x: 7.3, y: 8.6), shapes: [], plane: .top, grid: 1, tolerance: 0.8, guides: guides)
        XCTAssertEqual(nothing.label, "Grid")
        XCTAssertTrue(nothing.alignedTo.isEmpty)
    }

    func centered(_ halfWidth: Double, _ halfHeight: Double, at c: Point2 = .zero) -> SketchShape {
        SketchShape(kind: .rectangle, plane: .top, start: .init(x: c.x - halfWidth, y: c.y - halfHeight),
                    end: .init(x: c.x + halfWidth, y: c.y + halfHeight), centered: true)
    }

    func testCenteredRectangleDimensionsGrowEvenlyAboutTheCenter() throws {
        let rectangle = centered(10, 5, at: .init(x: 3, y: -2))
        let wider = try XCTUnwrap(SketchEditing.dimension(.width, value: 30, of: rectangle))
        XCTAssertEqual(wider.center, rectangle.center)
        XCTAssertEqual(ShapeDimension.width.value(of: wider), 30, accuracy: 1e-12)
        let taller = try XCTUnwrap(SketchEditing.dimension(.height, value: 4, of: wider))
        XCTAssertEqual(taller.center, rectangle.center)
        XCTAssertEqual(ShapeDimension.height.value(of: taller), 4, accuracy: 1e-12)
        // An ordinary rectangle still grows from its first corner.
        var corner = rectangle; corner.centered = nil
        XCTAssertEqual(try XCTUnwrap(SketchEditing.dimension(.width, value: 30, of: corner)).start, corner.start)
    }

    func testCenteredRectangleDragsAreSymmetricAndTheCenterHandleMovesIt() throws {
        let rectangle = centered(10, 5)
        let corner = try XCTUnwrap(SketchEditing.dragging(rectangle, handle: .corner(2), to: .init(x: 14, y: 8)))
        XCTAssertEqual(corner.start, .init(x: -14, y: -8))
        XCTAssertEqual(corner.end, .init(x: 14, y: 8))
        let side = try XCTUnwrap(SketchEditing.dragging(rectangle, handle: .side(1), to: .init(x: 12, y: 3)))
        XCTAssertEqual(side.start, .init(x: -12, y: -5), "A side handle changes only its own axis")
        XCTAssertEqual(SketchEditing.handlePoint(.center, on: rectangle), .zero)
        let moved = try XCTUnwrap(SketchEditing.dragging(rectangle, handle: .center, to: .init(x: 7, y: -4)))
        XCTAssertEqual(moved.center, .init(x: 7, y: -4))
        XCTAssertEqual(ShapeDimension.width.value(of: moved), 20, accuracy: 1e-12)
    }

    func testCenteredSlotsStayCenteredWhenTheirEndsOrLengthChange() throws {
        let slot = SketchShape.slot(from: .init(x: -8, y: 1), to: .init(x: 12, y: 1), width: 6, plane: .top, centered: true)
        XCTAssertTrue(slot.isCentered)
        XCTAssertEqual(slot.center, .init(x: 2, y: 1))
        let longer = try XCTUnwrap(SketchEditing.dimension(.length, value: 30, of: slot))
        XCTAssertEqual(longer.start, .init(x: -13, y: 1))
        XCTAssertEqual(longer.end, .init(x: 17, y: 1))
        XCTAssertEqual(longer.width, 6)
        // Dragging either end swings and stretches the slot about its center.
        let dragged = try XCTUnwrap(SketchEditing.dragging(slot, handle: .start, to: .init(x: 2, y: -9)))
        XCTAssertEqual(dragged.start, .init(x: 2, y: -9))
        XCTAssertEqual(dragged.end, .init(x: 2, y: 11))
        let end = try XCTUnwrap(SketchEditing.dragging(slot, handle: .end, to: .init(x: 7, y: 1)))
        XCTAssertEqual(end.start, .init(x: -3, y: 1))
        XCTAssertEqual(SketchEditing.handlePoint(.center, on: slot), slot.center)
        let moved = try XCTUnwrap(SketchEditing.dragging(slot, handle: .center, to: .init(x: -5, y: 4)))
        XCTAssertEqual(moved.start, .init(x: -15, y: 4))
        XCTAssertEqual(moved.end, .init(x: 5, y: 4))
        let wider = try XCTUnwrap(SketchEditing.dragging(slot, handle: .side(0), to: .init(x: 2, y: 6)))
        XCTAssertEqual(wider.width ?? 0, 10, accuracy: 1e-12)
        XCTAssertEqual(wider.center, slot.center)
        // An ordinary slot still grows from its first end, and its ends move alone.
        let plain = SketchShape.slot(from: .init(x: -8, y: 1), to: .init(x: 12, y: 1), width: 6, plane: .top)
        XCTAssertFalse(plain.isCentered)
        XCTAssertEqual(try XCTUnwrap(SketchEditing.dimension(.length, value: 30, of: plain)).start, plain.start)
        XCTAssertEqual(try XCTUnwrap(SketchEditing.dragging(plain, handle: .start, to: .init(x: 2, y: -9))).end, plain.end)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("centered"))
        XCTAssertTrue(try JSONDecoder().decode(SketchShape.self, from: JSONEncoder().encode(slot)).isCentered)
    }

    func testCenteredFlagRoundTripsAndPlainShapesEncodeAsBefore() throws {
        let plain = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 4, y: 3))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("centered"))
        let rectangle = centered(4, 3)
        let decoded = try JSONDecoder().decode(SketchShape.self, from: JSONEncoder().encode(rectangle))
        XCTAssertTrue(decoded.isCentered)
    }
}
