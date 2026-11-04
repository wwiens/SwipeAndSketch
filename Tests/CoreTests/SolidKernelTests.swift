import XCTest
import simd
@testable import SwipeAndSketchCore

/// Feasibility checks for the Open CASCADE kernel: every v1 modeling operation on the
/// document's own profile types, valid watertight results, and per-face tessellation.
final class SolidKernelTests: XCTestCase {
    func rectangle(_ width: Double, _ height: Double, plane: SketchPlane = .top) throws -> SketchProfile {
        let shape = SketchShape(kind: .rectangle, plane: plane, start: .init(x: -width / 2, y: -height / 2),
                                end: .init(x: width / 2, y: height / 2))
        return try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first)
    }

    func circle(radius: Double, center: Point2 = .zero, plane: SketchPlane = .top) throws -> SketchProfile {
        let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: radius, y: 0))
        return try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first)
    }

    func testReportsOCCTVersion() {
        XCTAssertTrue(SolidKernel.occtVersion.hasPrefix("8.0"), SolidKernel.occtVersion)
    }

    func testExtrudesRectanglesAndCirclesOnEveryPlaneInBothDirections() throws {
        for plane in SketchPlane.allCases {
            for depth in [12.0, -12.0] {
                let box = try SolidKernel.extrude(rectangle(60, 40, plane: plane), depth: depth)
                XCTAssertTrue(box.isValidSolid)
                XCTAssertEqual(box.volume, 60 * 40 * 12, accuracy: 1e-6, "Volume is positive whatever the extrusion direction")
                XCTAssertEqual(box.faceCount, 6)
                XCTAssertEqual(box.edgeCount, 12)
                let cylinder = try SolidKernel.extrude(circle(radius: 10, plane: plane), depth: depth)
                XCTAssertTrue(cylinder.isValidSolid)
                XCTAssertEqual(cylinder.volume, .pi * 100 * 12, accuracy: 1e-6, "Circles stay analytic, not polygons")
            }
        }
    }

    func testExtrusionMatchesCanvasPlacement() throws {
        // Front plane normal is −Y: a positive depth grows toward −Y from the sketch plane.
        let bounds = try SolidKernel.extrude(rectangle(60, 40, plane: .front), depth: 12).bounds
        XCTAssertEqual(bounds.min.y, -12, accuracy: 1e-6); XCTAssertEqual(bounds.max.y, 0, accuracy: 1e-6)
        XCTAssertEqual(bounds.min.x, -30, accuracy: 1e-6); XCTAssertEqual(bounds.max.z, 20, accuracy: 1e-6)
        let down = try SolidKernel.extrude(rectangle(60, 40), depth: -5).bounds
        XCTAssertEqual(down.min.z, -5, accuracy: 1e-6); XCTAssertEqual(down.max.z, 0, accuracy: 1e-6)
    }

    func testExtrudesConcaveLineProfiles() throws {
        let points = [Point2(x: 0, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 10),
                      .init(x: 10, y: 10), .init(x: 10, y: 30), .init(x: 0, y: 30)]
        let lines = points.indices.map { SketchShape(kind: .line, plane: .top, start: points[$0], end: points[($0 + 1) % points.count]) }
        let profile = try XCTUnwrap(Geometry.profiles(in: lines, on: .top).first)
        let solid = try SolidKernel.extrude(profile, depth: 5)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, (30 * 10 + 10 * 20) * 5, accuracy: 1e-6)
    }

    func testCollinearOutlinePointsDoNotSplitFlatSides() throws {
        // A 30 × 20 rectangle drawn as five lines, two of them meeting mid-edge.
        let points = [Point2(x: 0, y: 0), .init(x: 15, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 20), .init(x: 0, y: 20)]
        let lines = points.indices.map { SketchShape(kind: .line, plane: .top, start: points[$0], end: points[($0 + 1) % points.count]) }
        let solid = try SolidKernel.extrude(XCTUnwrap(Geometry.profiles(in: lines, on: .top).first), depth: 10)
        XCTAssertEqual(solid.faceCount, 6)
        XCTAssertEqual(solid.edgeCount, 12)
        XCTAssertEqual(solid.volume, 6000, accuracy: 1e-6)
    }

    func testBooleansCutHolesAndJoinBodies() throws {
        let plate = try SolidKernel.extrude(rectangle(60, 40), depth: 10)
        let pin = try SolidKernel.extrude(circle(radius: 5), depth: 30)
        let drilled = try SolidKernel.boolean(plate, pin, .subtract)
        XCTAssertTrue(drilled.isValidSolid)
        XCTAssertEqual(drilled.volume, 60 * 40 * 10 - .pi * 25 * 10, accuracy: 1e-4)
        let joined = try SolidKernel.boolean(plate, pin, .union)
        XCTAssertTrue(joined.isValidSolid)
        XCTAssertEqual(joined.volume, 60 * 40 * 10 + .pi * 25 * 20, accuracy: 1e-4)
        let common = try SolidKernel.boolean(plate, pin, .intersect)
        XCTAssertEqual(common.volume, .pi * 25 * 10, accuracy: 1e-4)
    }

    func testUnionOfFlushBoxesMergesCoplanarFaces() throws {
        let left = try SolidKernel.extrude(rectangle(20, 20), depth: 10)
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 10, y: -10), end: .init(x: 30, y: 10))
        let right = try SolidKernel.extrude(XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: 10)
        let joined = try SolidKernel.boolean(left, right, .union)
        XCTAssertTrue(joined.isValidSolid)
        XCTAssertEqual(joined.volume, 40 * 20 * 10, accuracy: 1e-6)
        XCTAssertEqual(joined.faceCount, 6, "Snapped, flush bodies should fuse into one clean box")
    }

    func testFilletsAndChamfersEdges() throws {
        let box = try SolidKernel.extrude(rectangle(40, 30), depth: 20)
        let rounded = try SolidKernel.fillet(box, edges: Array(0..<box.edgeCount), radius: 3)
        XCTAssertTrue(rounded.isValidSolid)
        XCTAssertLessThan(rounded.volume, box.volume)
        XCTAssertEqual(rounded.faceCount, 26, "6 faces + 12 edge blends + 8 corner patches")
        let chamfered = try SolidKernel.chamfer(box, edges: [0], distance: 2)
        XCTAssertTrue(chamfered.isValidSolid)
        XCTAssertEqual(chamfered.volume, box.volume - 0.5 * 2 * 2 * edgeLength(box, 0), accuracy: 1e-6)
        let cylinder = try SolidKernel.extrude(circle(radius: 10), depth: 10)
        let roundedCylinder = try SolidKernel.fillet(cylinder, edges: Array(0..<cylinder.edgeCount).filter { cylinderRim(cylinder, $0) }, radius: 1)
        XCTAssertTrue(roundedCylinder.isValidSolid)
    }

    func testOversizedFilletFailsWithReadableReasonAndKeepsInput() throws {
        let box = try SolidKernel.extrude(rectangle(10, 10), depth: 4)
        XCTAssertThrowsError(try SolidKernel.fillet(box, edges: Array(0..<box.edgeCount), radius: 6)) { error in
            XCTAssertFalse((error as? SolidKernel.Failure)?.message.isEmpty ?? true)
        }
        XCTAssertThrowsError(try SolidKernel.fillet(box, edges: [99], radius: 1))
        XCTAssertTrue(box.isValidSolid)
        XCTAssertEqual(box.volume, 400, accuracy: 1e-9)
    }

    func testShellsBoxIntoOpenContainer() throws {
        let box = try SolidKernel.extrude(rectangle(40, 30), depth: 20)
        let top = try XCTUnwrap(topFace(box))
        let tray = try SolidKernel.shell(box, openFaces: [top], thickness: 2)
        XCTAssertTrue(tray.isValidSolid)
        XCTAssertEqual(tray.volume, 40 * 30 * 20 - 36 * 26 * 18, accuracy: 1e-3, "Walls grow inward; outside stays 40 × 30 × 20")
        let bounds = tray.bounds
        XCTAssertEqual(bounds.max.x - bounds.min.x, 40, accuracy: 1e-3)
    }

    /// Known OCCT limitation: hollowing through a face bounded by fillets on every edge fails.
    /// The supported order is shell first, then round the edges.
    func testShellOfFullyRoundedBoxFailsCleanlyAndShellThenFilletWorks() throws {
        let box = try SolidKernel.extrude(rectangle(80, 50), depth: 30)
        let rounded = try SolidKernel.fillet(box, edges: Array(0..<box.edgeCount), radius: 3)
        let roundedTop = try XCTUnwrap(topFace(rounded))
        XCTAssertThrowsError(try SolidKernel.shell(rounded, openFaces: [roundedTop], thickness: 2)) { error in
            XCTAssertTrue((error as? SolidKernel.Failure)?.message.contains("shelling before rounding") ?? false, "\(error)")
        }
        let shelled = try SolidKernel.shell(box, openFaces: [XCTUnwrap(topFace(box))], thickness: 2)
        XCTAssertEqual(shelled.volume, 80 * 50 * 30 - 76 * 46 * 28, accuracy: 1e-3)
        let outerVertical = verticalEdges(shelled).filter { edge in
            let p = try! shelled.tessellate().edges[edge].points[0]
            return abs(abs(p.x) - 40) < 1e-4 && abs(abs(p.y) - 25) < 1e-4
        }
        XCTAssertEqual(outerVertical.count, 4)
        let finished = try SolidKernel.fillet(shelled, edges: outerVertical, radius: 3)
        XCTAssertTrue(finished.isValidSolid)
        XCTAssertLessThan(finished.volume, shelled.volume)
    }

    func testFilletedShelledEnclosureWorkflow() throws {
        // The hobbyist enclosure: box → round vertical edges → hollow from the top → drill a hole.
        let box = try SolidKernel.extrude(rectangle(80, 50), depth: 30)
        let rounded = try SolidKernel.fillet(box, edges: verticalEdges(box), radius: 5)
        let top = try XCTUnwrap(topFace(rounded))
        let shelled = try SolidKernel.shell(rounded, openFaces: [top], thickness: 2)
        XCTAssertLessThan(shelled.volume, rounded.volume * 0.25, "Walls only, not a solid block")
        let hole = try SolidKernel.extrude(circle(radius: 3, center: .init(x: 0, y: 15), plane: .front), depth: -40)
        let enclosure = try SolidKernel.boolean(shelled, hole, .subtract)
        XCTAssertTrue(enclosure.isValidSolid)
        XCTAssertLessThan(enclosure.volume, shelled.volume)
        try assertWatertight(enclosure.tessellate())
    }

    func testTessellationIsWatertightAndGroupedByFace() throws {
        let box = try SolidKernel.extrude(rectangle(60, 40), depth: 12)
        let mesh = try box.tessellate()
        XCTAssertEqual(mesh.faces.count, 6)
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertEqual(mesh.edges.filter(\.isBoundary).count, 12)
        XCTAssertEqual(mesh.faces.flatMap { Array($0) }.count, mesh.indices.count)
        try assertWatertight(mesh)
        assertOutwardNormals(mesh)

        let cylinder = try SolidKernel.extrude(circle(radius: 10), depth: 12).tessellate()
        XCTAssertEqual(cylinder.edges.filter(\.isBoundary).count, 2, "Only the two cap rims; the seam is hidden")
        try assertWatertight(cylinder)
        assertOutwardNormals(cylinder)
        // 0.02 mm chordal tolerance keeps every vertex on the true circle.
        let radial = cylinder.positions.map { hypot(Double($0.x), Double($0.y)) }.filter { $0 > 1 }
        XCTAssertLessThanOrEqual(radial.map { abs($0 - 10) }.max() ?? 1, 1e-4)
    }

    /// Operation timings for the device comparison. Run on the iPad from Xcode for real numbers.
    func testReportsOperationTimings() throws {
        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            print(String(format: "[kernel timing] %@: %.1f ms", label, Date().timeIntervalSince(start) * 1000))
            return value
        }
        let box = try time("extrude box") { try SolidKernel.extrude(rectangle(80, 50), depth: 30) }
        _ = try time("fillet 12 edges r3") { try SolidKernel.fillet(box, edges: Array(0..<box.edgeCount), radius: 3) }
        let rounded = try time("fillet 4 vertical edges r5") { try SolidKernel.fillet(box, edges: verticalEdges(box), radius: 5) }
        let top = try XCTUnwrap(topFace(rounded))
        let shelled = try time("shell 2 mm") { try SolidKernel.shell(rounded, openFaces: [top], thickness: 2) }
        let hole = try SolidKernel.extrude(circle(radius: 3, center: .init(x: 0, y: 15), plane: .front), depth: -60)
        let drilled = try time("boolean cut") { try SolidKernel.boolean(shelled, hole, .subtract) }
        let mesh = try time("tessellate") { try drilled.tessellate() }
        print("[kernel timing] triangles: \(mesh.triangleCount), faces: \(mesh.faces.count)")
        XCTAssertTrue(drilled.isValidSolid)
    }

    // MARK: - Helpers

    func topFace(_ solid: KernelSolid) -> Int? {
        let mesh = try? solid.tessellate()
        return mesh?.faces.indices.max { faceHeight(mesh!, $0) < faceHeight(mesh!, $1) }
    }

    func faceHeight(_ mesh: KernelMesh, _ face: Int) -> Float {
        let range = mesh.faces[face]
        guard !range.isEmpty else { return -.infinity }
        // A planar face whose every vertex is at the maximum height with an upward normal.
        let vertices = mesh.indices[range].map { Int($0) }
        let upward = vertices.allSatisfy { mesh.normals[$0].z > 0.999 }
        return upward ? vertices.map { mesh.positions[$0].z }.min()! : -.infinity
    }

    func verticalEdges(_ solid: KernelSolid) -> [Int] {
        let mesh = try! solid.tessellate()
        return mesh.edges.indices.filter { index in
            let points = mesh.edges[index].points
            guard let first = points.first, let last = points.last else { return false }
            return abs(first.x - last.x) < 1e-4 && abs(first.y - last.y) < 1e-4 && abs(first.z - last.z) > 1
        }
    }

    func edgeLength(_ solid: KernelSolid, _ edge: Int) -> Double {
        let points = try! solid.tessellate().edges[edge].points
        return zip(points, points.dropFirst()).reduce(0) { $0 + Double(simd_distance($1.0, $1.1)) }
    }

    func cylinderRim(_ solid: KernelSolid, _ edge: Int) -> Bool {
        let mesh = try! solid.tessellate()
        return mesh.edges[edge].isBoundary && mesh.edges[edge].points.count > 4
    }

    /// After welding coincident vertices, every triangle edge must be shared by exactly two triangles.
    func assertWatertight(_ mesh: KernelMesh, file: StaticString = #filePath, line: UInt = #line) throws {
        struct Key: Hashable { var x, y, z: Int }
        func key(_ p: SIMD3<Float>) -> Key { Key(x: Int((p.x * 1e4).rounded()), y: Int((p.y * 1e4).rounded()), z: Int((p.z * 1e4).rounded())) }
        var welded: [Key: Int] = [:]
        let ids = mesh.positions.map { p in welded[key(p)] ?? { welded[key(p)] = welded.count; return welded.count - 1 }() }
        var directed: [Int: Int] = [:]
        func edgeKey(_ a: Int, _ b: Int) -> Int { a * 1_000_000 + b }
        for t in 0..<mesh.triangleCount {
            let v = (0..<3).map { ids[Int(mesh.indices[3 * t + $0])] }
            if v[0] == v[1] || v[1] == v[2] || v[0] == v[2] { continue }
            for i in 0..<3 { directed[edgeKey(v[i], v[(i + 1) % 3]), default: 0] += 1 }
        }
        let bad = directed.filter { pair in pair.value != 1 || directed[edgeKey(pair.key % 1_000_000, pair.key / 1_000_000)] != 1 }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) non-manifold or open triangle edges", file: file, line: line)
    }

    /// Consistent winding: the signed volume of the triangle soup equals the solid's volume.
    func assertOutwardNormals(_ mesh: KernelMesh, file: StaticString = #filePath, line: UInt = #line) {
        var volume = 0.0
        for t in 0..<mesh.triangleCount {
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t])])
            let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 2])])
            volume += simd_dot(a, simd_cross(b, c)) / 6
            let n = simd_cross(b - a, c - a)
            let vertexNormal = SIMD3<Double>(mesh.normals[Int(mesh.indices[3 * t])])
            if simd_length(n) > 1e-9 {
                XCTAssertGreaterThan(simd_dot(simd_normalize(n), vertexNormal), 0, "Winding agrees with normals", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(volume, 0, "Triangles wind counter-clockwise seen from outside", file: file, line: line)
    }
}
