import XCTest
import simd
@testable import SwipeAndSketchCore

final class MirrorTests: XCTestCase {
    /// An L-shaped solid (asymmetric in every direction) with a fillet on one corner, a through
    /// hole, a joined boss, a hole preset, a face extrusion, and a merged solid.
    func featuredL() throws -> SolidBody {
        let outline = [Point2(x: 0, y: 0), Point2(x: 40, y: 0), Point2(x: 40, y: 10), Point2(x: 12, y: 10), Point2(x: 12, y: 30), Point2(x: 0, y: 30)]
        let lines = zip(outline, outline.dropFirst() + [outline[0]]).map { SketchShape(kind: .line, plane: .top, start: $0, end: $1) }
        var body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: lines, on: .top).first), depth: 15)
        let side = try XCTUnwrap(body.extrusionEdges.first { $0.position == .side && body.corners[$0.index] == Point2(x: 40, y: 10) })
        body.finishes = [EdgeFinish(kind: .fillet, edges: [side], size: 4)]
        let hole = SketchShape(kind: .circle, plane: .top, start: .init(x: 30, y: 5), end: .init(x: 32, y: 5))
        body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [hole], on: .top).first), depth: 1, throughAll: true))
        let lid = try XCTUnwrap(SketchPlane.through(.init(0, 0, 15), normal: .init(0, 0, 1)))
        let boss = SketchShape(kind: .rectangle, plane: lid, start: .init(x: 2, y: 14), end: .init(x: 8, y: 26))
        body.cuts.append(ExtrusionCut(profile: try XCTUnwrap(Geometry.profiles(in: [boss], on: lid).first), depth: 5, operation: .join))
        body.cuts.append(try XCTUnwrap(ExtrusionCut.hole(HolePresets.spec(.counterbore, size: "M3"), at: .init(x: 20, y: 5), on: lid, depth: nil)))
        let solid = try SolidKernel.solid(for: body)
        let bottom = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { $0.normal.z < -0.9999 } ?? false })
        body.cuts.append(try XCTUnwrap(FaceExtrusionSource(body: body, face: bottom)).operation(depth: 2))
        let tab = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 40, y: 0), end: .init(x: 46, y: 4))
        body.cuts.append(.merge(SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [tab], on: .top).first), depth: 6)))
        return body
    }

    /// Every flat face of the mirror image sits where the original's reflected face does. (Curved
    /// faces are left out: the kernel may place a cylinder's seam elsewhere and split it in two.)
    func assertMirrorImage(_ image: SolidBody, of original: SolidBody, by reflection: Reflection,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try SolidKernel.solid(for: original), b = try SolidKernel.solid(for: image)
        XCTAssertEqual(b.volume, a.volume, accuracy: a.volume * 1e-6, "Same volume", file: file, line: line)
        func flatCenters(_ solid: KernelSolid) -> [SIMD3<Double>] {
            (0..<solid.faceCount).filter { solid.facePlane($0) != nil }.compactMap(solid.faceCenter)
        }
        let expected = flatCenters(a).map(reflection.point)
        let actual = flatCenters(b)
        XCTAssertEqual(actual.count, expected.count, "Same faces", file: file, line: line)
        for point in expected {
            XCTAssertTrue(actual.contains { simd_distance($0, point) < 1e-5 }, "Face center \(point) reflected", file: file, line: line)
        }
    }

    func testMirroredSolidKeepsEveryStepOnTheMirroredGeometry() throws {
        let body = try featuredL()
        for plane in [SketchPlane.right, .front, .top, try XCTUnwrap(SketchPlane.through(.init(5, 3, 2), normal: .init(1, 2, 3)))] {
            let reflection = try XCTUnwrap(Reflection(across: plane))
            let image = try XCTUnwrap(body.mirrored(by: reflection), "Mirrors across \(plane)")
            XCTAssertTrue(image.isValid)
            XCTAssertEqual(image.finishes.count, 1, "The fillet stays a named fillet")
            try assertMirrorImage(image, of: body, by: reflection)
        }
        // Across Right (x = 0), the L faces the other way.
        let image = try XCTUnwrap(body.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        let bounds = try SolidKernel.solid(for: image).bounds, original = try SolidKernel.solid(for: body).bounds
        XCTAssertEqual(bounds.min.x, -original.max.x, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.x, -original.min.x, accuracy: 1e-6)
        XCTAssertEqual(bounds.min.z, original.min.z, accuracy: 1e-6)
    }

    func testMirroredSolidCanBeFilletedAndMovedLikeAnyOther() throws {
        let body = try featuredL()
        let image = try XCTUnwrap(body.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        var rounded = image
        let edge = try XCTUnwrap(rounded.extrusionEdges.first { $0.position == .cap && $0.index == 0 })
        rounded.finishes.append(EdgeFinish(kind: .chamfer, edges: [edge], size: 1))
        XCTAssertLessThan(try SolidKernel.solid(for: rounded).volume, try SolidKernel.solid(for: image).volume, "A new chamfer on the mirror image")
        let moved = try XCTUnwrap(image.transformed(by: .rotate(degrees: 30, about: .init(0, 0, 1), through: .zero)))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, try SolidKernel.solid(for: image).volume, accuracy: 1e-6)
    }

    func testMirroredShellRevolveAndArcProfiles() throws {
        // A shelled box with its top (by name) and one side (by point) left open.
        let box = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 5, y: 0), end: .init(x: 35, y: 20))
        var shelled = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [box], on: .top).first), depth: 12)
        shelled.cuts = [.shell(of: shelled, openFaces: [ExtrusionFace(position: .cap, index: 0)], openingAt: [SIMD3(35, 10, 6)], thickness: 2)]
        XCTAssertEqual(shelled.cuts[0].shell?.openPoints?.count, 1)
        let tilted = try XCTUnwrap(Reflection(across: try XCTUnwrap(SketchPlane.through(.init(0, 0, 0), normal: .init(1, 0, 1)))))
        try assertMirrorImage(try XCTUnwrap(shelled.mirrored(by: tilted)), of: shelled, by: tilted)

        // A three-quarter revolve of an off-axis rectangle about the y axis.
        let section = SketchShape(kind: .rectangle, plane: .front, start: .init(x: 10, y: 0), end: .init(x: 16, y: 8))
        let profile = try XCTUnwrap(Geometry.profiles(in: [section], on: .front).first)
        var revolved = SolidBody(profile: profile, depth: 0)
        revolved.revolve = .oriented(from: .zero, to: Point2(x: 0, y: 1), angle: 270, for: profile)
        for plane in [SketchPlane.right, .front, .top] {
            let reflection = try XCTUnwrap(Reflection(across: plane))
            try assertMirrorImage(try XCTUnwrap(revolved.mirrored(by: reflection)), of: revolved, by: reflection)
        }

        // A profile with an exact arc keeps the arc on its points.
        let arcProfile = SketchProfile(id: "arc", plane: .top, sourceIDs: [],
                                       outline: [Point2(x: 0, y: 0), Point2(x: 20, y: 0)] + (1...7).map { i in
                                           let t = Double(i) / 8 * .pi
                                           return Point2(x: 10 + 10 * cos(t), y: 10 * sin(t))
                                       },
                                       arcs: [ProfileArc(start: 1, segments: 8, center: Point2(x: 10, y: 0), radius: 10)])
        XCTAssertTrue(arcProfile.isSolidProfile)
        let dome = SolidBody(profile: arcProfile, depth: 5)
        let flipped = try XCTUnwrap(dome.profile.mirrored(by: try XCTUnwrap(Reflection(across: .front))))
        XCTAssertTrue(flipped.isSolidProfile, "Still counter-clockwise, with the arc on its points")
        XCTAssertGreaterThan(Geometry.signedArea(flipped.outline), 0)
        let reflection = try XCTUnwrap(Reflection(across: .front))
        try assertMirrorImage(try XCTUnwrap(dome.mirrored(by: reflection)), of: dome, by: reflection)
    }

    func testMirroringSketchesAndKeepOriginals() throws {
        var workspace = Workspace()
        workspace.shapes = [
            SketchShape(kind: .line, plane: .top, start: .init(x: 1, y: 2), end: .init(x: 9, y: 4)),
            SketchShape(kind: .rectangle, plane: .top, start: .init(x: 10, y: 10), end: .init(x: 20, y: 16)),
            .arc(center: .init(x: 30, y: 5), from: .init(x: 35, y: 5), to: .init(x: 30, y: 10), plane: .top)
        ]
        workspace.normalizeSketches()
        let sketch = try XCTUnwrap(workspace.sketches.first?.id)
        let shape = workspace.shapes[0]
        let body = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [workspace.shapes[1]], on: .top).first), depth: 7)
        workspace.bodies = [body]

        // Across Front (y = 0): a Top sketch stays on Top, with y flipped.
        let kept = try XCTUnwrap(Mirroring.mirror(workspace, bodies: [body.id], sketches: [sketch], across: .front, keepOriginals: true))
        XCTAssertEqual(kept.workspace.sketches.count, 2)
        XCTAssertEqual(kept.workspace.bodies.count, 2)
        XCTAssertEqual(kept.workspace.bodies[0], body, "The original stays")
        let copy = try XCTUnwrap(kept.workspace.sketches.first { $0.id == kept.sketches[0] })
        XCTAssertEqual(copy.plane, .top)
        let line = try XCTUnwrap(kept.workspace.shapes.first { $0.sketch == copy.id && $0.kind == .line })
        XCTAssertEqual(line.start, Point2(x: 1, y: -2))
        XCTAssertEqual(line.end, Point2(x: 9, y: -4))
        let arc = try XCTUnwrap(kept.workspace.shapes.first { $0.sketch == copy.id && $0.kind == .arc })
        XCTAssertTrue(arc.isValid)
        XCTAssertEqual(arc.start, Point2(x: 30, y: -10), "Ends swap so the arc stays counter-clockwise")
        XCTAssertEqual(arc.end, Point2(x: 35, y: -5))
        let bounds = try SolidKernel.solid(for: try XCTUnwrap(kept.workspace.bodies.first { $0.id == kept.bodies[0] })).bounds
        XCTAssertEqual(bounds.min.y, -16, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.y, -10, accuracy: 1e-9)

        // Without originals, each is replaced in place under the same id.
        let replaced = try XCTUnwrap(Mirroring.mirror(workspace, bodies: [body.id], sketches: [sketch], across: .right, keepOriginals: false))
        XCTAssertEqual(replaced.workspace.bodies.map(\.id), [body.id])
        XCTAssertEqual(replaced.workspace.sketches.map(\.id), [sketch])
        let moved = try XCTUnwrap(replaced.workspace.shapes.first { $0.id == shape.id })
        XCTAssertLessThan(simd_distance(moved.plane.point(moved.start), SIMD3(-1, 2, 0)), 1e-9, "World positions reflect")
        XCTAssertLessThan(simd_distance(moved.plane.point(moved.end), SIMD3(-9, 4, 0)), 1e-9)
        XCTAssertNil(Mirroring.mirror(workspace, bodies: [], sketches: [], across: .right, keepOriginals: true))
    }
}
