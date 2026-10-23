import XCTest
@testable import SwipeAndSketchCore

final class EditingTests: XCTestCase {
    func testRectangleCornersKeepOppositeCornerFixedIncludingReversedRectangles() throws {
        for reversed in [false, true] {
            let shape = SketchShape(kind: .rectangle, plane: .top, start: reversed ? .init(x: 30, y: 20) : .zero,
                                    end: reversed ? .zero : .init(x: 30, y: 20))
            for index in 0..<4 {
                let opposite = shape.outline[(index + 2) % 4]
                let moved = shape.outline[index] + Point2(x: 4, y: 6)
                let updated = try XCTUnwrap(SketchEditing.dragging(shape, handle: .corner(index), to: moved))
                XCTAssertTrue(updated.outline.contains(opposite))
                XCTAssertTrue(updated.outline.contains(moved))
            }
        }
    }
    func testRectangleSidesResizeOnlyTheirAxis() throws {
        let shape = SketchShape(kind: .rectangle, plane: .front, start: .zero, end: .init(x: 30, y: 20))
        for index in 0..<4 {
            let point = SketchEditing.handlePoint(.side(index), on: shape) + Point2(x: 4, y: 6)
            let updated = try XCTUnwrap(SketchEditing.dragging(shape, handle: .side(index), to: point))
            if index.isMultiple(of: 2) { XCTAssertEqual(ShapeDimension.width.value(of: updated), 30) }
            else { XCTAssertEqual(ShapeDimension.height.value(of: updated), 20) }
        }
    }
    func testCircleCenterTranslationAndCircumferenceResize() throws {
        let circle = SketchShape(kind: .circle, plane: .right, start: .init(x: 10, y: 20), end: .init(x: 20, y: 20))
        let moved = try XCTUnwrap(SketchEditing.dragging(circle, handle: .center, to: .init(x: 30, y: 40)))
        XCTAssertEqual(moved.end, .init(x: 40, y: 40))
        let resized = try XCTUnwrap(SketchEditing.dragging(circle, handle: .radius, to: .init(x: 10, y: 35)))
        XCTAssertEqual(resized.start, circle.start)
        XCTAssertEqual(ShapeDimension.diameter.value(of: resized), 30)
    }
    func testJoinedLineEndpointsFollowAndOtherPlanesStayUnchanged() throws {
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 20, y: 0))
        let b = SketchShape(kind: .line, plane: .top, start: a.end, end: .init(x: 10, y: 20))
        let c = SketchShape(kind: .line, plane: .top, start: b.end, end: a.start)
        let otherPlane = SketchShape(kind: .line, plane: .front, start: a.end, end: .init(x: 10, y: 20))
        let document = Workspace(shapes: [a, b, c, otherPlane])
        let updated = try XCTUnwrap(SketchEditing.dragging(a, handle: .end, to: .init(x: 30, y: 5)))
        let result = try XCTUnwrap(SketchEditing.replacing(updated, in: document))
        XCTAssertEqual(result.shapes[1].start, updated.end)
        XCTAssertEqual(result.shapes[3], document.shapes[3], "The line on Front is untouched")
        XCTAssertEqual(Geometry.profiles(in: result.shapes, on: .top).count, 1)
    }
    func testDegenerateConnectedEdgeIsRejected() {
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 20, y: 0))
        let b = SketchShape(kind: .line, plane: .top, start: a.end, end: .init(x: 30, y: 0))
        var updated = a; updated.end = b.end
        XCTAssertNil(SketchEditing.replacing(updated, in: Workspace(shapes: [a, b])))
        XCTAssertNil(SketchEditing.dragging(a, handle: .end, to: .zero))
    }
    func testDimensionsKeepAnchorAndCircleDirection() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 0, y: 10))
        let changed = try XCTUnwrap(SketchEditing.dimension(.diameter, value: 30, of: circle))
        XCTAssertEqual(changed.end, .init(x: 0, y: 15))
        XCTAssertNil(SketchEditing.dimension(.diameter, value: -1, of: circle))
    }
    func testDimensionCalculatorPrecedenceUnitsAndInvalidInput() {
        XCTAssertEqual(DimensionExpression.evaluate("(24 + 6) ÷ 2"), 15)
        XCTAssertEqual(DimensionExpression.evaluate("2cm + 4mm"), 24)
        XCTAssertEqual(DimensionExpression.evaluate("0.025m"), 25)
        XCTAssertEqual(DimensionExpression.evaluate("-(5 + 2) × 3"), -21)
        XCTAssertEqual(DimensionExpression.evaluate("2,5 * 4"), 10)
        for invalid in ["", "1/0", "24+", "1..2", "(5+2", "inf", "nan", "20kg", String(repeating: "9", count: 129)] {
            XCTAssertNil(DimensionExpression.evaluate(invalid), invalid)
        }
    }
}
