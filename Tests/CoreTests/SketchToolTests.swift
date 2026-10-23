import XCTest
import simd
@testable import SwipeAndSketchCore

/// Inch units, Arc and Slot, regions that divide and hold holes, Trim, sketch Fillet, and
/// dimensions between sketch items.
final class SketchToolTests: XCTestCase {
    func line(_ a: Point2, _ b: Point2) -> SketchShape { SketchShape(kind: .line, plane: .top, start: a, end: b) }
    func rectangle(_ a: Point2, _ b: Point2) -> SketchShape { SketchShape(kind: .rectangle, plane: .top, start: a, end: b) }
    func circle(_ c: Point2, _ r: Double) -> SketchShape { SketchShape(kind: .circle, plane: .top, start: c, end: c + Point2(x: r, y: 0)) }
    func sketch(_ shapes: [SketchShape]) -> Workspace { Workspace(shapes: shapes) }

    // MARK: Units

    func testInchesAreTypedShownAndSnapped() {
        XCTAssertEqual(DimensionExpression.evaluate("1in"), 25.4)
        XCTAssertEqual(DimensionExpression.evaluate("2\""), 50.8)
        XCTAssertEqual(DimensionExpression.evaluate("10mm+1cm"), 20)
        // Bare numbers are in the chosen unit; other units convert to it.
        XCTAssertEqual(DimensionExpression.evaluate("2*3", unit: .inches), 6)
        XCTAssertEqual(try XCTUnwrap(DimensionExpression.evaluate("25.4mm", unit: .inches)), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(DimensionExpression.evaluate("1 + 12.7mm", unit: .inches)), 1.5, accuracy: 1e-12)
        XCTAssertNil(DimensionExpression.evaluate("1i"))
        // A comma that may group thousands is refused, not read as a decimal point; a length times a length is not a length.
        XCTAssertNil(DimensionExpression.evaluate("1,000"))
        XCTAssertEqual(DimensionExpression.evaluate("1,5"), 1.5)
        XCTAssertNil(DimensionExpression.evaluate("3mm*2mm", unit: .inches))
        XCTAssertEqual(DimensionExpression.evaluate("3mm*2"), 6)
        XCTAssertEqual(DimensionExpression.evaluate("10mm/2mm"), 5)
        XCTAssertNil(DimensionExpression.evaluate("10/2mm"))
        XCTAssertEqual(LengthUnit.inches.rounded(10), 9.906, accuracy: 1e-9, "0.39 in")
        XCTAssertEqual(LengthUnit.millimeters.rounded(10.04), 10, accuracy: 1e-9)
        XCTAssertEqual(LengthUnit.inches.gridStep(atLeast: 5), 25.4 / 4, "a quarter inch")
        XCTAssertEqual(LengthUnit.millimeters.gridStep(atLeast: 3), 5)
        XCTAssertEqual(LengthUnit.inches.snapGrid(for: 25.4), 25.4 / 16)
    }

    // MARK: Arc and Slot

    func testThreePointArcsRunCounterclockwiseThroughTheMiddlePoint() throws {
        let up = try XCTUnwrap(SketchShape.arc(from: .zero, through: .init(x: 5, y: 5), to: .init(x: 10, y: 0), plane: .top))
        XCTAssertEqual(up.arcCenter?.x ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(up.arcCenter?.y ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(up.arcSweep, .pi, accuracy: 1e-9)
        XCTAssertEqual(up.arcMiddle.y, 5, accuracy: 1e-9, "Drawn clockwise, it is stored the other way round")
        let down = try XCTUnwrap(SketchShape.arc(from: .zero, through: .init(x: 5, y: -2), to: .init(x: 10, y: 0), plane: .top))
        XCTAssertLessThan(down.arcMiddle.y, 0)
        XCTAssertNil(SketchShape.arc(from: .zero, through: .init(x: 5, y: 0), to: .init(x: 10, y: 0), plane: .top), "Three points in a line")
        // Radius: the ends stay put.
        let wider = try XCTUnwrap(SketchEditing.dimension(.radius, value: 10, of: up))
        XCTAssertEqual(wider.start.distance(to: up.start) + wider.end.distance(to: up.end), 0, accuracy: 1e-9)
        XCTAssertEqual(ShapeDimension.radius.value(of: wider), 10, accuracy: 1e-9)
        XCTAssertNil(SketchEditing.dimension(.radius, value: 4, of: up), "Smaller than half the chord")
        XCTAssertNotNil(SketchEditing.dimension(.radius, value: 5, of: up), "A half circle keeps its radius")
        // Dragging the middle keeps both ends.
        let flatter = try XCTUnwrap(SketchEditing.dragging(up, handle: .mid, to: .init(x: 5, y: 2)))
        XCTAssertEqual(flatter.arcMiddle.y, 2, accuracy: 1e-9)
    }

    func testJoinedArcsFollowAMovedLineEnd() throws {
        let arc = SketchShape.arc(center: .init(x: 10, y: 0), from: .init(x: 20, y: 0), to: .init(x: 0, y: 0), plane: .top)
        let base = line(.zero, .init(x: 20, y: 0))
        let workspace = sketch([base, arc])
        XCTAssertEqual(Geometry.profiles(in: workspace.shapes, on: .top).count, 1, "A half disc")
        let moved = try XCTUnwrap(SketchEditing.dragging(base, handle: .end, to: .init(x: 30, y: 0)))
        let next = try XCTUnwrap(SketchEditing.replacing(moved, in: workspace))
        let followed = try XCTUnwrap(next.shapes.first { $0.kind == .arc })
        XCTAssertEqual(followed.start.x, 30, accuracy: 1e-9)
        XCTAssertEqual(followed.arcSweep, .pi, accuracy: 1e-9, "It keeps its sweep")
        XCTAssertEqual(Geometry.profiles(in: next.shapes, on: .top).first?.area ?? 0, .pi * 225 / 2, accuracy: 0.5)
    }

    func testSlotsAreClosedRegionsWithExactRoundEnds() throws {
        let slot = SketchShape.slot(from: .init(x: -10, y: 0), to: .init(x: 10, y: 0), width: 6, plane: .top)
        XCTAssertTrue(slot.isValid)
        XCTAssertTrue(slot.isClosed)
        let profile = try XCTUnwrap(Geometry.profiles(in: [slot], on: .top).first)
        XCTAssertEqual(profile.area, 20 * 6 + .pi * 9, accuracy: 0.05)
        XCTAssertEqual(profile.arcs?.count, 2)
        XCTAssertTrue(profile.isSolidProfile)
        let body = SolidBody(profile: profile, depth: 5)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, (20 * 6 + .pi * 9) * 5, accuracy: 1e-3, "Exact round ends")
        XCTAssertEqual(ShapeDimension.width.value(of: slot), 6)
        XCTAssertEqual(ShapeDimension.length.value(of: slot), 20)
        let wide = try XCTUnwrap(SketchEditing.dragging(slot, handle: .side(0), to: .init(x: 0, y: 5)))
        XCTAssertEqual(wide.width ?? 0, 10, accuracy: 1e-9)
        var slotWithoutWidth = slot; slotWithoutWidth.width = nil
        XCTAssertFalse(slotWithoutWidth.isValid)
    }

    // MARK: Regions

    func testOverlappingRectanglesDivideIntoThreeRegions() throws {
        let shapes = [rectangle(.zero, .init(x: 20, y: 20)), rectangle(.init(x: 10, y: 10), .init(x: 30, y: 30))]
        let profiles = Geometry.profiles(in: shapes, on: .top)
        XCTAssertEqual(profiles.map(\.area), [100, 300, 300])
        XCTAssertTrue(profiles.allSatisfy(\.isSolidProfile))
        XCTAssertEqual(Set(profiles.map(\.id)).count, 3, "Each region has its own id")
        // The ids stay the same when asked again.
        XCTAssertEqual(Geometry.profiles(in: shapes, on: .top).map(\.id), profiles.map(\.id))
        for profile in profiles { XCTAssertTrue(try SolidKernel.solid(for: SolidBody(profile: profile, depth: 4)).isValidSolid) }
    }

    func testALineAcrossARectangleOrCornerToCornerDividesIt() {
        let box = rectangle(.zero, .init(x: 40, y: 20))
        let across = Geometry.profiles(in: [box, line(.init(x: 10, y: -5), .init(x: 10, y: 25))], on: .top)
        XCTAssertEqual(across.map(\.area), [200, 600])
        let diagonal = Geometry.profiles(in: [box, line(.zero, .init(x: 40, y: 20))], on: .top)
        XCTAssertEqual(diagonal.map(\.area), [400, 400])
        // A line that only touches the rectangle leaves it whole, with its own id.
        let touching = Geometry.profiles(in: [box, line(.init(x: 40, y: 20), .init(x: 60, y: 30))], on: .top)
        XCTAssertEqual(touching.count, 1)
        XCTAssertEqual(touching.first?.id, box.id.uuidString)
        // A line poking into the rectangle does not spoil it.
        let poking = Geometry.profiles(in: [box, line(.init(x: 20, y: 0), .init(x: 20, y: 10))], on: .top)
        XCTAssertEqual(poking.map(\.area), [800])
    }

    func testACircleCrossingARectangleKeepsExactArcs() throws {
        let shapes = [rectangle(.zero, .init(x: 20, y: 20)), circle(.init(x: 20, y: 10), 5)]
        let profiles = Geometry.profiles(in: shapes, on: .top)
        XCTAssertEqual(profiles.count, 3)
        let halves = profiles.filter { abs($0.area - .pi * 12.5) < 0.05 }
        XCTAssertEqual(halves.count, 2, "Each half of the circle")
        XCTAssertTrue(profiles.allSatisfy { $0.arcs?.count == 1 })
        let notched = try XCTUnwrap(profiles.max { $0.area < $1.area })
        XCTAssertEqual(notched.area, 400 - .pi * 12.5, accuracy: 0.05)
        let solid = try SolidKernel.solid(for: SolidBody(profile: notched, depth: 10))
        XCTAssertEqual(solid.volume, (400 - .pi * 12.5) * 10, accuracy: 1e-3, "The notch is exactly round")
    }

    func testAnOutlineInsideARegionIsAHoleInIt() throws {
        let plate = rectangle(.init(x: -30, y: -20), .init(x: 30, y: 20))
        let bore = circle(.zero, 5)
        let pocket = SketchShape.slot(from: .init(x: 15, y: 0), to: .init(x: 22, y: 0), width: 4, plane: .top)
        let profiles = Geometry.profiles(in: [plate, bore, pocket], on: .top)
        XCTAssertEqual(profiles.count, 3)
        let outer = try XCTUnwrap(profiles.first { $0.id == plate.id.uuidString })
        XCTAssertEqual(outer.holes?.count, 2)
        XCTAssertEqual(outer.holes?.first { $0.circle != nil }?.circle?.radius, 5)
        XCTAssertTrue(outer.isSolidProfile)
        XCTAssertFalse(outer.contains(.zero), "The hole is not part of the plate")
        XCTAssertTrue(outer.contains(.init(x: 0, y: 10)))
        XCTAssertTrue(try XCTUnwrap(profiles.first { $0.id == bore.id.uuidString }).contains(.zero), "The circle is a region of its own")
        let solid = try SolidKernel.solid(for: SolidBody(profile: outer, depth: 8))
        let slotArea = 7.0 * 4 + Double.pi * 4
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, (2400 - .pi * 25 - slotArea) * 8, accuracy: 1e-3)
        // Revolving a region with a hole makes a hollow ring.
        var ring = SolidBody(profile: try XCTUnwrap(Geometry.profiles(in: [rectangle(.init(x: 20, y: -5), .init(x: 30, y: 5)), circle(.init(x: 25, y: 0), 2)], on: .top).last), depth: 1)
        XCTAssertEqual(ring.profile.holes?.count, 1)
        ring.revolve = RevolveSpec(from: .init(x: 0, y: -1), to: .init(x: 0, y: 1), angle: 360)
        XCTAssertEqual(try SolidKernel.solid(for: ring).volume, 2 * .pi * 25 * (100 - .pi * 4), accuracy: 0.01)
        // Holes come with the file and mirror with the solid.
        let body = SolidBody(profile: outer, depth: 8)
        let project = Project(workspace: Workspace(shapes: [plate, bore, pocket], bodies: [body]))
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(project)).workspace, project.workspace)
        let image = try XCTUnwrap(body.mirrored(by: XCTUnwrap(Reflection(across: .front))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, solid.volume, accuracy: 1e-3)
    }

    func testTangentShapesKeepTheirRegions() throws {
        func areas(_ shapes: [SketchShape]) -> [Double] { Geometry.profiles(in: shapes, on: .top).map(\.area).sorted() }
        func assertAreas(_ shapes: [SketchShape], _ expected: [Double], _ message: String, line: UInt = #line) {
            let found = areas(shapes)
            XCTAssertEqual(found.count, expected.count, message, line: line)
            for (a, b) in zip(found, expected.sorted()) { XCTAssertEqual(a, b, accuracy: 0.05 * max(1, b / 100), message, line: line) }
        }
        let box = rectangle(.zero, .init(x: 40, y: 20))
        // A circle resting on a rectangle, and one tangent to two others: each stays its own region.
        let resting = Geometry.profiles(in: [box, circle(.init(x: 20, y: 30), 10)], on: .top)
        XCTAssertTrue(resting.contains { $0.id == box.id.uuidString }, "a closed shape that only touches keeps its own id")
        assertAreas([box, circle(.init(x: 20, y: 30), 10)], [800, 100 * .pi], "circle resting on a rectangle")
        XCTAssertEqual(resting.first { $0.circle != nil }?.circle?.radius ?? 0, 10, accuracy: 1e-9, "the disc keeps its exact circle")
        assertAreas([circle(.zero, 10), circle(.init(x: 25, y: 0), 15)], [100 * .pi, 225 * .pi], "circles touching outside")
        assertAreas([circle(.zero, 20), circle(.init(x: 10, y: 0), 10)], [100 * .pi], "the inner of two circles touching inside")
        // A circle inscribed in a square: the disc and four corners.
        let corner = (400 - 100 * Double.pi) / 4
        assertAreas([rectangle(.zero, .init(x: 20, y: 20)), circle(.init(x: 10, y: 10), 10)], [100 * .pi, corner, corner, corner, corner], "inscribed circle")
        let slot = SketchShape(kind: .slot, plane: .top, start: .zero, end: .init(x: 20, y: 0), width: 10)
        assertAreas([slot, circle(.init(x: 10, y: 15), 10)], [20 * 10 + 25 * .pi, 100 * .pi], "a circle resting on a slot")
    }

    func testAnArcOnACirclesPathDividesWithIt() throws {
        // A circle, an arc along its top half, and the diameter under it: two half discs.
        let arc = try XCTUnwrap(SketchShape.arc(from: .init(x: 10, y: 0), through: .init(x: 0, y: 10), to: .init(x: -10, y: 0), plane: .top))
        let diameter = line(.init(x: -10, y: 0), .init(x: 10, y: 0))
        let profiles = Geometry.profiles(in: [circle(.zero, 10), arc, diameter], on: .top)
        XCTAssertEqual(profiles.count, 2)
        for profile in profiles { XCTAssertEqual(profile.area, 50 * .pi, accuracy: 0.2) }
    }

    func testNestedOutlinesAlternate() {
        let profiles = Geometry.profiles(in: [circle(.zero, 30), circle(.zero, 20), circle(.zero, 10)], on: .top)
        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(profiles.map { $0.holes?.count ?? 0 }, [0, 1, 1], "Each ring holds only the next circle in")
        for (area, expected) in zip(profiles.map(\.area), [Double.pi * 100, .pi * 300, .pi * 500]) { XCTAssertEqual(area, expected, accuracy: 2) }
    }

    func testARingsExtrudeArrowSitsOnTheRingNotItsHole() throws {
        // An offset rectangle inside another: the outer region's center is in its hole.
        let profiles = Geometry.profiles(in: [rectangle(.zero, .init(x: 82, y: 39)), rectangle(.init(x: 2, y: 2), .init(x: 80, y: 37))], on: .top)
        let ring = try XCTUnwrap(profiles.first { $0.holes?.count == 1 })
        XCTAssertFalse(ring.contains(ring.center))
        XCTAssertTrue(ring.contains(ring.anchor), "The arrow is on the ring")
        XCTAssertEqual(ring.anchor.y, ring.center.y, accuracy: 1e-9)
        let plain = try XCTUnwrap(profiles.first { $0.holes == nil })
        XCTAssertEqual(plain.anchor, plain.center, "A region without holes keeps its center")
        // A bore off the center leaves the center where it is.
        let plate = try XCTUnwrap(Geometry.profiles(in: [rectangle(.zero, .init(x: 40, y: 20)), circle(.init(x: 30, y: 10), 3)], on: .top).first { $0.holes != nil })
        XCTAssertEqual(plate.anchor, plate.center)
    }

    // MARK: Trim and Fillet

    func testTrimRemovesTheStretchBetweenCrossings() throws {
        let box = rectangle(.zero, .init(x: 40, y: 20))
        let cross = line(.init(x: 10, y: -10), .init(x: 10, y: 30))
        var workspace = sketch([box, cross])
        // The line's middle, inside the rectangle, goes; its two ends outside stay.
        workspace = try XCTUnwrap(SketchModify.trim(cross.id, at: .init(x: 10, y: 10), in: workspace))
        XCTAssertEqual(workspace.shapes.filter { $0.kind == .line }.count, 2)
        XCTAssertEqual(Geometry.profiles(in: workspace.shapes, on: .top).map(\.area), [800])
        // The rectangle's left side between the corner and the crossing.
        let trimmed = try XCTUnwrap(SketchModify.trim(box.id, at: .init(x: 5, y: 0), in: sketch([box, cross])))
        XCTAssertFalse(trimmed.shapes.contains { $0.kind == .rectangle }, "The rectangle became lines")
        XCTAssertTrue(trimmed.shapes.contains { $0.kind == .line && $0.start == Point2(x: 10, y: 0) && $0.end == Point2(x: 40, y: 0) })
        // A shape nothing crosses goes whole.
        XCTAssertEqual(SketchModify.trim(cross.id, at: .zero, in: sketch([cross]))?.shapes.count, 0)
        // A circle crossed twice keeps the arc on the other side.
        let ring = circle(.zero, 10)
        let chord = line(.init(x: -20, y: 5), .init(x: 20, y: 5))
        let cut = try XCTUnwrap(SketchModify.trim(ring.id, at: .init(x: 0, y: 10), in: sketch([ring, chord])))
        let arc = try XCTUnwrap(cut.shapes.first { $0.id == ring.id })
        XCTAssertEqual(arc.kind, .arc)
        XCTAssertLessThan(arc.arcMiddle.y, 0)
        XCTAssertEqual(Geometry.profiles(in: cut.shapes, on: .top).count, 1)
    }

    func testFilletRoundsACornerWithATangentArc() throws {
        let box = rectangle(.zero, .init(x: 40, y: 20))
        var workspace = sketch([box])
        let rounded = try XCTUnwrap(SketchModify.roundCorner(at: .init(x: 40, y: 20), radius: 5, sketch: try XCTUnwrap(workspace.shapes[0].sketch), in: workspace))
        workspace = rounded.workspace
        XCTAssertEqual(workspace.shapes.filter { $0.kind == .line }.count, 4)
        let arc = try XCTUnwrap(workspace.shapes.first { $0.id == rounded.arc })
        XCTAssertEqual(arc.arcCenter?.x ?? 0, 35, accuracy: 1e-9)
        XCTAssertEqual(arc.arcCenter?.y ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(arc.arcSweep, .pi / 2, accuracy: 1e-9)
        let profile = try XCTUnwrap(Geometry.profiles(in: workspace.shapes, on: .top).first)
        XCTAssertEqual(profile.area, 800 - 25 + .pi * 25 / 4, accuracy: 0.05)
        XCTAssertTrue(try SolidKernel.solid(for: SolidBody(profile: profile, depth: 3)).isValidSolid)
        XCTAssertNil(SketchModify.roundCorner(at: .zero, radius: 30, sketch: try XCTUnwrap(workspace.shapes[0].sketch), in: workspace), "Too large for the sides")
        XCTAssertEqual(SketchModify.corners(in: workspace.shapes).count, 3)
    }

    // MARK: Dimensions between items

    func testPointsAreDimensionedAcrossAndUpAndMoveTheirOutline() throws {
        let plate = rectangle(.zero, .init(x: 40, y: 20))
        let bore = circle(.init(x: 12, y: 7), 3)
        let workspace = sketch([plate, bore])
        let corner = try XCTUnwrap(SketchReference.part(.corner(0), of: plate)), center = try XCTUnwrap(SketchReference.part(.center, of: bore))
        let dimensions = SketchDimensions.dimensions(corner, center, in: workspace)
        XCTAssertEqual(dimensions.map(\.kind), [.horizontal, .vertical, .distance])
        XCTAssertEqual(dimensions[0].value, 12)
        let moved = try XCTUnwrap(SketchDimensions.applying(.horizontal, value: 6, corner, center, in: workspace))
        XCTAssertEqual(moved.shapes[1].start, Point2(x: 6, y: 7), "The circle moves; the rectangle stays")
        XCTAssertEqual(moved.shapes[0], workspace.shapes[0])
        let up = try XCTUnwrap(SketchDimensions.applying(.vertical, value: 10, corner, center, in: moved))
        XCTAssertEqual(up.shapes[1].start, Point2(x: 6, y: 10))
        // A fixed reference (from a solid) stays; the sketch moves instead, whichever was picked first.
        let edge = SketchReference.fixed(.line(.init(x: 0, y: -5), .init(x: 40, y: -5)))
        let fromEdge = try XCTUnwrap(SketchDimensions.applying(.distance, value: 5, center, edge, in: workspace))
        XCTAssertEqual(fromEdge.shapes[1].start.y, 0, accuracy: 1e-9)
    }

    func testJoinedLinesFollowARectangleDraggedInsideOut() throws {
        let box = rectangle(.zero, .init(x: 10, y: 10)), tail = line(.init(x: 10, y: 0), .init(x: 20, y: 0))
        let workspace = sketch([box, tail])
        let flipped = try XCTUnwrap(SketchEditing.dragging(box, handle: .corner(2), to: .init(x: -5, y: 10)))
        let result = try XCTUnwrap(SketchEditing.replacing(flipped, in: workspace))
        XCTAssertEqual(result.shapes[1].start, Point2(x: -5, y: 0), "The line stays on the corner that moved")
        XCTAssertEqual(result.shapes[1].end, Point2(x: 20, y: 0))
    }

    func testDimensionsWithinOneShapeResizeItOrAreNotOffered() throws {
        let box = rectangle(.zero, .init(x: 10, y: 10))
        let workspace = sketch([box])
        let corner = try XCTUnwrap(SketchReference.part(.corner(0), of: box)), center = try XCTUnwrap(SketchReference.part(.center, of: box))
        // From a corner to the center: the rectangle grows from that corner.
        let wider = try XCTUnwrap(SketchDimensions.applying(.horizontal, value: 8, corner, center, in: workspace))
        let resized = try XCTUnwrap(wider.shapes.first)
        XCTAssertEqual(resized.outline[0], .zero, "The picked corner stays")
        XCTAssertEqual(resized.center.x, 8, accuracy: 1e-9)
        XCTAssertEqual(SketchDimensions.dimensions(corner, try XCTUnwrap(center.resolved(in: wider)), in: wider).first?.value ?? 0, 8, accuracy: 1e-9)
        // From the center to a corner: moving the corner moves the center too, so the value cannot be set.
        let reversed = SketchDimensions.dimensions(center, corner, in: workspace)
        XCTAssertFalse(reversed.isEmpty)
        XCTAssertFalse(reversed.contains(where: \.editable))
        XCTAssertNil(SketchDimensions.applying(.horizontal, value: 8, center, corner, in: workspace), "No silent move of the whole rectangle")
    }

    func testDimensionsInsideAnOutlineReshapeIt() throws {
        let points = [Point2(x: 0, y: 0), .init(x: 30, y: 0), .init(x: 30, y: 20), .init(x: 0, y: 20)]
        let lines = points.indices.map { line(points[$0], points[($0 + 1) % 4]) }
        let workspace = sketch(lines)
        let bottom = try XCTUnwrap(SketchReference.part(.whole, of: lines[0])), top = try XCTUnwrap(SketchReference.part(.whole, of: lines[2]))
        XCTAssertEqual(SketchDimensions.dimensions(bottom, top, in: workspace).map(\.value), [20])
        let taller = try XCTUnwrap(SketchDimensions.applying(.distance, value: 25, bottom, top, in: workspace))
        XCTAssertEqual(Geometry.profiles(in: taller.shapes, on: .top).first?.area ?? 0, 750, accuracy: 1e-9, "The sides stretch")
        // The angle at a shared corner turns the second line about it.
        let left = try XCTUnwrap(SketchReference.part(.whole, of: lines[3]))
        let angle = try XCTUnwrap(SketchDimensions.dimensions(bottom, left, in: workspace).first)
        XCTAssertEqual(angle.kind, .angle)
        XCTAssertEqual(angle.value, 90, accuracy: 1e-9)
        let leaning = try XCTUnwrap(SketchDimensions.applying(.angle, value: 60, bottom, left, in: workspace))
        let turned = try XCTUnwrap(SketchReference.part(.whole, of: XCTUnwrap(leaning.shapes.first { $0.id == lines[3].id })))
        XCTAssertEqual(try XCTUnwrap(SketchDimensions.angle(bottom, turned)).value, 60, accuracy: 1e-9)
        XCTAssertEqual(leaning.shapes[0].start, .zero, "It turns about the shared corner")
        // One line: its length and its angle from the x axis.
        let single = SketchDimensions.dimensions(bottom, nil, in: workspace)
        XCTAssertEqual(single.map(\.kind), [.length, .angle])
        let tilted = try XCTUnwrap(SketchDimensions.applying(.angle, value: 30, bottom, nil, in: workspace))
        let tiltedLine = try XCTUnwrap(tilted.shapes.first { $0.id == lines[0].id })
        XCTAssertEqual(atan2(tiltedLine.end.y - tiltedLine.start.y, tiltedLine.end.x - tiltedLine.start.x) * 180 / .pi, 30, accuracy: 1e-9)
    }
}
