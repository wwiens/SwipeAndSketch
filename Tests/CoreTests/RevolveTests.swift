import XCTest
import simd
@testable import SwipeAndSketchCore

final class RevolveTests: XCTestCase {
    func rectangle(_ from: Point2, _ to: Point2, plane: SketchPlane = .top) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: .rectangle, plane: plane, start: from, end: to)], on: plane).first)
    }

    func circle(_ center: Point2, radius: Double, plane: SketchPlane = .top) throws -> SketchProfile {
        let shape = SketchShape(kind: .circle, plane: plane, start: center, end: center + Point2(x: radius, y: 0))
        return try XCTUnwrap(Geometry.profiles(in: [shape], on: plane).first)
    }

    /// The sketch's vertical axis (u = 0).
    let vertical = (from: Point2(x: 0, y: 0), to: Point2(x: 0, y: 1))

    func testRevolvesRectanglesAndCirclesOnEveryPlaneInBothDirections() throws {
        for plane in SketchPlane.allCases {
            for sign in [1.0, -1.0] {
                // Touching the axis: a solid cylinder, or part of one.
                let block = try rectangle(.init(x: 0, y: 0), .init(x: 10, y: 20), plane: plane)
                for angle in [360.0, 90] {
                    let spec = RevolveSpec(from: vertical.from, to: vertical.to, angle: sign * angle)
                    let solid = try SolidKernel.revolve(block, spec)
                    XCTAssertTrue(solid.isValidSolid, "\(plane) \(sign * angle)")
                    XCTAssertEqual(solid.volume, .pi * 100 * 20 * angle / 360, accuracy: 1e-6)
                }
                // Away from the axis: a ring.
                let ring = try SolidKernel.revolve(rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4), plane: plane),
                                                   RevolveSpec(from: vertical.from, to: vertical.to, angle: sign * 360))
                XCTAssertTrue(ring.isValidSolid)
                XCTAssertEqual(ring.volume, .pi * (100 - 25) * 4, accuracy: 1e-6)
                // A circle: a torus, exactly.
                let torus = try SolidKernel.revolve(circle(.init(x: 20, y: 0), radius: 5, plane: plane),
                                                    RevolveSpec(from: vertical.from, to: vertical.to, angle: sign * 360))
                XCTAssertTrue(torus.isValidSolid)
                XCTAssertEqual(torus.volume, 2 * .pi * .pi * 20 * 25, accuracy: 1e-6)
            }
        }
    }

    func testAnAxisThroughTheProfileIsRejected() throws {
        let block = try rectangle(.init(x: -5, y: 0), .init(x: 10, y: 20))
        let spec = RevolveSpec(from: vertical.from, to: vertical.to, angle: 360)
        XCTAssertFalse(spec.allows(block))
        XCTAssertThrowsError(try SolidKernel.revolve(block, spec)) { error in
            XCTAssertTrue("\(error)".contains("axis crosses"), "\(error)")
        }
        XCTAssertFalse(spec.allows(try circle(.init(x: 3, y: 0), radius: 5)))
        XCTAssertTrue(spec.allows(try circle(.init(x: 5, y: 0), radius: 5)), "A circle may touch the axis")
        XCTAssertFalse(RevolveSpec(from: .zero, to: .zero, angle: 90).isValid)
        for angle in [0.0, 0.05, 360.5, .nan] { XCTAssertFalse(RevolveSpec(from: vertical.from, to: vertical.to, angle: angle).isValid) }
    }

    func testPositiveAnglesLiftTheProfileTowardItsNormal() throws {
        for plane in SketchPlane.allCases {
            for profile in [try rectangle(.init(x: 2, y: 0), .init(x: 10, y: 5), plane: plane),
                            try rectangle(.init(x: -10, y: 0), .init(x: -2, y: 5), plane: plane)] {
                for (from, to) in [(vertical.from, vertical.to), (vertical.to, vertical.from)] {
                    for sign in [1.0, -1.0] {
                        let spec = RevolveSpec.oriented(from: from, to: to, angle: sign * 90, for: profile)
                        XCTAssertEqual(spec.sweepSign(for: profile), sign)
                        let bounds = try SolidKernel.revolve(profile, spec).bounds
                        let heights = [bounds.min, bounds.max].map { simd_dot($0, plane.normalAxis) }
                        XCTAssertEqual(sign > 0 ? heights.max()! : -heights.min()!, 10, accuracy: 1e-6, "\(plane)")
                        XCTAssertEqual(sign > 0 ? heights.min()! : heights.max()!, 0, accuracy: 1e-6)
                    }
                }
            }
        }
    }

    func testRevolvedBodiesBuildThroughTheCacheAndValidate() throws {
        let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4))
        let body = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 180, for: profile))
        XCTAssertTrue(body.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, .pi * 75 * 4 / 2, accuracy: 1e-6)
        var crossing = body
        crossing.revolve?.from.x = 7; crossing.revolve?.to.x = 7
        XCTAssertFalse(crossing.isValid)
        var zero = body
        zero.revolve?.angle = 0
        XCTAssertFalse(zero.isValid)
    }

    func testEveryKernelEdgeOfAPartialRevolveHasAUniqueName() throws {
        for plane in SketchPlane.allCases {
            for angle in [90.0, -135] {
                let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4), plane: plane)
                let body = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: angle, for: profile))
                let solid = try SolidKernel.solid(for: body)
                let names = (0..<solid.edgeCount).compactMap { body.extrusionEdge(along: solid.edgeSamples($0)) }
                XCTAssertEqual(names.count, 12, "\(plane) \(angle)")
                XCTAssertEqual(Set(names), Set(body.extrusionEdges))
            }
        }
        // A full revolve has only the rings its corners trace; seams are not edges to finish.
        let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4))
        let full = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 360, for: profile))
        let solid = try SolidKernel.solid(for: full)
        let names = (0..<solid.edgeCount).compactMap { full.extrusionEdge(along: solid.edgeSamples($0)) }
        XCTAssertEqual(Set(names), Set(full.extrusionEdges))
        XCTAssertEqual(names.count, 4)
        XCTAssertTrue(names.allSatisfy { $0.position == .side })
    }

    func testFilletAndChamferRingsAndShellAnEndFace() throws {
        let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4))
        var full = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 360, for: profile))
        let plain = try SolidKernel.solid(for: full).volume
        full.finishes = [EdgeFinish(kind: .fillet, edges: [ExtrusionEdge(position: .side, index: 1), ExtrusionEdge(position: .side, index: 2)], size: 1)]
        XCTAssertTrue(full.isValid)
        let rounded = try SolidKernel.solid(for: full)
        XCTAssertTrue(rounded.isValidSolid)
        XCTAssertLessThan(rounded.volume, plain)
        full.finishes = [EdgeFinish(kind: .chamfer, edges: [ExtrusionEdge(position: .side, index: 0)], size: 0.5)]
        XCTAssertLessThan(try SolidKernel.solid(for: full).volume, plain)

        var half = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 180, for: profile))
        XCTAssertEqual(half.extrusionFaces.count, 2)
        let solid = try SolidKernel.solid(for: half)
        let named = (0..<solid.faceCount).compactMap { index in solid.facePlane(index).flatMap { half.extrusionFace(point: $0.origin, normal: $0.normal) } }
        XCTAssertEqual(Set(named), Set(half.extrusionFaces), "The start and end faces are found by their planes")
        let before = solid.volume
        half.cuts = [.shell(of: half, openFaces: [ExtrusionFace(position: .cap, index: 0)], thickness: 1)]
        let shelled = try SolidKernel.solid(for: half)
        XCTAssertTrue(shelled.isValidSolid)
        XCTAssertLessThan(shelled.volume, before)
    }

    func testRevolvedCutsAndJoins() throws {
        let box = SolidBody(profile: try rectangle(.init(x: -30, y: -20), .init(x: 30, y: 20)), depth: 20)
        // A 5 mm-deep, 5 mm-radius pocket in the top: a Front-plane rectangle turned about Z.
        let pocket = try rectangle(.init(x: 0, y: 15), .init(x: 5, y: 25), plane: .front)
        var cut = ExtrusionCut(profile: pocket, depth: 0, operation: .cut)
        cut.revolve = .oriented(from: vertical.from, to: vertical.to, angle: 360, for: pocket)
        var body = box
        body.cuts = [cut]
        XCTAssertTrue(body.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 48_000 - .pi * 25 * 5, accuracy: 1e-4)
        var join = cut
        join.join = true
        body.cuts = [join]
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 48_000 + .pi * 25 * 5, accuracy: 1e-4)
        join.throughAll = true
        XCTAssertFalse(join.isValid)
    }

    func testAFlatFaceRevolvesAboutItsOwnEdge() throws {
        let box = SolidBody(profile: try rectangle(.init(x: -10, y: -10), .init(x: 10, y: 10)), depth: 10)
        let solid = try SolidKernel.solid(for: box)
        let top = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0).map { $0.normal.z > 0.9999 } ?? false })
        let source = try XCTUnwrap(FaceExtrusionSource(body: box, face: top))
        let plane = source.profile.plane
        // About the top face's back edge (y = 10), out of the solid: a quarter cylinder of radius 20.
        let spec = RevolveSpec.oriented(from: plane.coordinates(of: .init(-10, 10, 10)), to: plane.coordinates(of: .init(10, 10, 10)),
                                        angle: 90, for: source.profile)
        var join = source.operation(depth: 1)
        join.depth = 0
        join.join = true
        join.revolve = spec
        var body = box
        body.cuts = [join]
        XCTAssertTrue(body.isValid)
        XCTAssertEqual(try SolidKernel.solid(for: body).volume, 4_000 + .pi * 400 / 4 * 20, accuracy: 1e-3)
    }

    func testMovingAndTurningARevolvedSolidCarriesItsAxis() throws {
        let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4), plane: .front)
        var body = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 270, for: profile))
        body.finishes = [EdgeFinish(kind: .fillet, edges: [ExtrusionEdge(position: .side, index: 2)], size: 0.5)]
        let volume = try SolidKernel.solid(for: body).volume
        let center = try XCTUnwrap(Workspace(bodies: [body]).center(of: body))
        let motion = RigidTransform.rotate(degrees: 37, about: .init(1, 2, 3), through: .init(5, 5, 5))
        let moved = try XCTUnwrap(body.transformed(by: motion))
        XCTAssertEqual(moved.revolve, body.revolve, "The axis is stored in the plane's own coordinates")
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, volume, accuracy: volume * 1e-6)
        let movedCenter = try XCTUnwrap(Workspace(bodies: [moved]).center(of: moved))
        XCTAssertLessThan(simd_distance(movedCenter, motion.apply(point: center)), 2, "Bounding boxes turn loosely, but the solid goes with the motion")
    }

    func testRevolveRoundTripAndExport() throws {
        let profile = try rectangle(.init(x: 5, y: 0), .init(x: 10, y: 4))
        let ring = SolidBody(profile: profile, revolve: .oriented(from: vertical.from, to: vertical.to, angle: 360, for: profile))
        let project = Project(workspace: Workspace(bodies: [ring]))
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)), project)
        // A revolve that crosses its axis is invalid model data.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectCodec.encode(project)) as? [String: Any])
        var workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        var bodies = try XCTUnwrap(workspace["bodies"] as? [[String: Any]])
        var revolve = try XCTUnwrap(bodies[0]["revolve"] as? [String: Any])
        revolve["from"] = ["x": 7, "y": 0]; revolve["to"] = ["x": 7, "y": 1]
        bodies[0]["revolve"] = revolve; workspace["bodies"] = bodies; json["workspace"] = workspace
        XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json)))

        let mesh = try XCTUnwrap(ModelExport.meshes([ring]).first)
        var directed: [UInt64: Int] = [:]
        for t in mesh.triangles { for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { directed[UInt64(a) << 32 | UInt64(b), default: 0] += 1 } }
        XCTAssertTrue(directed.allSatisfy { $0.value == 1 && directed[($0.key & 0xFFFF_FFFF) << 32 | ($0.key >> 32)] == 1 }, "Watertight")
    }
}
