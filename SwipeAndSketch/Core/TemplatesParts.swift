import Foundation
import simd

/// Replacement Parts (October 28, 2026): knobs, handles, plugs, and spacers made to measurements
/// of the part being replaced. Each comes out lying the way it prints.
enum PartTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "parts.knob", category: .parts, title: "Control Knob",
            summary: "Replace a knob on a D-shaped or hexagonal shaft, with a smooth or fluted grip.",
            parameters: [
                TemplateParameter(id: "diameter", title: "Knob diameter", kind: .length(12...60, step: 1), defaultValue: 24),
                TemplateParameter(id: "height", title: "Height", kind: .length(8...40, step: 1), defaultValue: 16),
                TemplateParameter(id: "shaft", title: "Shaft", kind: .choice(Knob.shaftChoices), defaultValue: 0),
                TemplateParameter(id: "shaftSize", title: "Shaft size", kind: .length(3...20, step: 0.05), defaultValue: 6,
                                  note: "The round part's diameter, or across the flats of a hexagon"),
                TemplateParameter(id: "flat", title: "Flat depth", kind: .length(0.2...3, step: 0.05), defaultValue: 0.5,
                                  note: "How far the flat cuts into the round", isShown: { $0.choice("shaft") == 0 }),
                TemplateParameter(id: "boreDepth", title: "Bore depth", kind: .length(4...35, step: 0.5), defaultValue: 12),
                TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the shaft; starts from the Fit in the project menu"),
                TemplateParameter(id: "grip", title: "Grip", kind: .choice(["Smooth", "Fluted"]), defaultValue: 1)
            ],
            name: { values in "Knob Ø\(TemplateFormat.number(values["diameter"]))" },
            make: { values in try Knob(values).parts() },
            notes: { values in Knob(values).notes }),
         ProjectTemplate(
            id: "parts.handle", category: .parts, title: "Pull Handle",
            summary: "Replace a drawer or door handle using the holes the old one left.",
            parameters: [
                TemplateParameter(id: "centers", title: "Mounting centers", kind: .length(40...200, step: 1), defaultValue: 96,
                                  note: "From one screw hole's center to the other's"),
                TemplateParameter(id: "gripWidth", title: "Clear grip width", kind: .length(20...160, step: 1), defaultValue: 64,
                                  note: "Room for the hand between the supports"),
                TemplateParameter(id: "gripHeight", title: "Clear grip height", kind: .length(10...50, step: 1), defaultValue: 20,
                                  note: "Room for the fingers under the grip"),
                TemplateParameter(id: "sectionWidth", title: "Grip width", kind: .length(8...25, step: 0.5), defaultValue: 12),
                TemplateParameter(id: "sectionThickness", title: "Grip thickness", kind: .length(5...16, step: 0.5), defaultValue: 8),
                TemplateParameter(id: "tab", title: "Mounting tab thickness", kind: .length(2...8, step: 0.1), defaultValue: 4),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2.5...8, step: 0.1), defaultValue: 4.5)
            ],
            name: { values in "Pull Handle \(TemplateFormat.number(values["centers"])) mm" },
            make: { values in try Handle(values).parts() },
            notes: { values in Handle(values).notes }),
         ProjectTemplate(
            id: "parts.tube-plug", category: .parts, title: "Tube Plug",
            summary: "Cap the open end of a round or rectangular tube with a plug that presses inside it.",
            parameters: [
                TemplateParameter(id: "shape", title: "Tube", kind: .choice(["Round", "Rectangular"]), defaultValue: 0),
                TemplateParameter(id: "diameter", title: "Inside diameter", kind: .length(8...80, step: 0.1), defaultValue: 20,
                                  note: "As measured", isShown: { $0.choice("shape") == 0 }),
                TemplateParameter(id: "width", title: "Inside width", kind: .length(8...80, step: 0.1), defaultValue: 20,
                                  note: "As measured", isShown: { $0.choice("shape") == 1 }),
                TemplateParameter(id: "depth", title: "Inside depth", kind: .length(8...80, step: 0.1), defaultValue: 20,
                                  note: "As measured", isShown: { $0.choice("shape") == 1 }),
                TemplateParameter(id: "insertion", title: "Insertion depth", kind: .length(5...40, step: 1), defaultValue: 15),
                TemplateParameter(id: "wall", title: "Sleeve wall", kind: .length(1.2...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "cap", title: "Cap thickness", kind: .length(1.2...5, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "overhang", title: "Cap overhang", kind: .length(1...8, step: 0.5), defaultValue: 3,
                                  note: "How far the cap reaches past the opening"),
                TemplateParameter(id: "interference", title: "Interference per side", kind: .length(-0.5...0.3, step: 0.05), defaultValue: 0.1,
                                  note: "Positive presses tight; negative leaves a gap")
            ],
            name: { values in
                values.choice("shape") == 0 ? "Tube Plug Ø\(TemplateFormat.number(values["diameter"]))"
                    : "Tube Plug \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))"
            },
            make: { values in try TubePlug(values).parts() },
            notes: { values in TubePlug(values).notes }),
         ProjectTemplate(
            id: "parts.spacers", category: .parts, title: "Spacer Set",
            summary: "Make round spacers that share one bore, in lengths that step up from the first.",
            parameters: [
                TemplateParameter(id: "outside", title: "Outside diameter", kind: .length(5...50, step: 0.5), defaultValue: 10),
                TemplateParameter(id: "bore", title: "Bore diameter", kind: .length(2...20, step: 0.05), defaultValue: 3.4),
                TemplateParameter(id: "first", title: "First length", kind: .length(1...100, step: 0.5), defaultValue: 2),
                TemplateParameter(id: "increment", title: "Length increment", kind: .length(0...10, step: 0.5), defaultValue: 1,
                                  note: "0 makes identical spacers"),
                TemplateParameter(id: "count", title: "Spacers", kind: .count(1...12), defaultValue: 5)
            ],
            name: { values in "Spacers Ø\(TemplateFormat.number(values["outside"]))" },
            make: { values in try Spacers(values).parts() },
            needsPro: false,
            notes: { values in Spacers(values).notes })]
    }

    // MARK: Control knob

    struct Knob {
        static let shaftChoices = ["D-shaped", "Hexagonal"]
        var diameter, height, shaft, flat, boreDepth, fit: Double
        var hexagonal: Bool
        var fluted: Bool
        init(_ values: TemplateValues) {
            diameter = values["diameter"]; height = values["height"]; shaft = values["shaftSize"]; flat = values["flat"]
            boreDepth = values["boreDepth"]; fit = values["fit"]
            hexagonal = values.choice("shaft") == 1
            fluted = values.choice("grip") == 1
        }

        /// The bore's widest reach from the axis: the round's radius, or the hexagon's corners.
        var boreRadius: Double { hexagonal ? (shaft + 2 * fit) / 3.squareRoot() : shaft / 2 + fit }
        var fluteDiameter: Double { min(max(diameter * 0.12, 2), 5) }
        var fluteCount: Int { min(24, max(8, Int((Double.pi * diameter / 5).rounded()))) }
        /// How far each flute reaches in from the knob's side.
        var fluteDepth: Double { fluted ? fluteDiameter * 0.3 : 0 }
        var roof: Double { height - boreDepth }

        func parts() throws -> [TemplatePart] {
            guard roof >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The bore leaves less than 2 mm of knob over it. Make the knob \(TemplateFormat.number(boreDepth + 2)) mm tall or more, or the bore shallower.")
            }
            let side = diameter / 2 - fluteDepth - boreRadius
            guard side >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The shaft leaves less than 2 mm of knob around it. Make the knob \(TemplateFormat.number(2 * (boreRadius + fluteDepth + 2), digits: 1)) mm across or more.")
            }
            if !hexagonal {
                guard flat < shaft / 2 else { throw TemplateError.tooSmall("The flat must cut less than halfway into the shaft.") }
            }
            // The knob stands on its closed top, its bore opening upward.
            var knob = TemplateGeometry.block(TemplateGeometry.circle(diameter, at: .zero, on: .top), height: height)
            if fluted {
                let radius = diameter / 2 + fluteDiameter / 2 - fluteDepth
                for index in 0..<fluteCount {
                    let angle = Double(index) * 2 * .pi / Double(fluteCount)
                    let center = Point2(x: cos(angle), y: sin(angle)) * radius
                    knob.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(fluteDiameter, at: center, on: .top, points: 32)))
                }
            }
            let mouth = TemplateGeometry.horizontal(height)
            if hexagonal {
                let corners = (0..<6).map { i -> Point2 in
                    let angle = Double(i) * .pi / 3
                    return Point2(x: cos(angle), y: sin(angle)) * boreRadius
                }
                knob.cuts.append(TemplateGeometry.step(TemplateGeometry.polygon(corners, on: mouth), depth: -boreDepth))
            } else {
                // The round bore, then the flat filled back in: everything past the flat's line.
                let round = shaft / 2 + fit
                knob.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(2 * round, at: .zero, on: mouth), depth: -boreDepth))
                let line = shaft / 2 - flat + fit
                let fill = TemplateGeometry.roundedRectangle(center: Point2(x: (line + round + 1) / 2, y: 0), width: round + 1 - line, depth: 2 * round + 2,
                                                             radius: 0, on: TemplateGeometry.horizontal(roof))
                knob.cuts.append(TemplateGeometry.step(fill, depth: boreDepth, join: true))
            }
            return [TemplatePart(name: "Knob", body: knob)]
        }

        var notes: TemplateNotes {
            var bore = TemplateMeasurement(title: "Bore", lengths: [shaft + 2 * fit])
            bore.text = hexagonal ? "across the flats" : "round, flat at \(TemplateFormat.number(shaft / 2 - flat + fit)) mm from the center"
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Knob", lengths: [diameter, height]),
                bore,
                TemplateMeasurement(title: "Bore depth", lengths: [boreDepth]),
                TemplateMeasurement(title: "Material over the bore", lengths: [roof]),
                TemplateMeasurement(title: "Clearance per side", lengths: [fit])
            ], printing: "Print it standing on its closed top, bore up. Try the fit on the shaft: if it slips, use less clearance.")
        }
    }

    // MARK: Pull handle

    struct Handle {
        var centers, gripWidth, gripHeight, sectionWidth, sectionThickness, tab, hole: Double
        init(_ values: TemplateValues) {
            centers = values["centers"]; gripWidth = values["gripWidth"]; gripHeight = values["gripHeight"]
            sectionWidth = values["sectionWidth"]; sectionThickness = values["sectionThickness"]; tab = values["tab"]; hole = values["hole"]
        }

        /// Where the supports' outer faces are, and the tabs' ends, from the middle.
        var supports: Double { gripWidth / 2 + sectionThickness }
        var tabEnd: Double { centers / 2 + hole / 2 + 3 }
        var top: Double { gripHeight + sectionThickness }

        func parts() throws -> [TemplatePart] {
            // A screw head about twice the hole across, with room to turn it beside the support.
            let shortest = 2 * (supports + hole + 1)
            guard centers >= shortest - 1e-9 else {
                throw TemplateError.tooSmall("The grip leaves no room for the screw heads. Make the mounting centers \(TemplateFormat.number(shortest.rounded(.up))) mm or more, or the grip narrower.")
            }
            guard sectionWidth >= hole + 4 - 1e-9 else {
                throw TemplateError.tooSmall("The tabs are too narrow for their holes. Make the grip \(TemplateFormat.number(hole + 4, digits: 1)) mm wide or more, or the holes smaller.")
            }
            // Lying on its side: the handle's outline in x and y (y is its height off the door),
            // extruded across its width.
            let a = tabEnd, b = supports, g = gripWidth / 2
            let outline = [Point2(x: -a, y: 0), Point2(x: -g, y: 0), Point2(x: -g, y: gripHeight), Point2(x: g, y: gripHeight), Point2(x: g, y: 0),
                           Point2(x: a, y: 0), Point2(x: a, y: tab), Point2(x: b, y: tab), Point2(x: b, y: top), Point2(x: -b, y: top),
                           Point2(x: -b, y: tab), Point2(x: -a, y: tab)]
            var handle = TemplateGeometry.block(TemplateGeometry.polygon(outline, on: .top), height: sectionWidth)
            for x in [-centers / 2, centers / 2] {
                handle.cuts.append(TemplateGeometry.sideHole(hole, at: SIMD3(x, 0, sectionWidth / 2), along: SIMD3(0, -1, 0), label: "Handle"))
            }
            return [TemplatePart(name: "Handle", body: handle)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Handle", lengths: [2 * tabEnd, sectionWidth, top], text: "long, wide, tall"),
                TemplateMeasurement(title: "Mounting centers", lengths: [centers]),
                TemplateMeasurement(title: "Hand room", lengths: [gripWidth, gripHeight], text: "under the grip"),
                TemplateMeasurement(title: "Holes", lengths: [hole])
            ], hardware: "Two \(TemplateFormat.screw(forHole: hole)) screws.",
               printing: "Print it lying on its side, so the opening under the grip needs no bridge.")
        }
    }

    // MARK: Tube plug

    struct TubePlug {
        var round: Bool
        var opening: (width: Double, depth: Double)
        var insertion, wall, cap, overhang, interference: Double
        init(_ values: TemplateValues) {
            round = values.choice("shape") == 0
            opening = round ? (values["diameter"], values["diameter"]) : (values["width"], values["depth"])
            insertion = values["insertion"]; wall = values["wall"]; cap = values["cap"]; overhang = values["overhang"]
            interference = values["interference"]
        }
        static let insertRadius = 1.0

        var insert: (width: Double, depth: Double) { (opening.width + 2 * interference, opening.depth + 2 * interference) }
        var bore: Double { min(insert.width, insert.depth) - 2 * wall }
        var lead: Double { min(0.8, wall / 2, insertion / 4) }

        func profile(width: Double, depth: Double, radius: Double, z: Double) -> SketchProfile {
            round ? TemplateGeometry.circle(width, at: .zero, on: TemplateGeometry.horizontal(z))
                : TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: radius, on: TemplateGeometry.horizontal(z))
        }

        func parts() throws -> [TemplatePart] {
            guard bore >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The sleeve walls leave no hollow inside the plug. Make them thinner, or measure a bigger opening.")
            }
            // Cap down, the sleeve standing on it with a lead-in at its end, hollow down to the cap.
            let r = Self.insertRadius
            var plug = TemplateGeometry.block(profile(width: opening.width + 2 * overhang, depth: opening.depth + 2 * overhang, radius: r + overhang, z: 0), height: cap)
            plug.cuts.append(TemplateGeometry.step(profile(width: insert.width, depth: insert.depth, radius: r, z: cap), depth: insertion - lead, join: true))
            plug.cuts.append(TemplateGeometry.step(profile(width: insert.width, depth: insert.depth, radius: r, z: cap + insertion - lead), depth: lead,
                                                   taper: 45, join: true))
            plug.cuts.append(TemplateGeometry.step(profile(width: insert.width - 2 * wall, depth: insert.depth - 2 * wall, radius: max(0.3, r - wall),
                                                           z: cap + insertion), depth: -insertion))
            return [TemplatePart(name: "Plug", body: plug)]
        }

        var notes: TemplateNotes {
            let sign = interference > 0 ? "+" : ""
            let fit = interference > 0 ? "presses tight" : interference < 0 ? "leaves a gap" : "exact"
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Opening (measured)", lengths: round ? [opening.width] : [opening.width, opening.depth]),
                TemplateMeasurement(title: "Insert", lengths: round ? [insert.width] : [insert.width, insert.depth]),
                TemplateMeasurement(title: "Interference", text: "\(sign)\(TemplateFormat.number(interference)) mm per side, \(fit)"),
                TemplateMeasurement(title: "Insertion depth", lengths: [insertion]),
                TemplateMeasurement(title: "Cap", lengths: round ? [opening.width + 2 * overhang, cap] : [opening.width + 2 * overhang, opening.depth + 2 * overhang, cap])
            ], printing: "Print it cap down. The right interference depends on your printer and material: print one and adjust.")
        }
    }

    // MARK: Spacers

    struct Spacers {
        var outside, bore, first, increment: Double
        var count: Int
        init(_ values: TemplateValues) {
            outside = values["outside"]; bore = values["bore"]; first = values["first"]; increment = values["increment"]; count = values.count("count")
        }
        var lengths: [Double] { (0..<count).map { first + Double($0) * increment } }

        func parts() throws -> [TemplatePart] {
            guard outside - bore >= 4 - 1e-9 else {
                throw TemplateError.tooSmall("Leave at least 2 mm around the bore: make the spacers \(TemplateFormat.number(bore + 4)) mm across or more, or the bore smaller.")
            }
            let pitch = outside + 4
            return lengths.enumerated().map { index, length in
                let center = Point2(x: (Double(index) - Double(count - 1) / 2) * pitch, y: 0)
                let ring = TemplateGeometry.region(TemplateGeometry.circle(outside, at: center, on: .top), holes: [TemplateGeometry.circle(bore, at: center, on: .top)])
                let name = increment > 0 ? "Spacer \(TemplateFormat.number(length)) mm" : "Spacer \(index + 1)"
                return TemplatePart(name: name, body: TemplateGeometry.block(ring, height: length))
            }
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Outside", lengths: [outside]),
                TemplateMeasurement(title: "Bore", lengths: [bore]),
                TemplateMeasurement(title: increment > 0 ? "Lengths" : "Length", lengths: increment > 0 ? lengths : [first], separator: ", ",
                                    text: increment > 0 ? nil : "× \(count)")
            ], hardware: "The screw or bolt that goes through them.", printing: "Print them standing on end.")
        }
    }
}
