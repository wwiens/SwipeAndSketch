import Foundation
import CoreGraphics
import CoreText
import SSKernel
import simd

// Text embossed onto (raised from) or debossed into (sunk into) a flat face: labels, version
// numbers, names. The glyph outlines are saved with the text, so it rebuilds exactly on any
// device, whatever fonts that device has; the string, font, and size are kept for editing. Saved
// as a `text` entry in a solid's ordered `cuts` list.

/// One stretch of a glyph outline after the point before it: a line (one point), a quadratic
/// curve (control point, end), or a cubic curve (two control points, end).
struct TextSegment: Codable, Equatable, Sendable {
    var points: [Point2]
}

/// A closed glyph outline, on the text entry's plane. A glyph's `filled` loops are its shapes;
/// its other loops are holes (the inside of an "o").
struct TextLoop: Codable, Equatable, Sendable {
    var glyph: Int
    var filled: Bool
    var start: Point2
    var segments: [TextSegment]
}

struct TextSpec: Codable, Equatable, Sendable {
    var text: String
    /// The font's PostScript name, such as "Helvetica-Bold".
    var font: String
    /// Capital-letter height in millimeters.
    var height: Double
    /// Where the text is centered on the plane, and its turn about the plane's normal (degrees).
    var center: Point2
    var angle: Double
    var loops: [TextLoop]

    static let heightRange = 0.5...500.0
    static let maximumLength = 200

    var isValid: Bool {
        let points = loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumLength &&
            Self.heightRange.contains(height) && center.isValid && angle.isFinite && !loops.isEmpty && loops.contains(where: \.filled) &&
            loops.allSatisfy { !$0.segments.isEmpty && $0.segments.allSatisfy { (1...3).contains($0.points.count) } } &&
            points.count <= 200_000 && points.allSatisfy { $0.isValid && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }
    }
}

/// Fonts that print well and that every iPad has. Outlines are saved, so a font missing later only
/// matters when the text is edited.
enum TextFonts {
    static let choices: [(name: String, title: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"), ("AvenirNext-Bold", "Avenir Next Bold"), ("ArialRoundedMTBold", "Arial Rounded"),
        ("Futura-Bold", "Futura Bold"), ("GillSans-Bold", "Gill Sans Bold"), ("Courier-Bold", "Courier Bold"),
        ("Menlo-Bold", "Menlo Bold"), ("Georgia-Bold", "Georgia Bold"), ("AmericanTypewriter-Bold", "American Typewriter"),
        ("MarkerFelt-Wide", "Marker Felt")]
    static let defaultFont = "Helvetica-Bold"

    /// The fonts this device has (a missing font would silently fall back to another).
    static var available: [(name: String, title: String)] {
        choices.filter { CTFontCopyPostScriptName(CTFontCreateWithName($0.name as CFString, 12, nil)) as String == $0.name }
    }
    static func title(for name: String) -> String { choices.first { $0.name == name }?.title ?? name }

    /// The outlines of `text` in `font`, capitals `height` tall, centered on `center` and turned
    /// `angle` degrees. Nil when the text has no visible glyphs or the font is missing.
    static func outlines(_ text: String, font name: String, height: Double, center: Point2, angle: Double) -> [TextLoop]? {
        let font = CTFontCreateWithName(name as CFString, 100, nil)
        guard CTFontCopyPostScriptName(font) as String == name else { return nil }
        let capHeight = CTFontGetCapHeight(font)
        guard capHeight > 0, height > 0 else { return nil }
        let scale = height / Double(capHeight)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let turn = angle * .pi / 180, c = cos(turn), s = sin(turn)
        // Centered across the line's width and on the capitals' height.
        func place(_ p: CGPoint) -> Point2 {
            let x = (Double(p.x) - width / 2) * scale, y = (Double(p.y) - Double(capHeight) / 2) * scale
            return Point2(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
        }
        var loops: [TextLoop] = [], glyphIndex = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attributes[kCTFontAttributeName as String] as! CTFont?) ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let origin = positions[index]
                var glyphLoops: [TextLoop] = [], current: TextLoop?, last = CGPoint.zero
                func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
                func finish() {
                    if let loop = current, !loop.segments.isEmpty { glyphLoops.append(loop) }
                    current = nil
                }
                path.applyWithBlock { element in
                    let e = element.pointee
                    switch e.type {
                    case .moveToPoint:
                        finish()
                        last = shifted(e.points[0])
                        current = TextLoop(glyph: glyphIndex, filled: true, start: place(last), segments: [])
                    case .addLineToPoint:
                        last = shifted(e.points[0])
                        current?.segments.append(TextSegment(points: [place(last)]))
                    case .addQuadCurveToPoint:
                        last = shifted(e.points[1])
                        current?.segments.append(TextSegment(points: [place(shifted(e.points[0])), place(last)]))
                    case .addCurveToPoint:
                        last = shifted(e.points[2])
                        current?.segments.append(TextSegment(points: [place(shifted(e.points[0])), place(shifted(e.points[1])), place(last)]))
                    case .closeSubpath:
                        finish()
                    @unknown default:
                        break
                    }
                }
                finish()
                guard !glyphLoops.isEmpty else { continue }
                // The font's outer contours all turn one way and its holes the other; the largest loop is outer.
                let areas = glyphLoops.map(signedArea)
                let outer = areas.max { abs($0) < abs($1) }!.sign
                for (i, area) in areas.enumerated() { glyphLoops[i].filled = area.sign == outer }
                loops += glyphLoops
                glyphIndex += 1
            }
        }
        return loops.isEmpty ? nil : loops
    }

    /// The area a loop's control polygon encloses (positive counterclockwise), to tell outer loops from holes.
    static func signedArea(_ loop: TextLoop) -> Double {
        let points = [loop.start] + loop.segments.flatMap(\.points)
        return Geometry.signedArea(points)
    }
}

extension TextSpec {
    /// A spec with outlines for these settings, or nil when the font cannot draw them.
    static func make(_ text: String, font: String, height: Double, center: Point2, angle: Double) -> TextSpec? {
        guard let loops = TextFonts.outlines(text, font: font, height: height, center: center, angle: angle) else { return nil }
        return TextSpec(text: text, font: font, height: height, center: center, angle: angle, loops: loops)
    }

    /// The text on the mirror image of its solid's plane: the plane's y axis flips.
    var mirrored: TextSpec {
        var image = self
        image.center = Reflection.flip(center)
        image.angle = -angle
        image.loops = loops.map { loop in
            var flipped = loop
            flipped.start = Reflection.flip(loop.start)
            flipped.segments = loop.segments.map { TextSegment(points: $0.points.map(Reflection.flip)) }
            return flipped
        }
        return image
    }
}

extension ExtrusionCut {
    /// Text on `plane`, raised `depth` mm along its normal (embossed), or sunk `-depth` mm into the
    /// solid (debossed). The profile is a placeholder circle that carries the plane.
    static func text(_ spec: TextSpec, on plane: SketchPlane, depth: Double) -> ExtrusionCut? {
        let circle = SketchShape(kind: .circle, plane: plane, start: spec.center, end: spec.center + Point2(x: max(spec.height, 1) / 2, y: 0))
        guard let profile = Geometry.profiles(in: [circle], on: plane).first else { return nil }
        var operation = ExtrusionCut(profile: profile, depth: depth)
        operation.text = spec
        return operation
    }
}

extension SolidKernel {
    /// The letters as solids on the cut's plane: embossed ones reach a hair into the face so they
    /// join it; debossed ones start above it so the cut never shares a face with the solid.
    static func textTool(for operation: ExtrusionCut) throws -> KernelSolid {
        guard let spec = operation.text else { throw Failure(message: "Missing text") }
        var xy: [Double] = [], degrees: [Int32] = [], counts: [Int32] = [], groups: [Int32] = [], filled: [Bool] = []
        for loop in spec.loops {
            xy += [loop.start.x, loop.start.y]
            for segment in loop.segments {
                degrees.append(Int32(segment.points.count))
                for p in segment.points { xy += [p.x, p.y] }
            }
            counts.append(Int32(loop.segments.count))
            groups.append(Int32(loop.glyph))
            filled.append(loop.filled)
        }
        let emboss = operation.depth > 0
        let offset = emboss ? -0.02 : 0.5, depth = emboss ? operation.depth + 0.02 : operation.depth - 0.5
        guard let tool = ssk_extrude_outlines(operation.profile.plane.kernelPlane, xy, degrees, counts, groups, filled, Int32(spec.loops.count), offset, depth) else {
            throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Text failed")
        }
        return KernelSolid(adopting: tool)
    }

    static func applyText(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        do {
            return try applyLetters(operation, to: solid)
        } catch {
            // Letters a font kerns into each other (Georgia's "Al") are separate solids that
            // overlap, which one boolean can't take: apply them a letter at a time instead.
            guard let spec = operation.text else { throw error }
            let glyphs = Array(Set(spec.loops.map(\.glyph))).sorted()
            guard glyphs.count > 1 else { throw error }
            var result = solid
            for glyph in glyphs {
                var letter = operation
                letter.text?.loops = spec.loops.filter { $0.glyph == glyph }
                result = try applyLetters(letter, to: result)
            }
            return result
        }
    }

    private static func applyLetters(_ operation: ExtrusionCut, to solid: KernelSolid) throws -> KernelSolid {
        let tool = try textTool(for: operation)
        if operation.depth > 0 {
            let result = try boolean(solid, tool, .union)
            guard result.isValidSolid else { throw Failure(message: "Some letters are off the face; move the text onto it") }
            return result
        }
        let result = try boolean(solid, tool, .subtract)
        guard result.volume < solid.volume - 1e-9 else { throw Failure(message: "The text is not on this solid") }
        guard result.isValidSolid else { throw Failure(message: "The text cuts this solid apart; make it shallower") }
        return result
    }
}
