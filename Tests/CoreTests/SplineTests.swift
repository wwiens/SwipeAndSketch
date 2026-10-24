import XCTest
import simd
@testable import SwipeAndSketchCore

/// Splines: smooth curves through points, drawn from a stroke (October 24, 2026).
final class SplineTests: XCTestCase {
    func testASplinePassesThroughItsPoints() throws {
        let points = [Point2(x: 0, y: 0), Point2(x: 10, y: 8), Point2(x: 20, y: 0), Point2(x: 30, y: 8)]
        let spline = try XCTUnwrap(SketchShape.spline(through: points, closed: false, plane: .top))
        XCTAssertTrue(spline.isSpline)
        let outline = spline.outline
        XCTAssertEqual(outline.count, 3 * 16 + 1)
        for point in points { XCTAssertTrue(outline.contains { $0.distance(to: point) < 1e-9 }, "Through \(point)") }
        XCTAssertGreaterThan(Geometry.distance(outline[8], toSegment: points[0], points[1]), 0.1, "Smooth: it bows between its points")
        XCTAssertNil(SketchShape.spline(through: [.zero], closed: false, plane: .top))
    }

    func testAClosedSplineBoundsARegionThatExtrudes() throws {
        let points = [Point2(x: 0, y: 0), Point2(x: 20, y: 0), Point2(x: 20, y: 20), Point2(x: 0, y: 20)]
        var spline = try XCTUnwrap(SketchShape.spline(through: points, closed: true, plane: .top))
        spline.sketch = spline.id
        let profile = try XCTUnwrap(Geometry.profiles(in: [spline], on: .top).first)
        XCTAssertGreaterThan(profile.area, 400, "A rounded square bowing out through its corners")
        XCTAssertLessThan(profile.area, 700)
        let solid = try SolidKernel.solid(for: SolidBody(profile: profile, depth: 5))
        XCTAssertEqual(solid.volume, profile.area * 5, accuracy: 1)
    }

    func testDraggingAPointReshapesTheCurveAndMovingCarriesIt() throws {
        let points = [Point2(x: 0, y: 0), Point2(x: 10, y: 10), Point2(x: 20, y: 0)]
        let spline = try XCTUnwrap(SketchShape.spline(through: points, closed: false, plane: .top))
        let dragged = try XCTUnwrap(SketchEditing.dragging(spline, handle: .corner(1), to: Point2(x: 10, y: 20)))
        XCTAssertEqual(dragged.points?[1], Point2(x: 10, y: 20))
        XCTAssertTrue(dragged.outline.contains { $0.distance(to: Point2(x: 10, y: 20)) < 1e-9 })
        let end = try XCTUnwrap(SketchEditing.dragging(spline, handle: .corner(2), to: Point2(x: 25, y: 5)))
        XCTAssertEqual(end.end, Point2(x: 25, y: 5), "Its end follows its last point")
        let moved = try XCTUnwrap(SketchTools.transformed(spline, by: Point2(x: 5, y: 0), turning: 0, about: .zero))
        XCTAssertEqual(moved.isSpline, true)
        XCTAssertEqual(moved.outline[8].x, spline.outline[8].x + 5, accuracy: 1e-9)
    }

    func testAStrokeIsFittedWithFewPoints() {
        // A wavy stroke of 200 samples.
        let stroke = (0...200).map { i -> Point2 in let x = Double(i) * 0.2; return Point2(x: x, y: 5 * sin(x / 5)) }
        let fitted = SketchShape.splinePoints(fitting: stroke, tolerance: 0.3)
        XCTAssertLessThan(fitted.count, 15)
        XCTAssertEqual(fitted.first, stroke.first)
        XCTAssertEqual(fitted.last, stroke.last)
        let curve = SketchShape.splineOutline(fitted, closed: false)
        for sample in stride(from: 0, to: stroke.count, by: 10) {
            let nearest = curve.map { $0.distance(to: stroke[sample]) }.min() ?? .infinity
            XCTAssertLessThan(nearest, 0.6, "The curve follows the stroke")
        }
        XCTAssertLessThanOrEqual(SketchShape.splinePoints(fitting: stroke, tolerance: 0.001, maximum: 6).count, 6)
    }

    func testSplinesAreSaved() throws {
        let spline = try XCTUnwrap(SketchShape.spline(through: [.zero, Point2(x: 5, y: 5), Point2(x: 10, y: 0)], closed: false, plane: .top))
        let data = try JSONEncoder().encode(spline)
        XCTAssertEqual(try JSONDecoder().decode(SketchShape.self, from: data), spline)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"spline\":true"))
    }
}

extension SplineTests {
    func testAssistantDrawsASpline() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        let text = try bench.addShapes([.init(kind: .spline, point: [0, 0, 0], points: [[10, 10, 0], [20, 0, 0]])], on: .world(.top))
        XCTAssertTrue(text.contains("spline through 3 points"), text)
        XCTAssertEqual(bench.workspace.shapes.first?.isSpline, true)
    }
}
