import XCTest
import simd
@testable import SwipeAndSketchCore

/// The kernel operations behind the missing basics (October 21, 2026): scale, delete face, offset
/// face, tapered and ellipse extrusions, and 2D offsets.
final class KernelBasicsTests: XCTestCase {
    func box(_ width: Double = 20, _ depthY: Double = 10, height: Double = 10) throws -> KernelSolid {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .zero, end: .init(x: width, y: depthY))
        return try SolidKernel.extrude(try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first), depth: height)
    }

    func testUniformAndStretchedScale() throws {
        let solid = try box()
        let twice = try SolidKernel.scaled(solid, about: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)], factors: SIMD3(repeating: 2))
        XCTAssertEqual(twice.volume, 8 * 2000, accuracy: 1e-6)
        XCTAssertEqual(twice.bounds.max.x, 40, accuracy: 1e-9)
        let stretched = try SolidKernel.scaled(solid, about: SIMD3(10, 5, 0), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)], factors: SIMD3(1, 1, 3))
        XCTAssertEqual(stretched.volume, 3 * 2000, accuracy: 1e-6)
        XCTAssertEqual(stretched.bounds.max.z, 30, accuracy: 1e-6)
        XCTAssertEqual(stretched.bounds.min.x, 0, accuracy: 1e-6)
        XCTAssertTrue(stretched.isValidSolid)
        XCTAssertThrowsError(try SolidKernel.scaled(solid, about: .zero, axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)], factors: SIMD3(0, 1, 1)))
    }

    func testRemovingAFilletAndAHole() throws {
        let solid = try box()
        // Round the top edge along x at y = 10.
        let edge = try XCTUnwrap(solid.edge(near: SIMD3(10, 10, 10)))
        let rounded = try SolidKernel.fillet(solid, edges: [edge], radius: 2)
        XCTAssertLessThan(rounded.volume, 2000)
        let fillet = try XCTUnwrap((0..<rounded.faceCount).first { rounded.facePlane($0) == nil })
        let healed = try SolidKernel.removingFaces([fillet], from: rounded)
        XCTAssertEqual(healed.volume, 2000, accuracy: 1e-6)
        XCTAssertEqual(healed.faceCount, 6)
        // A through hole: its wall comes out and the top and bottom close over it.
        let circle = SketchShape(kind: .circle, plane: .top, start: .init(x: 10, y: 5), end: .init(x: 12, y: 5))
        let tool = try SolidKernel.extrude(try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first), depth: 10)
        let drilled = try SolidKernel.boolean(solid, tool, .subtract)
        let wall = try XCTUnwrap((0..<drilled.faceCount).first { drilled.faceCylinder($0) != nil })
        XCTAssertEqual(try SolidKernel.removingFaces([wall], from: drilled).volume, 2000, accuracy: 1e-6)
    }

    func testOffsettingAFlatFaceAndARoundFace() throws {
        let solid = try box()
        let top = try XCTUnwrap(solid.face(containing: SIMD3(10, 5, 10), normal: SIMD3(0, 0, 1)))
        let raised = try SolidKernel.offsettingFaces([top], of: solid, by: 3)
        XCTAssertEqual(raised.volume, 20 * 10 * 13, accuracy: 1e-6)
        let lowered = try SolidKernel.offsettingFaces([top], of: solid, by: -4)
        XCTAssertEqual(lowered.volume, 20 * 10 * 6, accuracy: 1e-6)
        // A cylinder's side, grown from radius 5 to 6.
        let circle = SketchShape(kind: .circle, plane: .top, start: .zero, end: .init(x: 5, y: 0))
        let cylinder = try SolidKernel.extrude(try XCTUnwrap(Geometry.profiles(in: [circle], on: .top).first), depth: 10)
        let side = try XCTUnwrap((0..<cylinder.faceCount).first { cylinder.faceCylinder($0) != nil })
        let grown = try SolidKernel.offsettingFaces([side], of: cylinder, by: 1)
        XCTAssertEqual(grown.volume, .pi * 36 * 10, accuracy: 1e-3)
        // A hole's wall moved outward (away from the material it faces) makes the hole smaller.
        let tool = try SolidKernel.extrude(try XCTUnwrap(Geometry.profiles(in: [SketchShape(kind: .circle, plane: .top, start: .init(x: 10, y: 5), end: .init(x: 12, y: 5))], on: .top).first), depth: 10)
        let drilled = try SolidKernel.boolean(solid, tool, .subtract)
        let wall = try XCTUnwrap((0..<drilled.faceCount).first { drilled.faceCylinder($0) != nil })
        let tighter = try SolidKernel.offsettingFaces([wall], of: drilled, by: 1)
        XCTAssertEqual(tighter.volume, 2000 - .pi * 1 * 10, accuracy: 1e-3)
    }

    func testTaperedExtrusionsNarrowTowardTheFarEndEitherWay() throws {
        let shape = SketchShape(kind: .rectangle, plane: .top, start: .init(x: -10, y: -10), end: .init(x: 10, y: 10))
        let profile = try XCTUnwrap(Geometry.profiles(in: [shape], on: .top).first)
        XCTAssertThrowsError(try SolidKernel.extrude(profile, depth: 12, taper: 45), "Closes before the far end")
        let gentle = try SolidKernel.extrude(profile, depth: 5, taper: 45)
        // 20 × 20 at the base, 10 × 10 at the top: (h/3)(A1 + A2 + √(A1 A2)).
        XCTAssertEqual(gentle.volume, 5.0 / 3 * (400 + 100 + 200), accuracy: 1e-3)
        let down = try SolidKernel.extrude(profile, depth: -5, taper: 45)
        XCTAssertEqual(down.volume, gentle.volume, accuracy: 1e-3)
        XCTAssertEqual(down.bounds.min.z, -5, accuracy: 1e-6)
        let outward = try SolidKernel.extrude(profile, depth: 5, taper: -45)
        XCTAssertEqual(outward.volume, 5.0 / 3 * (400 + 900 + 600), accuracy: 1e-3)
        let lifted = try SolidKernel.extrude(profile, depth: 4, offset: -2)
        XCTAssertEqual(lifted.bounds.min.z, -2, accuracy: 1e-9)
        XCTAssertEqual(lifted.bounds.max.z, 2, accuracy: 1e-9)
    }

    func testExactEllipseRegionsExtrudeAndRevolve() throws {
        let ellipse = EllipseProfile(center: .init(x: 30, y: 0), radiusX: 10, radiusY: 4, angle: .pi / 6)
        let profile = SketchProfile(id: "e", plane: .top, sourceIDs: [], outline: ellipse.outline(), ellipse: ellipse)
        XCTAssertTrue(profile.isSolidProfile)
        let solid = try SolidKernel.extrude(profile, depth: 5)
        XCTAssertEqual(solid.volume, .pi * 10 * 4 * 5, accuracy: 1e-6)
        XCTAssertEqual(solid.faceCount, 3, "One smooth side")
        // As a hole in a plate.
        let plate = SketchShape(kind: .rectangle, plane: .top, start: .init(x: 10, y: -20), end: .init(x: 50, y: 20))
        var region = try XCTUnwrap(Geometry.profiles(in: [plate], on: .top).first)
        region.holes = [ProfileHole(outline: ellipse.outline(), ellipse: ellipse)]
        XCTAssertTrue(region.isSolidProfile)
        XCTAssertEqual(try SolidKernel.extrude(region, depth: 2).volume, (40 * 40 - .pi * 40) * 2, accuracy: 1e-6)
        // Tapered (its curved side is lofted to an offset ellipse): about a frustum's volume.
        let tapered = try SolidKernel.extrude(profile, depth: 10, taper: 5)
        // An inward offset by d has area A − P·d + π·d² (Steiner), so the prismoidal rule is exact.
        let a = 10.0, b = 4.0, h = pow(a - b, 2) / pow(a + b, 2), perimeter = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
        func area(_ d: Double) -> Double { .pi * a * b - perimeter * d + .pi * d * d }
        let inset = 10 * tan(5 * Double.pi / 180)
        XCTAssertEqual(tapered.volume, 10.0 / 6 * (area(0) + 4 * area(inset / 2) + area(inset)), accuracy: 0.5)
        XCTAssertEqual(tapered.bounds.max.z, 10, accuracy: 1e-6)
        // Revolved about the y axis, the ellipse sweeps a torus of elliptic section.
        let ring = try SolidKernel.revolve(profile, RevolveSpec(from: .zero, to: .init(x: 0, y: 1), angle: 360))
        XCTAssertEqual(ring.volume, 2 * .pi * 30 * .pi * 10 * 4, accuracy: 1)
    }

    func testOffsetOutlines() throws {
        // A 20 × 10 rectangle, outward 2 with sharp corners: 24 × 14.
        let rectangle = SolidKernel.OutlineLoop(points: [.init(x: 0, y: 0), .init(x: 20, y: 0), .init(x: 20, y: 10), .init(x: 0, y: 10)],
                                                mids: [nil, nil, nil, nil], closed: true)
        let out = try SolidKernel.offset(rectangle, on: .top, by: 2, rounded: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].points.count, 4)
        XCTAssertTrue(out[0].closed)
        XCTAssertEqual(abs(Geometry.signedArea(out[0].points)), 24 * 14, accuracy: 1e-6)
        let rounded = try SolidKernel.offset(rectangle, on: .top, by: 2, rounded: true)
        XCTAssertEqual(rounded[0].mids.compactMap { $0 }.count, 4, "A quarter circle at each corner")
        let inward = try SolidKernel.offset(rectangle, on: .top, by: -2, rounded: false)
        XCTAssertEqual(abs(Geometry.signedArea(inward[0].points)), 16 * 6, accuracy: 1e-6)
        // A circle stays a circle.
        let circle = SolidKernel.OutlineLoop(points: [.init(x: 5, y: 0)], mids: [.zero], closed: true)
        let bigger = try SolidKernel.offset(circle, on: .top, by: 1, rounded: false)
        XCTAssertEqual(bigger[0].points.count, 1)
        XCTAssertEqual(bigger[0].points[0].distance(to: bigger[0].mids[0] ?? .init(x: 99, y: 99)), 6, accuracy: 1e-9)
        // An open chain moves to one side.
        let chain = SolidKernel.OutlineLoop(points: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 10, y: 10)], mids: [nil, nil, nil], closed: false)
        let side = try SolidKernel.offset(chain, on: .top, by: 1, rounded: false)
        XCTAssertFalse(side[0].closed)
        XCTAssertGreaterThanOrEqual(side[0].points.count, 3)
    }
}
