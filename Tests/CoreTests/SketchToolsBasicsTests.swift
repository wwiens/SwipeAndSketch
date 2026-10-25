import XCTest
import simd
@testable import SwipeAndSketchCore

/// Polygon, Ellipse, Point, construction geometry, Extend, Mirror in a sketch, moving shapes, and Offset.
final class SketchToolsBasicsTests: XCTestCase {
    func sketch(_ shapes: [SketchShape]) -> Workspace { Workspace(shapes: shapes) }

    func testPolygonsAreJoinedLinesThatMakeARegion() throws {
        let lines = SketchTools.polygon(center: .zero, vertex: .init(x: 10, y: 0), sides: 6, plane: .top)
        XCTAssertEqual(lines.count, 6)
        for (a, b) in zip(lines, lines.dropFirst() + lines.prefix(1)) { XCTAssertEqual(a.end, b.start) }
        let region = try XCTUnwrap(Geometry.profiles(in: lines, on: .top).first)
        XCTAssertEqual(region.area, 3 * 3.squareRoot() / 2 * 100, accuracy: 1e-6)
        XCTAssertTrue(SketchTools.polygon(center: .zero, vertex: .init(x: 10, y: 0), sides: 2, plane: .top).isEmpty)
    }

    func testEllipsesAreExactRegionsAndHoles() throws {
        let ellipse = SketchShape(kind: .ellipse, plane: .top, start: .zero, end: .init(x: 10, y: 0), width: 8)
        XCTAssertTrue(ellipse.isValid)
        XCTAssertEqual(ShapeDimension.width.value(of: ellipse), 20)
        XCTAssertEqual(ShapeDimension.height.value(of: ellipse), 8)
        let region = try XCTUnwrap(Geometry.profiles(in: [ellipse], on: .top).first)
        XCTAssertNotNil(region.ellipse)
        XCTAssertEqual(try SolidKernel.extrude(region, depth: 2).volume, .pi * 10 * 4 * 2, accuracy: 1e-6)
        // Inside a rectangle it is a hole.
        let plate = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -20, y: -20), end: .init(x: 20, y: 20))
        let regions = Geometry.profiles(in: [plate, ellipse], on: .top)
        let outer = try XCTUnwrap(regions.first { $0.sourceIDs == [plate.id] })
        XCTAssertNotNil(outer.holes?.first?.ellipse)
        XCTAssertEqual(try SolidKernel.extrude(outer, depth: 1).volume, 1600 - .pi * 40, accuracy: 1e-6)
        // Resized by its dimensions, and dragged by its side handle.
        let wider = try XCTUnwrap(SketchEditing.dimension(.width, value: 30, of: ellipse))
        XCTAssertEqual(wider.end, .init(x: 15, y: 0))
        let taller = try XCTUnwrap(SketchEditing.dragging(ellipse, handle: .side(0), to: .init(x: 3, y: 6)))
        XCTAssertEqual(taller.width ?? 0, 12, accuracy: 1e-12)
        // Mirrored with its body, it stays exact.
        let body = SolidBody(profile: region, depth: 2)
        let image = try XCTUnwrap(body.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, .pi * 80, accuracy: 1e-6)
    }

    func testPointsAndConstructionLinesBoundNoRegion() throws {
        let point = SketchShape(kind: .point, plane: .top, start: .init(x: 1, y: 2), end: .init(x: 1, y: 2))
        XCTAssertTrue(point.isValid)
        XCTAssertEqual(point.snapPoints, [.init(x: 1, y: 2)])
        var square = SketchTools.polygon(center: .zero, vertex: .init(x: 10, y: 10), sides: 4, plane: .top)
        XCTAssertEqual(Geometry.profiles(in: square + [point], on: .top).count, 1)
        square[0].construction = true
        XCTAssertTrue(Geometry.profiles(in: square, on: .top).isEmpty, "A construction side leaves the outline open")
        var bad = square[1]
        bad.construction = false
        XCTAssertFalse(bad.isValid, "Only saved when set")
    }

    func testExtendCarriesALineToTheNextShape() throws {
        let line = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let wall = SketchShape(kind: .line, plane: .top, start: .init(x: 20, y: -10), end: .init(x: 20, y: 10))
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: -30, y: 0), end: .init(x: -25, y: 0))
        let space = sketch([line, wall, circle])
        let right = try XCTUnwrap(SketchTools.extend(line.id, near: .init(x: 4, y: 0), in: space))
        XCTAssertEqual(right.shapes[0].end.x, 20, accuracy: 1e-9)
        let left = try XCTUnwrap(SketchTools.extend(line.id, near: .init(x: 1, y: 0), in: space))
        XCTAssertEqual(left.shapes[0].start.x, -25, accuracy: 1e-9, "Back to the circle's near side")
        XCTAssertNil(SketchTools.extend(wall.id, near: .init(x: 20, y: 9), in: space), "Nothing ahead")
    }

    func testExtendReachesOtherSketchesOnThePlaneAndFaceEdges() throws {
        var line = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        line.sketch = UUID()
        var wall = SketchShape(kind: .line, plane: .top, start: .init(x: 20, y: -10), end: .init(x: 20, y: 10))
        wall.sketch = UUID()
        let front = SketchShape(kind: .line, plane: .front, start: .init(x: 10, y: -10), end: .init(x: 10, y: 10))
        let space = sketch([line, wall, front])
        let extended = try XCTUnwrap(SketchTools.extend(line.id, near: .init(x: 4, y: 0), in: space))
        XCTAssertEqual(extended.shapes[0].end.x, 20, accuracy: 1e-9, "A wall drawn in another sketch on the plane stops it")
        // Without the wall: the Front line is on another plane, but a face edge on this one stops it.
        let alone = sketch([line, front])
        XCTAssertNil(SketchTools.extend(line.id, near: .init(x: 4, y: 0), in: alone), "The Front line is on another plane")
        let edge = (Point2(x: 30, y: -40), Point2(x: 30, y: 40))
        let toEdge = try XCTUnwrap(SketchTools.extend(line.id, near: .init(x: 4, y: 0), in: alone, edges: [edge]))
        XCTAssertEqual(toEdge.shapes[0].end.x, 30, accuracy: 1e-9)
    }

    func testMirrorInsideASketchAndMovingShapes() throws {
        let axis = SketchShape(kind: .line, plane: .top, start: .init(x: 0, y: -10), end: .init(x: 0, y: 10))
        let arc = SketchShape.arc(center: .init(x: 5, y: 0), from: .init(x: 8, y: 0), to: .init(x: 5, y: 3), plane: .top)
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 2, y: 2), end: .init(x: 6, y: 4))
        let space = sketch([axis, arc, rectangle])
        let result = try XCTUnwrap(SketchTools.mirror([arc.id, rectangle.id], across: axis.id, in: space))
        XCTAssertEqual(result.added.count, 2)
        let image = try XCTUnwrap(result.workspace.shapes.first { $0.id == result.added[0] })
        XCTAssertEqual(image.arcCenter, .init(x: -5, y: 0))
        XCTAssertEqual(image.arcSweep, arc.arcSweep, accuracy: 1e-9)
        // Across a slanted line, a rectangle becomes its four lines.
        let slant = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 10, y: 10))
        XCTAssertEqual(SketchTools.reflected(rectangle, across: slant.start, slant.end).count, 4)
        let moved = try XCTUnwrap(SketchTools.transformed(arc, by: .init(x: 1, y: 1)))
        XCTAssertEqual(moved.arcCenter, .init(x: 6, y: 1))
        let turned = try XCTUnwrap(SketchTools.transformed(rectangle, by: .zero, turning: 90, about: .zero))
        XCTAssertEqual(turned.start.x, -2, accuracy: 1e-9)
        XCTAssertNil(SketchTools.transformed(rectangle, by: .zero, turning: 30, about: .zero), "Not square to the sketch")
    }

    func testOffsetOfShapesAndChains() throws {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: 20, y: 10))
        var space = sketch([rectangle])
        let out = try XCTUnwrap(SketchTools.offset(rectangle.id, by: 2, bothSides: false, rounded: false, in: space))
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(Geometry.profiles(in: out, on: .top).first?.area ?? 0, 24 * 14, accuracy: 1e-6)
        let wall = try XCTUnwrap(SketchTools.offset(rectangle.id, by: 1, bothSides: true, rounded: true, in: space))
        XCTAssertEqual(wall.filter { $0.kind == .arc }.count, 4, "Rounded outside corners")
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 50, y: 0), end: .init(x: 55, y: 0))
        space = sketch([circle])
        let ring = try XCTUnwrap(SketchTools.offset(circle.id, by: -1, bothSides: false, rounded: false, in: space))
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[0].kind, .circle)
        XCTAssertEqual(ShapeDimension.diameter.value(of: ring[0]), 8, accuracy: 1e-9)
        // A chain of joined lines (an L), offset to one side.
        let a = SketchShape(kind: .line, plane: .top, start: .zero, end: .init(x: 10, y: 0))
        let b = SketchShape(kind: .line, plane: .top, start: .init(x: 10, y: 0), end: .init(x: 10, y: 10))
        space = sketch([a, b])
        XCTAssertEqual(SketchTools.chain(from: b.id, in: space).map(\.id), [a.id, b.id])
        let side = try XCTUnwrap(SketchTools.offset(a.id, by: 1, bothSides: false, rounded: false, in: space))
        XCTAssertEqual(side.count, 2)
        let ellipse = SketchShape(kind: .ellipse, plane: .top, start: .zero, end: .init(x: 10, y: 0), width: 8)
        let around = try XCTUnwrap(SketchTools.offset(ellipse.id, by: 1, bothSides: false, rounded: false, in: sketch([ellipse])))
        XCTAssertEqual(around.map(\.kind), [.curve])
    }
}
