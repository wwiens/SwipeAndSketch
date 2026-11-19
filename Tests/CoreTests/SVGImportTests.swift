import XCTest
import CoreGraphics
@testable import SwipeAndSketchCore

/// SVG import: the hand-written drawings in Tests/Fixtures/SVG, each made to exercise one thing.
final class SVGImportTests: XCTestCase {
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SVG/\(name)")
    }

    func drawing(_ name: String) throws -> SVGImport.Drawing {
        try SVGImport.read(fixture(name.contains(".") ? name : name + ".svg"), name: name)
    }

    let top = Placement.top

    func layout(_ name: String, _ change: (inout SVGImport.Options) -> Void = { _ in }) throws -> SVGImport.Layout {
        let drawing = try drawing(name)
        var options = SVGImport.defaultOptions(for: drawing)
        change(&options)
        return try SVGImport.layout(drawing, options: options, placement: top)
    }

    func profiles(_ layout: SVGImport.Layout, sketch: Int = 0) -> [SketchProfile] {
        Geometry.profiles(in: layout.sketches[sketch].shapes, on: SketchPlane.top)
    }

    // MARK: Size and units

    func testRealUnitsGiveTheDrawingItsSize() throws {
        let drawing = try drawing("units")
        XCTAssertTrue(drawing.hasPhysicalSize)
        XCTAssertEqual(drawing.bounds.width, 100, accuracy: 1e-6)
        XCTAssertEqual(drawing.bounds.height, 50, accuracy: 1e-6)
        let placed = try layout("units")
        XCTAssertEqual(placed.sketches.count, 1)
        XCTAssertEqual(placed.sketches[0].shapes.map(\.kind), [.line, .line, .line, .line])
        let regions = profiles(placed)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].area, 5_000, accuracy: 1e-6)
        // Centered on the placement's center.
        let xs = regions[0].outline.map(\.x), ys = regions[0].outline.map(\.y)
        XCTAssertEqual(xs.min()!, -50, accuracy: 1e-9)
        XCTAssertEqual(ys.max()!, 25, accuracy: 1e-9)
    }

    func testPixelsAreNinetySixToTheInchAndCirclesComeBackAsCircles() throws {
        let drawing = try drawing("pixels")
        XCTAssertFalse(drawing.hasPhysicalSize)
        XCTAssertEqual(drawing.bounds.width, 25.4, accuracy: 1e-6)
        let placed = try layout("pixels")
        XCTAssertEqual(placed.sketches[0].shapes.count, 1)
        let circle = placed.sketches[0].shapes[0]
        XCTAssertEqual(circle.kind, .circle)
        XCTAssertEqual(circle.start.distance(to: circle.end), 12.7, accuracy: 0.02)
        XCTAssertEqual(circle.start.distance(to: .zero), 0, accuracy: 0.02)
    }

    func testLargeCirclesComeBackAsCirclesToo() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='700mm' height='700mm' viewBox='0 0 700 700'><circle cx='350' cy='350' r='300'/></svg>"
        let drawing = try SVGImport.read(data: Data(svg.utf8), name: "big")
        let placed = try SVGImport.layout(drawing, options: SVGImport.defaultOptions(for: drawing), placement: top)
        XCTAssertEqual(placed.sketches[0].shapes.map(\.kind), [.circle])
        XCTAssertEqual(placed.sketches[0].shapes[0].start.distance(to: placed.sketches[0].shapes[0].end), 300, accuracy: 0.1)
    }

    func testAChosenWidthScalesEverythingAndTheFilePositionCanBeKept() throws {
        let wide = try layout("units") { $0.width = 40 }
        XCTAssertEqual(wide.size.width, 40, accuracy: 1e-9)
        XCTAssertEqual(wide.size.height, 20, accuracy: 1e-9)
        XCTAssertEqual(profiles(wide)[0].area, 800, accuracy: 1e-6)
        let kept = try layout("units") { $0.keepFilePosition = true }
        let ys = profiles(kept)[0].outline.map(\.y), xs = profiles(kept)[0].outline.map(\.x)
        // The file's origin (top left, Y down) lands on the center: the drawing runs right and down.
        XCTAssertEqual(xs.min()!, 0, accuracy: 1e-9)
        XCTAssertEqual(ys.max()!, 0, accuracy: 1e-9)
        XCTAssertEqual(ys.min()!, -50, accuracy: 1e-9)
    }

    func testNestedTransformsApply() throws {
        let placed = try layout("transforms")
        let region = try XCTUnwrap(profiles(placed).first)
        // A 20 mm square stretched to 40 × 20 and turned 45°: area 800, corners on the diagonals.
        XCTAssertEqual(region.area, 800, accuracy: 1e-6)
        XCTAssertEqual(placed.sketches[0].shapes.count, 4)
    }

    // MARK: Curves

    func testArcsAndRoundedCornersStayArcs() throws {
        let placed = try layout("arcs")
        let shapes = placed.sketches[0].shapes
        XCTAssertEqual(shapes.filter { $0.kind == .circle }.count, 1, "The two half-turn arcs make one circle")
        XCTAssertEqual(shapes.filter { $0.kind == .arc }.count, 4, "The rounded rectangle's corners")
        XCTAssertEqual(shapes.filter { $0.kind == .line }.count, 4)
        for corner in shapes where corner.kind == .arc {
            XCTAssertEqual(corner.start.distance(to: corner.arcCenter!), 8, accuracy: 0.02)
        }
        let regions = profiles(placed)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions.map(\.area).sorted()[0], .pi * 225, accuracy: 1)
        XCTAssertEqual(regions.map(\.area).sorted()[1], 45 * 40 - (4 - .pi) * 64, accuracy: 1)
    }

    func testCurvesFitWithinTheTolerance() {
        // A quarter of a 50 mm circle as one cubic curve.
        let k = 0.5522847498 * 50
        let p0 = Point2(x: 50, y: 0), p1 = Point2(x: 50, y: k), p2 = Point2(x: k, y: 50), p3 = Point2(x: 0, y: 50)
        let pieces = CurveFitting.fitCubic(p0, p1, p2, p3, tolerance: 0.01)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertFalse(pieces.isEmpty)
        for t in stride(from: 0.0, through: 1, by: 0.01) {
            let u = 1 - t
            let point = p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
            XCTAssertLessThanOrEqual(pieces.map { $0.distance(to: point) }.min()!, 0.011)
        }
        // Joined, it is one or two arcs about (nearly) the circle's center.
        let merged = CurveFitting.merged(pieces, closed: false, tolerance: 0.01)
        XCTAssertLessThanOrEqual(merged.count, 2)
        for piece in merged { XCTAssertEqual(piece.center!.distance(to: .zero), 0, accuracy: 0.2) }
        // An S curve turns both ways and still fits, end to end.
        let s = CurveFitting.fitCubic(.zero, Point2(x: 30, y: 40), Point2(x: 70, y: -40), Point2(x: 100, y: 0), tolerance: 0.01)
        XCTAssertGreaterThanOrEqual(s.count, 2)
        for (a, b) in zip(s, s.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertTrue(s.contains { $0.ccw } && s.contains { !$0.ccw })
    }

    // MARK: Fill rules, overlaps, clips, hidden things

    func testFillRulesDecideHoles() throws {
        let evenOdd = profiles(try layout("donut-evenodd"))
        // The ring (with the hole) and the hole's own disk.
        XCTAssertEqual(evenOdd.count, 2)
        XCTAssertEqual(evenOdd.first { ($0.holes ?? []).count == 1 }?.area ?? 0, .pi * (1_600 - 400), accuracy: 5)
        let solid = try layout("donut-evenodd") { $0.solidHeight = 3 }
        XCTAssertEqual(solid.solids.count, 1, "Only the ring is filled")
        XCTAssertEqual(solid.solids[0].profile.holes?.count, 1)

        let nonzero = profiles(try layout("donut-nonzero"))
        XCTAssertEqual(nonzero.count, 1, "Both loops turn the same way: the middle is filled, no hole")
        XCTAssertEqual(nonzero[0].area, .pi * 1_600, accuracy: 5)
    }

    func testOverlappingShapesOfOneColorJoin() throws {
        let regions = profiles(try layout("overlap"))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].area, 2 * 60 * 40 - 20 * 20, accuracy: 1e-3)
    }

    func testClipPathsCut() throws {
        let regions = profiles(try layout("clip"))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].area, .pi * 1_600 / 2, accuracy: 3)
    }

    func testHiddenThingsAreLeftOut() throws {
        let placed = try layout("hidden")
        XCTAssertEqual(profiles(placed).count, 1, "Only the first square is visible")
        XCTAssertEqual(profiles(placed)[0].area, 400, accuracy: 1e-6)
    }

    // MARK: Strokes

    func testStrokesBecomeOutlinesOrCenterLines() throws {
        let auto = try layout("strokes")
        let regions = profiles(auto)
        // The wide polyline's outline and the hairline rectangle (its center line) are regions;
        // the dashed line is eight dashes, each an outline.
        XCTAssertTrue(regions.contains { abs($0.area - 60 * 20) < 1 }, "The hairline rectangle is a closed center line")
        XCTAssertEqual(regions.filter { abs($0.area - 20) < 0.5 }.count, 5, "Five whole 10 × 2 dashes, and a half one")
        XCTAssertEqual(regions.filter { abs($0.area - 10) < 0.5 }.count, 1)
        XCTAssertTrue(regions.contains { $0.area > 200 && $0.area < 600 }, "The round-capped polyline's outline")
        XCTAssertEqual(auto.openPaths, 0)

        let lines = try layout("strokes") { $0.strokes = .centerline }
        XCTAssertGreaterThan(lines.openPaths, 0, "The polyline and dashes are open lines")
        XCTAssertEqual(profiles(lines).count, 1, "Only the rectangle closes")

        let outlines = try layout("strokes") { $0.strokes = .outline }
        // The hairline's outline is a thin frame: a ring region around the hole inside it.
        XCTAssertTrue(profiles(outlines).contains { ($0.holes ?? []).count == 1 && $0.area < 10 })
    }

    // MARK: Text

    func testTextBecomesLetterOutlinesInFontsThisDeviceHas() throws {
        let drawing = try drawing("text")
        XCTAssertTrue(drawing.hasText)
        XCTAssertTrue(drawing.warnings.messages.contains { $0.contains("Imaginary Sans Pro") }, "\(drawing.warnings.messages)")
        let placed = try layout("text") { $0.grouping = .single }
        let regions = profiles(placed)
        // "H", "i" (stem and dot), "o" (ring and its counter), "k".
        XCTAssertGreaterThanOrEqual(regions.count, 6)
        // The anchored "ok" ends near x = 190 of 200 (95 mm right of the left edge of 200 mm).
        let right = placed.sketches[0].shapes.flatMap(\.outline).map(\.x).max()!
        XCTAssertEqual(right, placed.size.width / 2, accuracy: 0.5)
        let colors = try layout("text") { $0.grouping = .colors }
        XCTAssertEqual(colors.sketches.map(\.name), ["Black", "Red"])
    }

    // MARK: Colors, layers, and solids

    func testStyleSheetsColorShapes() throws {
        let drawing = try drawing("css")
        XCTAssertEqual(drawing.colors.map(\.hex), ["#E53935", "#1E88E5"])
        let placed = try layout("css")
        XCTAssertEqual(placed.sketches.map(\.name), ["Red", "Blue"])
        XCTAssertEqual(profiles(placed, sketch: 0).count, 1)
        XCTAssertEqual(profiles(placed, sketch: 1).count, 2, "The inline style wins over the sheet")
    }

    func testColorsCoverWhatTheyArePaintedOverAndMakeColoredSolids() throws {
        let placed = try layout("sign") { $0.solidHeight = 2 }
        XCTAssertTrue(placed.warnings.messages.contains("The white background was left out"))
        XCTAssertEqual(placed.sketches.map(\.name), ["Black", "Red", "White"])
        // Black is the plate less the red shapes; red's circle has the white dot taken out.
        let black = profiles(placed, sketch: 0)
        XCTAssertEqual(black.count, 3, "The plate, and the places the red shapes take")
        XCTAssertEqual(black.last?.holes?.count, 2)
        let red = placed.solids.filter { $0.color == .red }
        XCTAssertEqual(red.count, 2)
        XCTAssertTrue(red.contains { $0.profile.holes?.count == 1 }, "The red circle around the white dot")
        XCTAssertEqual(placed.solids.filter { $0.color == .black }.count, 1)
        XCTAssertFalse(placed.solids.contains { $0.color == .white }, "White makes no solids")

        let added = try XCTUnwrap(SVGImport.adding(placed, name: "sign", to: Workspace()))
        let workspace = added.workspace
        XCTAssertTrue(workspace.isValid)
        XCTAssertEqual(workspace.groupNames[added.group], "sign")
        XCTAssertEqual(workspace.bodies.count, 3)
        XCTAssertTrue(workspace.bodies.allSatisfy { $0.depth == 2 })
        XCTAssertTrue(workspace.sketches.allSatisfy(\.isHidden), "With solids, the sketches are hidden")
        XCTAssertEqual(workspace.groups.count, 2, "The two red solids share a group")
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(Project(workspace: workspace))).workspace, workspace)
        // The solids build.
        for body in workspace.bodies { XCTAssertGreaterThan(try SolidKernel.solid(for: body).volume, 0) }
    }

    func testLayersBecomeSketches() throws {
        let placed = try layout("layers") { $0.grouping = .layers }
        XCTAssertEqual(placed.sketches.map(\.name), ["Base", "Top"])
        let added = try XCTUnwrap(SVGImport.adding(placed, name: "layers", to: Workspace()))
        XCTAssertEqual(added.workspace.sketches.map(\.name), ["Base", "Top"])
        XCTAssertEqual(added.workspace.members(of: added.group).count, 2)
    }

    func testAFaceGetsTheDrawingOnItsPlane() throws {
        let face = SketchPlane(origin: [0, 0, 10], xAxis: [1, 0, 0], yAxis: [0, 1, 0])
        let drawing = try drawing("pixels")
        let placed = try SVGImport.layout(drawing, options: SVGImport.defaultOptions(for: drawing),
                                          placement: SVGImport.Placement(plane: face, center: Point2(x: 5, y: -3)))
        let circle = placed.sketches[0].shapes[0]
        XCTAssertEqual(circle.plane, face)
        XCTAssertEqual(circle.start.distance(to: Point2(x: 5, y: -3)), 0, accuracy: 0.02)
    }

    // MARK: Pictures

    func testPicturesInsideTheFileAreTraced() throws {
        let placed = try layout("image")
        let regions = profiles(placed)
        // The black square frame (32 mm with a 12 mm hole) and the hole's own region.
        let frame = try XCTUnwrap(regions.first { ($0.holes ?? []).count == 1 })
        XCTAssertEqual(frame.area, 32 * 32 - 12 * 12, accuracy: 40)
        let off = try layout("image") { $0.traceImages = false }
        XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(off.warnings.messages.contains("Pictures were left out (tracing is off)"))
    }

    // MARK: Files that are not what they seem

    func testCompressedFilesRead() throws {
        let drawing = try drawing("units.svgz")
        XCTAssertEqual(drawing.bounds.width, 100, accuracy: 1e-6)
    }

    func testReferencesThatLoopStop() throws {
        let drawing = try drawing("use-loop")
        XCTAssertTrue(drawing.warnings.messages.contains { $0.hasPrefix("A reference that leads back to itself") })
        let placed = try layout("use-loop") { $0.grouping = .single }
        XCTAssertTrue(profiles(placed).contains { abs($0.area - .pi * 100) < 1 }, "The symbol, sized by the use")
    }

    func testHostileFilesAreRefused() throws {
        // Entities that expand a billion times over must not: either refused or read small.
        let start = Date()
        _ = try? drawing("entities")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // Nesting deeper than an import takes.
        let deep = String(repeating: "<g>", count: 600) + "<rect width='1' height='1'/>" + String(repeating: "</g>", count: 600)
        XCTAssertThrowsError(try SVGImport.read(data: Data("<svg xmlns='http://www.w3.org/2000/svg'>\(deep)</svg>".utf8), name: "deep"))
        // Not SVG, and SVG with nothing to draw.
        XCTAssertThrowsError(try SVGImport.read(data: Data("<html><body/></html>".utf8), name: "page"))
        XCTAssertThrowsError(try SVGImport.read(data: Data("not xml at all".utf8), name: "text"))
        XCTAssertThrowsError(try drawing("empty"))
        // Nothing outside the file is fetched: a linked picture is only a warning.
        let linked = try SVGImport.read(data: Data("""
            <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='5' height='5'/>
            <image href='https://example.com/a.png' width='10' height='10'/></svg>
            """.utf8), name: "linked")
        XCTAssertTrue(linked.warnings.messages.contains { $0.hasPrefix("Pictures linked from other files") })
    }

    // MARK: Values

    func testValues() {
        XCTAssertEqual(SVGValues.numbers("10-5.5.5e1,3"), [10, -5.5, 5, 3])
        XCTAssertEqual(SVGValues.color("#f00")?.color.hex, "#FF0000")
        XCTAssertEqual(SVGValues.color("rgb(0, 128, 255)")?.color.hex, "#0080FF")
        XCTAssertEqual(SVGValues.color("hsl(120, 100%, 50%)")?.color.hex, "#00FF00")
        XCTAssertEqual(SVGValues.color("rebeccapurple")?.color.hex, "#663399")
        XCTAssertEqual(SVGValues.color("#11223380")?.alpha ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(SVGValues.userLength("1in"), 96)
        XCTAssertEqual(SVGValues.userLength("50%", reference: 30), 15)
        let t = SVGValues.transform("translate(10 0) scale(2)")!
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(t), CGPoint(x: 12, y: 2))
        let path = SVGPathData.path("M0 0h10v10H0z m20 0 l5 5 5-5")
        XCTAssertEqual(CurveFitting.subpaths(of: path).count, 2)
    }

    // MARK: Speed

    func testADetailedDrawingImportsQuickly() throws {
        // A toothed outline of 600 sharp curves (each fits to about six arcs).
        var d = "M100 0"
        for i in 1...600 {
            let a = Double(i) / 600 * 2 * .pi, b = (Double(i) - 0.5) / 600 * 2 * .pi
            let r = i % 2 == 0 ? 100.0 : 98
            d += String(format: " Q%.4f %.4f %.4f %.4f", 101 * cos(b), 101 * sin(b), r * cos(a), r * sin(a))
        }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='220mm' height='220mm' viewBox='-110 -110 220 220'><path d='\(d)Z'/></svg>"
        let start = Date()
        let drawing = try SVGImport.read(data: Data(svg.utf8), name: "gear")
        let placed = try SVGImport.layout(drawing, options: SVGImport.defaultOptions(for: drawing), placement: top)
        let regions = Geometry.profiles(in: placed.sketches[0].shapes, on: .top)
        XCTAssertEqual(regions.count, 1)
        XCTAssertGreaterThan(placed.shapeCount, 2_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertLessThanOrEqual(placed.shapeCount, SVGImport.maximumShapes)
    }
}

private enum Placement {
    static let top = SVGImport.Placement(plane: .top)
}
