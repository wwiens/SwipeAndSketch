import XCTest
import simd
@testable import SwipeAndSketchCore

/// Project (sketch projections): solids and sketches cast onto a plane become sketch geometry.
final class ProjectionTests: XCTestCase {
    /// A 60 × 40 × 20 box on Top (z 0…20).
    func box() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
    }

    /// A cylinder of radius 10, 30 mm tall, on Top.
    func cylinder() throws -> SolidBody {
        let shape = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 30)
    }

    let above = SketchPlane.through(.init(0, 0, 50), normal: .init(0, 0, 1))!

    func count(_ shapes: [SketchShape], _ kind: ShapeKind) -> Int { shapes.filter { $0.kind == kind }.count }

    func testABoxSeenFromAboveIsOneClosedOutline() throws {
        let item = try XCTUnwrap(ProjectionItem.body(try box()))
        XCTAssertEqual(item.curves.count, 12)
        let shapes = try XCTUnwrap(Projection.shapes(projecting: [item], onto: above))
        // Top and bottom outlines coincide; the upright edges shrink to points.
        XCTAssertEqual(shapes.count, 4)
        XCTAssertEqual(count(shapes, .line), 4)
        XCTAssertTrue(shapes.allSatisfy { $0.plane == above })
        let profile = try XCTUnwrap(Geometry.profiles(in: shapes, on: above).first)
        XCTAssertEqual(profile.area, 60 * 40, accuracy: 1e-9)
        XCTAssertEqual(above.point(profile.center).z, 50, accuracy: 1e-12)
        // Already there: nothing more to add.
        XCTAssertEqual(Projection.shapes(projecting: [item], onto: above, existing: shapes)?.count, 0)
    }

    func testACylinderIsACircleFromAboveAndARectangleFromTheSide() throws {
        let item = try XCTUnwrap(ProjectionItem.body(try cylinder()))
        let top = try XCTUnwrap(Projection.shapes(projecting: [item], onto: above))
        XCTAssertEqual(top.count, 1, "Both rims become one exact circle; the sides add nothing")
        XCTAssertEqual(top.first?.kind, .circle)
        XCTAssertEqual(top.first.map { $0.start.distance(to: $0.end) } ?? 0, 10, accuracy: 1e-9)
        // From the front, the rims are lines and the curved side's outline closes the rectangle.
        let side = try XCTUnwrap(Projection.shapes(projecting: [item], onto: .front))
        XCTAssertTrue(side.allSatisfy { $0.kind == .line }, "\(side.map(\.kind))")
        let profile = try XCTUnwrap(Geometry.profiles(in: side, on: .front).first)
        XCTAssertEqual(profile.area, 20 * 30, accuracy: 0.5, "The outline follows the display mesh")
    }

    func testARoundedBoxProjectsToLinesAndExactArcsThatExtrudeSmoothly() throws {
        var rounded = try box()
        rounded.finishes = [EdgeFinish(kind: .fillet, edges: rounded.extrusionEdges.filter { $0.position == .side }, size: 5)]
        let item = try XCTUnwrap(ProjectionItem.body(rounded))
        let shapes = try XCTUnwrap(Projection.shapes(projecting: [item], onto: above))
        XCTAssertEqual(count(shapes, .line), 4)
        XCTAssertEqual(count(shapes, .arc), 4)
        for arc in shapes where arc.kind == .arc {
            XCTAssertEqual(arc.arcSweep, .pi / 2, accuracy: 1e-9)
            XCTAssertEqual(arc.start.distance(to: try XCTUnwrap(arc.arcCenter)), 5, accuracy: 1e-9)
        }
        let profile = try XCTUnwrap(Geometry.profiles(in: shapes, on: above).first)
        XCTAssertEqual(profile.arcs?.count, 4)
        XCTAssertTrue(profile.isSolidProfile)
        // Extruded, each arc is one exact curved side: 4 flat sides, 4 round ones, and 2 caps.
        let body = SolidBody(profile: profile, depth: 10)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.faceCount, 10)
        let corner: Double = 25 - Double.pi * 25 / 4
        XCTAssertEqual(solid.volume, (2_400 - 4 * corner) * 10, accuracy: 1e-6)
        // Every edge is named, including the curved ones, so they can be finished again.
        let names = Set((0..<solid.edgeCount).compactMap { body.extrusionEdge(along: solid.edgeSamples($0)) })
        XCTAssertEqual(names.count, solid.edgeCount)
        XCTAssertEqual(body.corners.count, 8)
        var capped = body
        capped.finishes = [EdgeFinish(kind: .fillet, edges: body.extrusionEdges.filter { $0.position == .cap }, size: 1)]
        XCTAssertTrue(try SolidKernel.solid(for: capped).isValidSolid)
    }

    func testALineAndAnArcCloseARegion() throws {
        let line = SketchShape(kind: .line, plane: .top, start: .init(x: -10, y: 0), end: .init(x: 10, y: 0))
        let arc = SketchShape.arc(center: .zero, from: .init(x: 10, y: 0), to: .init(x: -10, y: 0), plane: .top)
        XCTAssertTrue(arc.isValid)
        XCTAssertEqual(arc.arcSweep, .pi, accuracy: 1e-12)
        let profile = try XCTUnwrap(Geometry.profiles(in: [line, arc], on: .top).first)
        XCTAssertEqual(Set(profile.sourceIDs), [line.id, arc.id])
        XCTAssertEqual(profile.area, .pi * 50, accuracy: 0.2, "The outline is the arc's polygon")
        let solid = try SolidKernel.extrude(profile, depth: 4)
        XCTAssertEqual(solid.faceCount, 4, "Flat side, round side, two caps")
        XCTAssertEqual(solid.volume, .pi * 50 * 4, accuracy: 1e-6, "The kernel builds the exact arc")
    }

    func testCirclesAndArcsSeenAtAnAngleBecomeCurves() throws {
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 10, y: 0))
        let tilted = try XCTUnwrap(SketchPlane.through(.zero, normal: simd_normalize(SIMD3(0, -1, 1))))
        let shapes = try XCTUnwrap(Projection.shapes(projecting: [.shapes([circle], source: .shape(circle.id))], onto: tilted))
        XCTAssertEqual(shapes.count, 1)
        XCTAssertEqual(shapes.first?.kind, .curve)
        XCTAssertTrue(shapes.first?.isClosed ?? false)
        let ellipse = try XCTUnwrap(Geometry.profiles(in: shapes, on: tilted).first)
        XCTAssertEqual(ellipse.area, .pi * 100 * cos(.pi / 4), accuracy: 1)
        // Edge-on, the same circle is a line across it.
        let edgeOn = try XCTUnwrap(Projection.shapes(projecting: [.shapes([circle], source: .shape(circle.id))], onto: .front))
        XCTAssertEqual(edgeOn.map(\.kind), [.line])
        XCTAssertEqual(edgeOn.first.map { $0.start.distance(to: $0.end) } ?? 0, 20, accuracy: 1e-9)
        // An arc facing the plane from behind keeps running counterclockwise in the plane's own axes.
        let arc = SketchShape.arc(center: .zero, from: .init(x: 10, y: 0), to: .init(x: 0, y: 10), plane: .top)
        let below = try XCTUnwrap(SketchPlane.through(.init(0, 0, -5), normal: .init(0, 0, -1)))
        let flipped = try XCTUnwrap(Projection.shapes(projecting: [.shapes([arc], source: .shape(arc.id))], onto: below)?.first)
        XCTAssertEqual(flipped.kind, .arc)
        XCTAssertEqual(flipped.arcSweep, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(Set([below.point(flipped.start), below.point(flipped.end)].map { simd_distance($0, .init(10, 0, -5)) < 1e-9 }), [true, false])
    }

    func testRectanglesStayRectanglesOnlyWhileSquareToThePlane() throws {
        let rectangle = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 0, y: 0), end: .init(x: 20, y: 10))
        let item = ProjectionItem.shapes([rectangle], source: .shape(rectangle.id))
        let same = try XCTUnwrap(Projection.shapes(projecting: [item], onto: above))
        XCTAssertEqual(same.map(\.kind), [.rectangle])
        XCTAssertEqual(same.first?.outline, rectangle.outline)
        let turned = try XCTUnwrap(SketchPlane.through(.init(0, 0, 9), normal: simd_normalize(SIMD3(1, 0, 1))))
        let skewed = try XCTUnwrap(Projection.shapes(projecting: [item], onto: turned))
        XCTAssertEqual(count(skewed, .line) + count(skewed, .rectangle), skewed.count)
        XCTAssertNotNil(Geometry.profiles(in: skewed, on: turned).first, "Still one closed region")
    }

    func testFacesAndEdgesProjectOnlyThemselves() throws {
        let body = try box()
        let solid = try SolidKernel.solid(for: body)
        let topFace = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { $0.normal.z > 0.99 } ?? false })
        let face = try XCTUnwrap(ProjectionItem.face(topFace, of: body))
        XCTAssertEqual(face.curves.count, 4)
        let onFront = try XCTUnwrap(Projection.shapes(projecting: [face], onto: .front))
        XCTAssertEqual(onFront.count, 1, "The top face seen from the front is one line")
        XCTAssertEqual(onFront.first.map { $0.start.distance(to: $0.end) } ?? 0, 60, accuracy: 1e-9)
        let edge = try XCTUnwrap(ProjectionItem.edge(0, of: body))
        XCTAssertEqual(edge.curves.count, 1)
        XCTAssertNil(ProjectionItem.edge(solid.edgeCount, of: body))
    }

    func testProjectedGeometryRoundTrips() throws {
        let line = SketchShape(kind: .line, plane: .top, start: .init(x: -10, y: 0), end: .init(x: 10, y: 0))
        let arc = SketchShape.arc(center: .zero, from: .init(x: 10, y: 0), to: .init(x: -10, y: 0), plane: .top)
        let curve = SketchShape.curve([.init(x: 0, y: 20), .init(x: 5, y: 25), .init(x: 10, y: 20)], closed: false, plane: .top)
        let profile = try XCTUnwrap(Geometry.profiles(in: [line, arc], on: .top).first)
        let workspace = Workspace(shapes: [line, arc, curve], bodies: [SolidBody(profile: profile, depth: 3)])
        XCTAssertTrue(workspace.isValid)
        let project = Project(workspace: workspace)
        let data = try ProjectCodec.encode(project)
        XCTAssertEqual(try ProjectCodec.decode(data), project)
        // Arcs must stay on their circle.
        var broken = workspace
        broken.bodies[0].profile.arcs?[0].radius = 9
        XCTAssertFalse(broken.isValid)
    }

    func testChainedSegmentsJoinIntoPolylines() {
        let a = Point2(x: 0, y: 0), b = Point2(x: 1, y: 0), c = Point2(x: 2, y: 0), d = Point2(x: 5, y: 5), e = Point2(x: 6, y: 5)
        let chains = Projection.chained([(b, c), (d, e), (a, b)])
        XCTAssertEqual(chains.count, 2)
        XCTAssertTrue(chains.contains { $0 == [a, b, c] || $0 == [c, b, a] })
        XCTAssertEqual(Projection.polyline([a, b, c], closed: false, plane: .top).map(\.kind), [.line], "Collinear points are one line")
    }
}
