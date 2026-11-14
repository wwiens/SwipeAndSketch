import XCTest
import simd
@testable import SwipeAndSketchCore

final class SketchGuideTests: XCTestCase {
    func box() throws -> SolidBody {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20))
        return SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 20)
    }

    func topFace(_ body: SolidBody) throws -> (plane: SketchPlane, face: Int) {
        let solid = try SolidKernel.solid(for: body)
        let face = try XCTUnwrap((0..<solid.faceCount).first { solid.faceCenter($0).map { abs($0.z - 20) < 1e-9 } ?? false })
        return (try XCTUnwrap(SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1))), face)
    }

    func points(_ guides: [SketchGuide], _ kind: SketchGuide.Kind) -> Set<String> {
        Set(guides.filter { $0.kind == kind }.map { String(format: "%.3f,%.3f", ($0.point.x * 1000).rounded() / 1000 + 0, ($0.point.y * 1000).rounded() / 1000 + 0) })
    }

    func testTopFaceHasCornersMidpointsAndCenter() throws {
        let body = try box()
        let top = try topFace(body)
        let guides = SketchGuides.guides(on: top.plane, bodies: [body], face: (body.id, top.face))
        XCTAssertEqual(points(guides, .corner), ["-30.000,-20.000", "30.000,-20.000", "30.000,20.000", "-30.000,20.000"])
        XCTAssertEqual(points(guides, .midpoint), ["0.000,-20.000", "30.000,0.000", "0.000,20.000", "-30.000,0.000"])
        XCTAssertEqual(points(guides, .faceCenter), ["0.000,0.000"])
        XCTAssertEqual(guides.first?.kind, .corner, "Corners win ties")
        XCTAssertEqual(guides.first { $0.kind == .faceCenter }?.point, .zero, "Guide coordinates are exact, without kernel round-off")
        XCTAssertEqual(guides.first { $0.kind == .faceCenter }?.kind.label, "Face center")
        XCTAssertTrue(points(guides, .intersection).isEmpty, "Vertical edges end on the face, at its corners")
    }

    func testOtherSketchesCrossingThePlaneAreGuides() throws {
        // A square and circle on Top show where they pierce Front.
        let square = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10))
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 0, y: 3), end: .init(x: 5, y: 3))
        let slanted = SketchShape(kind: .line, plane: .right, start: .init(x: -4, y: -6), end: .init(x: 8, y: 6))
        let guides = SketchGuides.guides(on: .front, bodies: [], shapes: [square, circle, slanted])
        XCTAssertEqual(points(guides, .intersection), ["-10.000,0.000", "10.000,0.000", "-4.000,0.000", "4.000,0.000", "0.000,-2.000"])
        XCTAssertEqual(guides.first?.kind.label, "Intersection")
        XCTAssertTrue(SketchGuides.guides(on: .top, bodies: [], shapes: [square]).isEmpty, "A sketch's own plane adds nothing")
    }

    func testWorldPlaneGetsGuidesFromCoplanarSolidEdgesOnly() throws {
        let body = try box()
        let guides = SketchGuides.guides(on: .top, bodies: [body])
        XCTAssertEqual(points(guides, .corner).count, 4, "The box's bottom edges lie on Top")
        XCTAssertEqual(points(guides, .midpoint).count, 4)
        XCTAssertTrue(points(guides, .center).isEmpty, "No face center without a sketched face")
        // Right cuts through the box: no edge lies in it, but four edges cross it.
        let crossing = SketchGuides.guides(on: .right, bodies: [body])
        XCTAssertEqual(crossing.count, 4)
        XCTAssertTrue(crossing.allSatisfy { $0.kind == .intersection })
    }

    func testHoleEdgesAddTheirCenter() throws {
        var body = try box()
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: 15, y: 5), end: .init(x: 19, y: 5))
        body.cuts = [ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true)]
        let top = try topFace(body)
        let guides = SketchGuides.guides(on: top.plane, bodies: [body], face: (body.id, top.face))
        XCTAssertTrue(points(guides, .center).contains("15.000,5.000"), "The hole's center is a guide")
        XCTAssertEqual(points(guides, .corner).count, 4, "A full circle adds no seam corner")
    }

    func testSnappingPrefersNearbyGuidePoints() throws {
        let guides = [SketchGuide(point: .init(x: 0, y: 20), kind: .midpoint), SketchGuide(point: .zero, kind: .center)]
        let snapped = SketchSnap.snap(.init(x: 0.4, y: 19.7), shapes: [], plane: .top, grid: 1, tolerance: 1, guides: guides)
        XCTAssertEqual(snapped, SnapResult(point: .init(x: 0, y: 20), label: "Edge midpoint"))
        let free = SketchSnap.snap(.init(x: 7.3, y: 8.6), shapes: [], plane: .top, grid: 1, tolerance: 1, guides: guides)
        XCTAssertEqual(free.label, "Grid")
    }
}
