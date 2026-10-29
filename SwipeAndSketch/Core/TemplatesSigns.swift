import CoreText
import Foundation
import simd

/// Signs & Labels (October 28, 2026, second expansion): nameplates, signs, tags, and markers with
/// the user's own words on them, raised from or sunk into the face. The letters are ordinary text
/// features (Text.swift), so they stay editable once made.
enum SignTemplates {
    static var templates: [ProjectTemplate] { [nameplate, mountingSign, keyTag, plantMarker] }

    // MARK: Lettering shared by every sign

    /// The font, size, and relief controls every sign has, after its own sizes.
    static func letteringParameters(height: Double, heights: ClosedRange<Double>, margin: Double, margins: ClosedRange<Double>) -> [TemplateParameter] {
        [TemplateParameter(id: "letterHeight", title: "Letter height", kind: .length(heights, step: 0.5), defaultValue: height,
                           note: "Capital letters' height"),
         TemplateParameter(id: "margin", title: "Text margin", kind: .length(margins, step: 0.5), defaultValue: margin,
                           note: "Room kept clear round the text"),
         TemplateParameter(id: "font", title: "Font", kind: .choice(TextFonts.choices.map(\.title)),
                           defaultValue: Double(TextFonts.choices.firstIndex { $0.name == TextFonts.defaultFont } ?? 0)),
         TemplateParameter(id: "relief", title: "Letters", kind: .choice(["Raised", "Recessed"]), defaultValue: 0),
         TemplateParameter(id: "reliefDepth", title: "Relief depth", kind: .length(0.3...1.2, step: 0.1), defaultValue: 0.6,
                           note: "How far the letters stand up or sink in")]
    }

    /// The text and how it is cut, as set up.
    struct Lettering {
        var text: String
        var font: String
        var height: Double
        var margin: Double
        var recessed: Bool
        var depth: Double
        init(_ values: TemplateValues) {
            text = values.text("text")
            let fonts = TextFonts.choices
            font = fonts[min(max(values.choice("font"), 0), fonts.count - 1)].name
            height = values["letterHeight"]; margin = values["margin"]
            recessed = values.choice("relief") == 1; depth = values["reliefDepth"]
        }

        /// The letters' outlines at the origin, and the box round every glyph (accents and descenders too).
        func spec() throws -> (spec: TextSpec, low: Point2, high: Point2) {
            let missing = Self.unsupported(text, font: font)
            guard missing.isEmpty else {
                throw TemplateError.tooSmall("\(TextFonts.title(for: font)) can't draw \(missing.map { "“\($0)”" }.joined(separator: ", ")). Use other characters or another font.")
            }
            guard let spec = TextSpec.make(text, font: font, height: height, center: .zero, angle: 0) else {
                throw TemplateError.tooSmall("The text has nothing to draw. Type some letters or numbers.")
            }
            let points = spec.loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
            let low = Point2(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0)
            let high = Point2(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0)
            return (spec, low, high)
        }

        /// The characters `font` has no glyph for (spaces aside), which would otherwise come from
        /// another font or not at all.
        static func unsupported(_ text: String, font name: String) -> [String] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { return [text] }
            var missing: [String] = []
            for character in text where !character.isWhitespace {
                let units = Array(String(character).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                if !CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) || glyphs.contains(0) {
                    if !missing.contains(String(character)) { missing.append(String(character)) }
                }
            }
            return missing
        }

        /// The letters centered on `center` (in `plane`'s coordinates) within `room` (width, height),
        /// raised or sunk into the face on `plane`; the face's solid must be at least `thickness` deep there.
        func cut(on plane: SketchPlane, center: Point2, room: (width: Double, height: Double), thickness: Double) throws -> ExtrusionCut {
            if recessed {
                guard thickness - depth >= 1.2 - 1e-9 else {
                    throw TemplateError.tooSmall("Recessed letters would leave less than 1.2 mm behind them. Make the part thicker or the relief shallower.")
                }
            }
            let (spec, low, high) = try spec()
            let size = high - low
            guard size.x <= room.width + 1e-9 else {
                throw TemplateError.tooSmall("The text is \(TemplateFormat.number(size.x, digits: 1)) mm wide and there is room for \(TemplateFormat.number(max(0, room.width), digits: 1)) mm. Make the part wider, the letters smaller, or the text shorter.")
            }
            guard size.y <= room.height + 1e-9 else {
                throw TemplateError.tooSmall("The text is \(TemplateFormat.number(size.y, digits: 1)) mm tall and there is room for \(TemplateFormat.number(max(0, room.height), digits: 1)) mm. Make the part taller or the letters smaller.")
            }
            // Centered on its glyphs' actual box, not the font's line.
            let shift = center - (low + high) * 0.5
            guard let placed = TextSpec.make(text, font: font, height: height, center: spec.center + shift, angle: 0),
                  let operation = ExtrusionCut.text(placed, on: plane, depth: recessed ? -depth : depth) else {
                throw TemplateError.failed("text")
            }
            return operation
        }

        func measurements(room: (width: Double, height: Double)) -> [TemplateMeasurement] {
            guard let (_, low, high) = try? spec() else { return [] }
            return [TemplateMeasurement(title: "Text", lengths: [high.x - low.x, high.y - low.y],
                                        text: "\(recessed ? "recessed" : "raised") \(TemplateFormat.number(depth)) mm"),
                    TemplateMeasurement(title: "Room for text", lengths: [max(0, room.width), max(0, room.height)])]
        }
    }

    static func textParameter(_ text: String, maxLength: Int) -> TemplateTextParameter {
        TemplateTextParameter(id: "text", title: "Text", defaultText: text, maxLength: maxLength)
    }

    /// Whether a rounded rectangle's corner `radius` fits it, as typed (it is never quietly shrunk).
    static func checkCorner(_ radius: Double, width: Double, height: Double) throws {
        guard radius <= min(width, height) / 2 - 0.01 + 1e-9 else {
            throw TemplateError.tooSmall("A \(TemplateFormat.number(radius)) mm corner radius doesn't fit a part \(TemplateFormat.number(min(width, height))) mm across. Make it \(TemplateFormat.number(min(width, height) / 2 - 0.1, digits: 1)) mm or less.")
        }
    }

    // MARK: Desk nameplate

    static var nameplate: ProjectTemplate {
        ProjectTemplate(
            id: "signs.nameplate", category: .signs, title: "Desk Nameplate",
            summary: "Make a nameplate with your text on a sloping face.",
            parameters: [
                TemplateParameter(id: "width", title: "Width", kind: .length(60...240, step: 1), defaultValue: 160),
                TemplateParameter(id: "faceHeight", title: "Face height", kind: .length(20...60, step: 1), defaultValue: 35, note: "Measured up the slope"),
                TemplateParameter(id: "angle", title: "Face angle (degrees)", kind: .length(45...80, step: 1), defaultValue: 60, note: "From the desk, in degrees"),
                TemplateParameter(id: "baseDepth", title: "Base depth", kind: .length(20...80, step: 1), defaultValue: 40),
                TemplateParameter(id: "base", title: "Base thickness", kind: .length(2...6, step: 0.5), defaultValue: 3)
            ] + letteringParameters(height: 12, heights: 4...25, margin: 4, margins: 2...10),
            name: { values in "Nameplate \(values.text("text"))" },
            make: { values in [TemplatePart(name: "Nameplate", body: try Nameplate(values).body())] },
            notes: { values in Nameplate(values).notes },
            textParameters: [textParameter("Alex", maxLength: 30)])
    }

    struct Nameplate {
        var lettering: Lettering
        var width, faceHeight, angle, baseDepth, base: Double
        init(_ values: TemplateValues) {
            lettering = Lettering(values)
            width = values["width"]; faceHeight = values["faceHeight"]; angle = values["angle"] * .pi / 180
            baseDepth = values["baseDepth"]; base = values["base"]
        }
        /// How far the face reaches back, and how high it rises.
        var run: Double { faceHeight * cos(angle) }
        var rise: Double { faceHeight * sin(angle) }
        var room: (width: Double, height: Double) { (width - 2 * lettering.margin, faceHeight - 2 * lettering.margin) }

        func body() throws -> SolidBody {
            guard baseDepth >= run + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The face reaches \(TemplateFormat.number(run, digits: 1)) mm back; make the base \(TemplateFormat.number((run + 2).rounded(.up))) mm deep or more, or the face steeper or shorter.")
            }
            // The side profile (y back, z up), extruded across the width: a base with a wedge on its front.
            let x0 = -width / 2
            let plane = SketchPlane.through(SIMD3(x0, 0, 0), normal: SIMD3(1, 0, 0)) ?? .right
            let profile = TemplateGeometry.polygon([SIMD3(x0, 0, 0), SIMD3(x0, baseDepth, 0), SIMD3(x0, baseDepth, base), SIMD3(x0, run, base),
                                                    SIMD3(x0, run, base + rise), SIMD3(x0, 0, base)], on: plane)
            var plate = TemplateGeometry.block(profile, height: width)
            // The face's own plane: x across, up the slope, facing front and up.
            let middle = SIMD3(0, run / 2, base + rise / 2)
            let face = SketchPlane.through(middle, normal: SIMD3(0, -sin(angle), cos(angle))) ?? .front
            // The solid behind the face is at least as deep as the base is thick.
            plate.cuts.append(try lettering.cut(on: face, center: face.coordinates(of: middle), room: room, thickness: base + 1))
            return plate
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Nameplate", lengths: [width, baseDepth, base + rise]),
                TemplateMeasurement(title: "Face", lengths: [faceHeight], text: "up the slope, \(TemplateFormat.number(angle * 180 / .pi))° from the desk")
            ] + lettering.measurements(room: room), printing: "Print it base down.")
        }
    }

    // MARK: Mounting sign

    static var mountingSign: ProjectTemplate {
        let holes: @Sendable (TemplateValues) -> Bool = { $0.choice("mounting") == 1 }
        return ProjectTemplate(
            id: "signs.mounting-sign", category: .signs, title: "Mounting Sign",
            summary: "Create a sign for a door, shelf, or workshop, with screw holes or without.",
            parameters: [
                TemplateParameter(id: "width", title: "Width", kind: .length(40...300, step: 1), defaultValue: 120),
                TemplateParameter(id: "height", title: "Height", kind: .length(20...150, step: 1), defaultValue: 50),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...8, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "radius", title: "Corner radius", kind: .length(0...15, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "mounting", title: "Mounting", kind: .choice(["No holes", "Two holes"]), defaultValue: 1),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2...8, step: 0.1), defaultValue: 4.5, isShown: holes),
                TemplateParameter(id: "inset", title: "Hole inset", kind: .length(4...25, step: 0.5), defaultValue: 8,
                                  note: "From each short edge to the hole's center", isShown: holes)
            ] + letteringParameters(height: 12, heights: 4...40, margin: 4, margins: 2...12),
            name: { values in "Sign \(values.text("text"))" },
            make: { values in [TemplatePart(name: "Sign", body: try MountingSign(values).body())] },
            notes: { values in MountingSign(values).notes },
            textParameters: [textParameter("Workshop", maxLength: 40)])
    }

    struct MountingSign {
        var lettering: Lettering
        var width, height, thickness, radius, hole, inset: Double
        var holes: Bool
        init(_ values: TemplateValues) {
            lettering = Lettering(values)
            width = values["width"]; height = values["height"]; thickness = values["thickness"]; radius = values["radius"]
            holes = values.choice("mounting") == 1; hole = values["hole"]; inset = values["inset"]
        }
        /// The holes' bands at each end are kept clear of the text.
        var band: Double { holes ? inset + hole / 2 : 0 }
        var room: (width: Double, height: Double) { (width - 2 * band - 2 * lettering.margin, height - 2 * lettering.margin) }

        func body() throws -> SolidBody {
            try checkCorner(radius, width: width, height: height)
            if holes {
                guard inset - hole / 2 >= 2 - 1e-9, height / 2 - hole / 2 >= 2 - 1e-9 else {
                    throw TemplateError.tooSmall("The holes need 2 mm round them. Move them in from the ends or make them smaller.")
                }
                guard materialRound(Point2(x: width / 2 - inset, y: 0)) >= 2 - 1e-9 else {
                    throw TemplateError.tooSmall("The holes come too near the rounded corners. Move them in or use a smaller corner radius.")
                }
            }
            var sign = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: height, radius: radius, on: .top), height: thickness)
            let top = TemplateGeometry.horizontal(thickness)
            if holes {
                for x in [-(width / 2 - inset), width / 2 - inset] {
                    sign.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(hole, label: "Sign"), at: Point2(x: x, y: 0), on: top, depth: nil))
                }
            }
            sign.cuts.append(try lettering.cut(on: top, center: .zero, room: room, thickness: thickness))
            return sign
        }

        /// Material between a hole at `center` and the sign's edge, round corners included.
        func materialRound(_ center: Point2) -> Double {
            materialAround(center, radius: hole / 2, width: width, height: height, corner: radius)
        }

        var notes: TemplateNotes {
            var measurements = [TemplateMeasurement(title: "Sign", lengths: [width, height, thickness])]
            if holes { measurements.append(TemplateMeasurement(title: "Holes", lengths: [hole, width - 2 * inset], text: "across, centers apart")) }
            return TemplateNotes(measurements: measurements + lettering.measurements(room: room),
                                 hardware: holes ? "Two \(TemplateFormat.screw(forHole: hole)) screws." : "Double-sided tape or adhesive pads.",
                                 printing: "Print it back face down.")
        }
    }

    /// Material between a hole of `radius` at `center` and the edge of a rounded rectangle
    /// centered on the origin.
    static func materialAround(_ center: Point2, radius: Double, width: Double, height: Double, corner: Double) -> Double {
        let p = Point2(x: abs(center.x), y: abs(center.y))
        var room = min(width / 2 - p.x, height / 2 - p.y)
        let arc = Point2(x: width / 2 - corner, y: height / 2 - corner)
        if corner > 0, p.x > arc.x, p.y > arc.y { room = min(room, corner - p.distance(to: arc)) }
        return room - radius
    }

    // MARK: Key tag

    static var keyTag: ProjectTemplate {
        ProjectTemplate(
            id: "signs.key-tag", category: .signs, title: "Key Tag",
            summary: "Label a key or a bag with a small tag of your own words.",
            parameters: [
                TemplateParameter(id: "width", title: "Width", kind: .length(30...100, step: 1), defaultValue: 60),
                TemplateParameter(id: "height", title: "Height", kind: .length(15...45, step: 1), defaultValue: 25),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "radius", title: "Corner radius", kind: .length(1...10, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "hole", title: "Ring hole", kind: .length(3...10, step: 0.5), defaultValue: 5),
                TemplateParameter(id: "inset", title: "Ring hole inset", kind: .length(4...15, step: 0.5), defaultValue: 7,
                                  note: "From the left edge to the hole's center")
            ] + letteringParameters(height: 8, heights: 4...18, margin: 3, margins: 2...6),
            name: { values in "Key Tag \(values.text("text"))" },
            make: { values in [TemplatePart(name: "Key Tag", body: try KeyTag(values).body())] },
            // Free (user decision, October 28, 2026).
            needsPro: false,
            notes: { values in KeyTag(values).notes },
            textParameters: [textParameter("Keys", maxLength: 18)])
    }

    struct KeyTag {
        var lettering: Lettering
        var width, height, thickness, radius, hole, inset: Double
        init(_ values: TemplateValues) {
            lettering = Lettering(values)
            width = values["width"]; height = values["height"]; thickness = values["thickness"]; radius = values["radius"]
            hole = values["hole"]; inset = values["inset"]
        }
        /// The text sits right of the hole.
        var textLeft: Double { -width / 2 + inset + hole / 2 + lettering.margin }
        var room: (width: Double, height: Double) { (width / 2 - lettering.margin - textLeft, height - 2 * lettering.margin) }

        func body() throws -> SolidBody {
            try checkCorner(radius, width: width, height: height)
            let ring = Point2(x: -width / 2 + inset, y: 0)
            guard materialAround(ring, radius: hole / 2, width: width, height: height, corner: radius) >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The ring hole needs 2 mm round it. Move it in, make it smaller, or make the tag taller.")
            }
            var tag = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: height, radius: radius, on: .top), height: thickness)
            let top = TemplateGeometry.horizontal(thickness)
            tag.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(hole, label: "Ring"), at: ring, on: top, depth: nil))
            tag.cuts.append(try lettering.cut(on: top, center: Point2(x: (textLeft + width / 2 - lettering.margin) / 2, y: 0), room: room, thickness: thickness))
            return tag
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Tag", lengths: [width, height, thickness]),
                TemplateMeasurement(title: "Ring hole", lengths: [hole])
            ] + lettering.measurements(room: room), hardware: "A split ring, if you like.", printing: "Print it back down.")
        }
    }

    // MARK: Plant marker

    static var plantMarker: ProjectTemplate {
        ProjectTemplate(
            id: "signs.plant-marker", category: .signs, title: "Plant Marker",
            summary: "Label a plant with a marker whose spike is sized for its pot.",
            parameters: [
                TemplateParameter(id: "width", title: "Label width", kind: .length(30...100, step: 1), defaultValue: 60),
                TemplateParameter(id: "height", title: "Label height", kind: .length(15...45, step: 1), defaultValue: 25),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(1.6...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "spike", title: "Spike length", kind: .length(40...180, step: 1), defaultValue: 100, note: "Below the label"),
                TemplateParameter(id: "spikeWidth", title: "Spike width", kind: .length(6...20, step: 0.5), defaultValue: 12),
                TemplateParameter(id: "tip", title: "Tapered tip", kind: .length(10...40, step: 1), defaultValue: 20)
            ] + letteringParameters(height: 8, heights: 4...18, margin: 3, margins: 2...6),
            name: { values in "Plant Marker \(values.text("text"))" },
            make: { values in [TemplatePart(name: "Plant Marker", body: try PlantMarker(values).body())] },
            notes: { values in PlantMarker(values).notes },
            textParameters: [textParameter("Basil", maxLength: 24)])
    }

    struct PlantMarker {
        var lettering: Lettering
        var width, height, thickness, spike, spikeWidth, tip: Double
        init(_ values: TemplateValues) {
            lettering = Lettering(values)
            width = values["width"]; height = values["height"]; thickness = values["thickness"]
            spike = values["spike"]; spikeWidth = values["spikeWidth"]; tip = values["tip"]
        }
        var room: (width: Double, height: Double) { (width - 2 * lettering.margin, height - 2 * lettering.margin) }

        func body() throws -> SolidBody {
            guard tip < spike - 1e-9 else { throw TemplateError.tooSmall("The tapered tip must be shorter than the spike.") }
            guard spikeWidth <= width - 4 + 1e-9 else { throw TemplateError.tooSmall("The spike must be narrower than the label.") }
            var marker = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: height, radius: 3, on: .top), height: thickness)
            // The spike runs down from inside the label, narrowing to a 1 mm tip.
            let w = spikeWidth / 2, joint = -height / 2 + 1, shoulder = -height / 2 - (spike - tip), end = -height / 2 - spike
            marker.cuts.append(TemplateGeometry.step(TemplateGeometry.polygon([Point2(x: -w, y: joint), Point2(x: -w, y: shoulder), Point2(x: -0.5, y: end),
                                                                               Point2(x: 0.5, y: end), Point2(x: w, y: shoulder), Point2(x: w, y: joint)],
                                                                              on: .top), depth: thickness, join: true))
            marker.cuts.append(try lettering.cut(on: TemplateGeometry.horizontal(thickness), center: .zero, room: room, thickness: thickness))
            return marker
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Marker", lengths: [height + spike], text: "long overall"),
                TemplateMeasurement(title: "Label", lengths: [width, height, thickness]),
                TemplateMeasurement(title: "Spike", lengths: [spikeWidth, spike], text: "wide, long")
            ] + lettering.measurements(room: room) + (lettering.recessed
                ? [TemplateMeasurement(title: "Behind the letters", lengths: [thickness - lettering.depth])] : []),
               printing: "Print it back face down. Whether it lasts outdoors depends on the material; test it first.")
        }
    }
}
