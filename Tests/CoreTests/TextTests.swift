import XCTest
import simd
@testable import SwipeAndSketchCore

/// Text embossed onto and debossed into flat faces.
final class TextTests: XCTestCase {
    let top = SketchPlane.through(.init(0, 0, 20), normal: .init(0, 0, 1))!

    func spec(_ text: String = "A8o", height: Double = 8, at center: Point2 = .zero, angle: Double = 0) throws -> TextSpec {
        try XCTUnwrap(TextSpec.make(text, font: TextFonts.defaultFont, height: height, center: center, angle: angle))
    }

    func testOutlinesKnowLettersFromTheirHoles() throws {
        let text = try spec()
        let glyphs = Dictionary(grouping: text.loops, by: \.glyph)
        XCTAssertEqual(glyphs.count, 3)
        // A has one hole, 8 two, o one.
        XCTAssertEqual(glyphs.keys.sorted().map { key in glyphs[key]!.filter { !$0.filled }.count }, [1, 2, 1])
        XCTAssertEqual(glyphs.keys.sorted().map { key in glyphs[key]!.filter(\.filled).count }, [1, 1, 1])
        XCTAssertTrue(text.isValid)
        // Capitals are the height asked for, centered on the point.
        let points = text.loops.filter { $0.glyph == 0 }.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
        XCTAssertEqual(points.map(\.y).max()! - points.map(\.y).min()!, 8, accuracy: 0.05)
        XCTAssertNil(TextSpec.make("   ", font: TextFonts.defaultFont, height: 8, center: .zero, angle: 0), "Nothing to draw")
        XCTAssertNil(TextSpec.make("A", font: "NoSuchFont-Bold", height: 8, center: .zero, angle: 0))
        XCTAssertFalse(TextFonts.available.isEmpty)
    }

    func testEmbossRaisesAndDebossSinksTheLetters() throws {
        let block = try box(depth: 20)
        var raised = block
        raised.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec(), on: top, depth: 1.5)))
        XCTAssertTrue(raised.isValid)
        let start = Date()
        let raisedSolid = try SolidKernel.solid(for: raised)
        print("[text timing] emboss 3 letters: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertTrue(raisedSolid.isValidSolid)
        XCTAssertEqual(raisedSolid.bounds.max.z, 21.5, accuracy: 1e-6)
        XCTAssertGreaterThan(raisedSolid.volume, 48_000 + 10)
        let added = raisedSolid.volume - 48_000

        var sunk = block
        sunk.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec(), on: top, depth: -1.5)))
        let sunkSolid = try SolidKernel.solid(for: sunk)
        XCTAssertTrue(sunkSolid.isValidSolid)
        XCTAssertEqual(sunkSolid.bounds.max.z, 20, accuracy: 1e-6)
        XCTAssertEqual(48_000 - sunkSolid.volume, added * 1.5 / 1.52, accuracy: added * 0.02, "The same letters, sunk instead of raised")
    }

    func testTextOffTheFaceIsRefusedAndTurningWorks() throws {
        var floating = try box(depth: 20)
        floating.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec(at: Point2(x: 200, y: 0)), on: top, depth: 1)))
        XCTAssertThrowsError(try SolidKernel.solid(for: floating))

        var turned = try box(depth: 20)
        turned.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec("HI", height: 10, angle: 90), on: top, depth: 1)))
        let bounds = try SolidKernel.solid(for: turned).bounds
        XCTAssertEqual(bounds.max.z, 21, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.x, 30, accuracy: 1e-6, "Still inside the block")
    }

    func testMirroredMovedAndSavedTextKeepsItsLetters() throws {
        var block = try box(depth: 20)
        block.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec("R"), on: top, depth: -1)))
        let volume = try SolidKernel.solid(for: block).volume
        let image = try XCTUnwrap(block.mirrored(by: try XCTUnwrap(Reflection(across: .right))))
        XCTAssertEqual(try SolidKernel.solid(for: image).volume, volume, accuracy: 1e-3)
        let moved = try XCTUnwrap(block.transformed(by: .rotate(degrees: 90, about: .init(0, 1, 0), through: .zero)))
        XCTAssertEqual(try SolidKernel.solid(for: moved).volume, volume, accuracy: 1e-3)
        let data = try ProjectCodec.encode(Project(workspace: Workspace(bodies: [block])))
        XCTAssertEqual(try ProjectCodec.decode(data).workspace.bodies, [block])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"font\" : \"Helvetica-Bold\""))
    }

    func testEveryOfferedFontBuildsRaisedAndSunkText() throws {
        for font in TextFonts.available {
            let text = try XCTUnwrap(TextSpec.make("Ag8&%R", font: font.name, height: 6, center: .zero, angle: 0), font.name)
            for depth in [1.0, -1.0] {
                var block = try box(depth: 20)
                block.cuts.append(try XCTUnwrap(ExtrusionCut.text(text, on: top, depth: depth)))
                let solid = try SolidKernel.solid(for: block)
                XCTAssertTrue(solid.isValidSolid, "\(font.name) \(depth)")
                XCTAssertEqual(solid.volume > 48_000, depth > 0, font.name)
            }
        }
        let long = try spec("Swipe & Sketch v1.2", height: 4)
        var label = try box(-60, -20, 60, 20, depth: 20)
        label.cuts.append(try XCTUnwrap(ExtrusionCut.text(long, on: top, depth: -0.6)))
        let start = Date()
        XCTAssertTrue(try SolidKernel.solid(for: label).isValidSolid)
        print("[text timing] 19-character label: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    func testAssistantAddsRaisedAndSunkText() throws {
        var bench = AssistantWorkbench(workspace: Workspace(bodies: [try box(depth: 20)]))
        let raised = try bench.text(body: "Body 01", face: "top", text: "V2", height: 6, depth: 1)
        XCTAssertTrue(raised.hasPrefix("Raised \"V2\" 1 mm"), raised)
        let sunk = try bench.text(body: "Body 01", face: "front", text: "OK", height: 5, depth: -0.6, font: "Courier Bold")
        XCTAssertTrue(sunk.hasPrefix("Sank \"OK\""), sunk)
        XCTAssertEqual(bench.workspace.bodies[0].cuts.last?.text?.font, "Courier-Bold")
        XCTAssertThrowsError(try bench.text(body: "Body 01", face: "top", text: "MUCH TOO LONG FOR THIS", height: 30, depth: 1))
        XCTAssertTrue(bench.summary().contains("debossed text \"OK\""), bench.summary())
    }

    func testLetteringAddsNoSnapDots() throws {
        let block = try box(depth: 20)
        let plain = SketchGuides.guides(on: top, bodies: [block])
        var lettered = block
        lettered.cuts.append(try XCTUnwrap(ExtrusionCut.text(try spec("PLA 0.2", height: 5), on: top, depth: -1)))
        XCTAssertEqual(SketchGuides.guides(on: top, bodies: [lettered]).count, plain.count)
    }
}
