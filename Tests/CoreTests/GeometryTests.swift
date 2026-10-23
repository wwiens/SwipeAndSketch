import XCTest
@testable import SwipeAndSketchCore

final class GeometryTests: XCTestCase {
    func line(_ a: Point2, _ b: Point2, plane: SketchPlane = .top) -> SketchShape {
        SketchShape(kind: .line, plane: plane, start: a, end: b)
    }
    func testClosedConnectedLinesCreateProfileRegardlessOfDrawingDirection() {
        let a = Point2(x: 0, y: 0), b = Point2(x: 30, y: 0)
        let c = Point2(x: 30, y: 20), d = Point2(x: 0, y: 20)
        let shapes = [line(b, a), line(b, c), line(d, c), line(a, d)]
        let profiles = Geometry.profiles(in: shapes, on: .top)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 600, accuracy: 0.0001)
        XCTAssertEqual(profiles[0].center.x, 15, accuracy: 0.0001)
        XCTAssertEqual(profiles[0].sourceIDs.count, 4)
    }
    func testOpenAndSelfIntersectingOutlinesDoNotBecomeSolids() {
        let a = Point2(x: 0, y: 0), b = Point2(x: 20, y: 20)
        let c = Point2(x: 0, y: 20), d = Point2(x: 20, y: 0)
        XCTAssertTrue(Geometry.profiles(in: [line(a, b), line(b, c)], on: .top).isEmpty)
        // A crossed outline (a bow tie) divides at its crossing into two triangles.
        let bowTie = Geometry.profiles(in: [line(a, b), line(b, c), line(c, d), line(d, a)], on: .top)
        XCTAssertEqual(bowTie.count, 2)
        XCTAssertEqual(bowTie.map(\.area), [100, 100])
        XCTAssertTrue(bowTie.allSatisfy(\.isSolidProfile))
    }
    func testConcaveProfileAndDanglingLine() {
        let points = [Point2(x: 0, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 10),
                      .init(x: 10, y: 10), .init(x: 10, y: 30), .init(x: 0, y: 30)]
        var shapes = points.indices.map { line(points[$0], points[($0 + 1) % points.count]) }
        shapes.append(line(points[0], Point2(x: -10, y: -10)))
        let profiles = Geometry.profiles(in: shapes, on: .top)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.area, 500)
        XCTAssertTrue(Geometry.contains(.init(x: 5, y: 25), in: profiles[0].outline))
        XCTAssertFalse(Geometry.contains(.init(x: 20, y: 20), in: profiles[0].outline))
    }
    func testPlanesKeepUnrelatedSegmentsSeparate() {
        let shapes = [line(.zero, .init(x: 10, y: 0)),
                      line(.init(x: 10, y: 0), .init(x: 0, y: 10)),
                      line(.init(x: 0, y: 10), .zero, plane: .front)]
        XCTAssertTrue(Geometry.profiles(in: shapes, on: .top).isEmpty)
    }
    func testCircleAndRectangleAreClosedWithAnalyticCirclePreserved() {
        let shapes = [SketchShape(kind: .circle, plane: .right, start: .init(x: -20, y: 0), end: .init(x: -10, y: 0)),
                      SketchShape(kind: .rectangle, plane: .right, start: .init(x: 30, y: 20), end: .zero)]
        let profiles = Geometry.profiles(in: shapes, on: .right)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].circle?.radius, 10)
        XCTAssertEqual(profiles[1].area, 600)
        XCTAssertTrue(SolidBody(profile: profiles[0], depth: -12).isValid)
        XCTAssertFalse(SolidBody(profile: profiles[0], depth: 0).isValid)
    }
    func testSnappingPrioritizesEndpointsAndOnlyUsesActivePlane() {
        let shapes = [line(.init(x: 10.25, y: 20.75), .init(x: 40, y: 20.75)),
                      line(.init(x: 10.3, y: 20.7), .init(x: 50, y: 20), plane: .front)]
        let snap = SketchSnap.snap(.init(x: 10.3, y: 20.8), shapes: shapes, plane: .top, grid: 1, tolerance: 1)
        XCTAssertEqual(snap.point, shapes[0].start)
        XCTAssertEqual(snap.label, "Endpoint")
        let aligned = SketchSnap.snap(.init(x: 35.2, y: 6.3), start: .init(x: 2, y: 6.25), shapes: [], plane: .top, grid: 1, tolerance: 0.5)
        XCTAssertEqual(aligned.point, .init(x: 35, y: 6.25))
        XCTAssertEqual(aligned.label, "Horizontal")
    }
    func testInvalidGeometryRejected() {
        XCTAssertFalse(SketchShape(kind: .line, plane: .top, start: .zero, end: .zero).isValid)
        XCTAssertFalse(SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: .nan, y: 2)).isValid)
        XCTAssertFalse(Geometry.isSimplePolygon([.zero, .init(x: 1, y: 0), .init(x: 2, y: 0)]))
    }

    func testLongOutlinesAreCheckedQuicklyAndStillCatchCrossings() {
        // A 4096-point circle (as projected curves are) is simple; one stray point that crosses is caught.
        var circle = (0..<4096).map { i -> Point2 in
            let a = Double(i) / 4096 * 2 * .pi
            return Point2(x: 50 * cos(a), y: 50 * sin(a))
        }
        let start = Date()
        XCTAssertTrue(Geometry.isSimplePolygon(circle))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        circle[1000] = Point2(x: -60, y: 0)
        XCTAssertFalse(Geometry.isSimplePolygon(circle))
        // A long strip, and the same bottom edge with a closing point that crosses it (both take the grid path).
        let strip = (0...40).map { Point2(x: Double($0), y: 0) } + (0...40).map { Point2(x: Double(40 - $0), y: 10) }
        XCTAssertTrue(Geometry.isSimplePolygon(strip))
        let crossed = (0...80).map { Point2(x: Double($0) / 2, y: 0) } + [Point2(x: 40, y: 10), Point2(x: 0, y: 10), Point2(x: 20, y: -5)]
        XCTAssertFalse(Geometry.isSimplePolygon(crossed))
    }
}
