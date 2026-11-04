import Foundation
import simd

/// Cable Management (October 28, 2026): saddles, combs, grommets, and winders sized from the
/// cable or hole they're for.
enum CableTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "cables.saddle", category: .cables, title: "Screw-Mounted Cable Saddle",
            summary: "Secure a cable with a rigid saddle that screws down over it, open underneath to fit an installed cable.",
            parameters: [
                TemplateParameter(id: "cable", title: "Cable diameter", kind: .length(2...25, step: 0.1), defaultValue: 6, note: "As measured"),
                fitParameter,
                TemplateParameter(id: "width", title: "Saddle width", kind: .length(6...30, step: 1), defaultValue: 10, note: "Along the cable"),
                TemplateParameter(id: "arch", title: "Arch thickness", kind: .length(1.2...5, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "foot", title: "Foot thickness", kind: .length(2...6, step: 0.1), defaultValue: 3),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2...6, step: 0.1), defaultValue: 3.4),
                TemplateParameter(id: "spacing", title: "Hole spacing", kind: .length(10...70, step: 1), defaultValue: 22, note: "Center to center")
            ],
            name: { values in "Cable Saddle Ø\(TemplateFormat.number(values["cable"]))" },
            make: { values in try Saddle(values).parts() },
            notes: { values in Saddle(values).notes }),
         ProjectTemplate(
            id: "cables.comb", category: .cables, title: "Cable Comb",
            summary: "Keep several cables apart along a desk or bench, each in its own open groove.",
            parameters: [
                TemplateParameter(id: "count", title: "Channels", kind: .count(2...12), defaultValue: 4),
                TemplateParameter(id: "cable", title: "Cable diameter", kind: .length(2...12, step: 0.1), defaultValue: 4, note: "As measured"),
                fitParameter,
                TemplateParameter(id: "between", title: "Material between channels", kind: .length(1.2...5, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "base", title: "Base thickness", kind: .length(2...6, step: 0.1), defaultValue: 3, note: "Under each channel"),
                TemplateParameter(id: "depth", title: "Front-to-back depth", kind: .length(6...30, step: 1), defaultValue: 12)
            ],
            name: { values in "Cable Comb \(values.count("count")) × Ø\(TemplateFormat.number(values["cable"]))" },
            make: { values in try Comb(values).parts() },
            notes: { values in Comb(values).notes }),
         ProjectTemplate(
            id: "cables.grommet", category: .cables, title: "Desk Cable Grommet",
            summary: "Finish a hole in a desk or panel and guide cables through it, with a side opening for cables already plugged in.",
            parameters: [
                TemplateParameter(id: "hole", title: "Panel hole diameter", kind: .length(15...100, step: 0.5), defaultValue: 40, note: "As measured"),
                TemplateParameter(id: "panel", title: "Panel thickness", kind: .length(3...40, step: 0.5), defaultValue: 18),
                fitParameter,
                TemplateParameter(id: "wall", title: "Sleeve wall", kind: .length(1.2...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "overhang", title: "Flange overhang", kind: .length(2...10, step: 0.5), defaultValue: 4,
                                  note: "How far the flange reaches past the hole"),
                TemplateParameter(id: "flange", title: "Flange thickness", kind: .length(1.2...5, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "opening", title: "Side opening", kind: .length(0...25, step: 0.5), defaultValue: 6,
                                  note: "A slot for cables already plugged in; 0 makes a closed ring")
            ],
            name: { values in "Cable Grommet Ø\(TemplateFormat.number(values["hole"]))" },
            make: { values in try Grommet(values).parts() },
            notes: { values in Grommet(values).notes }),
         ProjectTemplate(
            id: "cables.winder", category: .cables, title: "Cable Winder",
            summary: "Wind a loose cable round a flat holder, its ends tucked into the notches.",
            parameters: [
                TemplateParameter(id: "length", title: "Length", kind: .length(40...160, step: 1), defaultValue: 80),
                TemplateParameter(id: "endWidth", title: "End width", kind: .length(20...60, step: 1), defaultValue: 30),
                TemplateParameter(id: "waist", title: "Waist width", kind: .length(8...40, step: 1), defaultValue: 14, note: "Where the cable winds"),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "notchWidth", title: "End notch width", kind: .length(3...20, step: 0.5), defaultValue: 8),
                TemplateParameter(id: "notchDepth", title: "End notch depth", kind: .length(4...25, step: 0.5), defaultValue: 10),
                TemplateParameter(id: "radius", title: "Edge radius", kind: .length(1...5, step: 0.5), defaultValue: 2, note: "Rounds the corners the cable bends round")
            ],
            name: { values in "Cable Winder \(TemplateFormat.number(values["length"])) mm" },
            make: { values in try Winder(values).parts() },
            notes: { values in Winder(values).notes })]
    }

    static var fitParameter: TemplateParameter {
        TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                          note: "Gap on each side of the cable; starts from the Fit in the project menu")
    }

    // MARK: Saddle

    struct Saddle {
        var radius, arch, width, foot, hole, spacing: Double
        init(_ values: TemplateValues) {
            radius = values["cable"] / 2 + values["fit"]
            arch = values["arch"]; width = values["width"]; foot = values["foot"]; hole = values["hole"]; spacing = values["spacing"]
        }
        var outer: Double { radius + arch }
        var footEnd: Double { spacing / 2 + hole / 2 + 2.5 }

        func parts() throws -> [TemplatePart] {
            // Room for a screw head (about twice the hole across) between the arch and each hole.
            let closest = 2 * (outer + hole)
            guard spacing >= closest - 1e-9 else {
                throw TemplateError.tooSmall("The arch leaves no room for the screw heads. Space the holes \(TemplateFormat.number(closest, digits: 1)) mm apart or more.")
            }
            guard width >= hole + 2 * MountTemplates.ligament - 1e-9 else {
                throw TemplateError.tooSmall("The saddle is too narrow for its holes. Make it \(TemplateFormat.number(hole + 2 * MountTemplates.ligament, digits: 1)) mm wide or more.")
            }
            // On its side: the feet along x with the arch rising over the cable in y, extruded
            // along the cable. The cable lies on the wall at y = 0, so the opening is open beneath.
            var saddle = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: foot / 2), width: 2 * footEnd, depth: foot,
                                                                                  radius: 0, on: .top), height: width)
            let center = Point2(x: 0, y: radius)
            saddle.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(2 * outer, at: center, on: .top), depth: width, join: true))
            saddle.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(2 * radius, at: center, on: .top)))
            saddle.cuts.append(TemplateGeometry.through(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: radius / 2 - 0.5), width: 2 * radius,
                                                                                         depth: radius + 1, radius: 0, on: .top)))
            saddle.cuts.append(TemplateGeometry.through(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: -(arch + 1) / 2), width: 2 * outer + 2,
                                                                                         depth: arch + 1, radius: 0, on: .top)))
            for x in [-spacing / 2, spacing / 2] {
                saddle.cuts.append(TemplateGeometry.sideHole(hole, at: SIMD3(x, 0, width / 2), along: SIMD3(0, -1, 0), label: "Saddle"))
            }
            return [TemplatePart(name: "Saddle", body: saddle)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Cable opening", lengths: [2 * radius], text: "wide, open underneath"),
                TemplateMeasurement(title: "Hole spacing", lengths: [spacing]),
                TemplateMeasurement(title: "Saddle", lengths: [2 * footEnd, width, max(2 * radius + arch, foot)])
            ], hardware: "Two \(TemplateFormat.screw(forHole: hole)) screws.",
               printing: "Print it on its side so the arch needs no support. This orientation still needs a test print to confirm.")
        }
    }

    // MARK: Comb

    struct Comb {
        var count: Int
        var channel, between, base, depth: Double
        init(_ values: TemplateValues) {
            count = values.count("count")
            channel = values["cable"] + 2 * values["fit"]
            between = values["between"]; base = values["base"]; depth = values["depth"]
        }
        static let border = 2.0
        var width: Double { Double(count) * channel + Double(count - 1) * between + 2 * Self.border }
        var height: Double { base + channel / 2 }

        func parts() throws -> [TemplatePart] {
            var comb = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: 0, on: .top), height: height)
            // Half-round grooves open on top, running front to back.
            for index in 0..<count {
                let x = -width / 2 + Self.border + channel / 2 + Double(index) * (channel + between)
                comb.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(channel, around: SIMD3(x, -depth / 2, height), facing: SIMD3(0, -1, 0))))
            }
            return [TemplatePart(name: "Comb", body: comb)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Comb", lengths: [width, depth, height]),
                TemplateMeasurement(title: "Grooves", lengths: [channel], text: "wide, half round, open on top"),
                TemplateMeasurement(title: "Between grooves", lengths: [between])
            ], hardware: "Double-sided mounting tape, if you want it stuck down.",
               printing: "Print it base down. It guides the cables; it doesn't grip them.")
        }
    }

    // MARK: Grommet

    struct Grommet {
        var hole, panel, fit, wall, overhang, flange, opening: Double
        init(_ values: TemplateValues) {
            hole = values["hole"]; panel = values["panel"]; fit = values["fit"]; wall = values["wall"]
            overhang = values["overhang"]; flange = values["flange"]; opening = values["opening"]
        }
        var sleeve: Double { hole - 2 * fit }
        var bore: Double { sleeve - 2 * wall }
        var flangeDiameter: Double { hole + 2 * overhang }

        func parts() throws -> [TemplatePart] {
            guard bore >= 3 - 1e-9 else { throw TemplateError.tooSmall("The sleeve walls leave no room for cables. Make them thinner, or measure a bigger hole.") }
            guard opening < bore - 1e-9 else {
                throw TemplateError.tooSmall("The side opening must be narrower than the cable opening (\(TemplateFormat.number(bore, digits: 1)) mm).")
            }
            // Flange down, the sleeve standing on it.
            var grommet = TemplateGeometry.block(TemplateGeometry.region(TemplateGeometry.circle(flangeDiameter, at: .zero, on: .top),
                                                                         holes: [TemplateGeometry.circle(bore, at: .zero, on: .top)]), height: flange)
            let plane = TemplateGeometry.horizontal(flange)
            grommet.cuts.append(TemplateGeometry.step(TemplateGeometry.region(TemplateGeometry.circle(sleeve, at: .zero, on: plane),
                                                                              holes: [TemplateGeometry.circle(bore, at: .zero, on: plane)]), depth: panel, join: true))
            if opening > 0 {
                // A slot from the bore out through sleeve and flange.
                let reach = flangeDiameter / 2 + 2
                grommet.cuts.append(TemplateGeometry.through(TemplateGeometry.roundedRectangle(center: Point2(x: reach / 2, y: 0), width: reach, depth: opening,
                                                                                               radius: 0, on: .top)))
            }
            return [TemplatePart(name: "Grommet", body: grommet)]
        }

        var notes: TemplateNotes {
            var measurements = [
                TemplateMeasurement(title: "Fits a hole", lengths: [hole], text: "sleeve \(TemplateFormat.number(sleeve)) mm across"),
                TemplateMeasurement(title: "Cable opening", lengths: [bore]),
                TemplateMeasurement(title: "Insertion depth", lengths: [panel]),
                TemplateMeasurement(title: "Flange", lengths: [flangeDiameter, flange])
            ]
            if opening > 0 { measurements.append(TemplateMeasurement(title: "Side opening", lengths: [opening], text: "wide")) }
            return TemplateNotes(measurements: measurements, printing: "Print it flange down.")
        }
    }

    // MARK: Winder

    struct Winder {
        var length, endWidth, waist, thickness, notchWidth, notchDepth, radius: Double
        init(_ values: TemplateValues) {
            length = values["length"]; endWidth = values["endWidth"]; waist = values["waist"]; thickness = values["thickness"]
            notchWidth = values["notchWidth"]; notchDepth = values["notchDepth"]; radius = values["radius"]
        }
        /// How far the narrow waist reaches each way from the middle.
        var waistReach: Double { length / 2 - notchDepth - 4 }

        func parts() throws -> [TemplatePart] {
            guard waist < endWidth - 1e-9 else { throw TemplateError.tooSmall("The waist must be narrower than the ends, so the cable stays on.") }
            guard (endWidth - notchWidth) / 2 >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The notches leave less than 2 mm beside them. Make the ends \(TemplateFormat.number(notchWidth + 4)) mm wide or more, or the notches narrower.")
            }
            guard waistReach >= 4 - 1e-9 else {
                throw TemplateError.tooSmall("The notches leave no room for the waist. Make the winder \(TemplateFormat.number(2 * notchDepth + 16)) mm long or more, or the notches shallower.")
            }
            var winder = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: length, depth: endWidth, radius: radius, on: .top), height: thickness)
            // The waist: a rounded bite from each long side.
            let bite = (endWidth - waist) / 2 + 5
            let corner = min(max(1.5 * radius, 2), waistReach / 2, bite / 2 - 0.1)
            for side in [-1.0, 1] {
                let center = Point2(x: 0, y: side * (waist / 2 + bite / 2))
                winder.cuts.append(TemplateGeometry.through(TemplateGeometry.roundedRectangle(center: center, width: 2 * waistReach, depth: bite,
                                                                                             radius: corner, on: .top)))
            }
            // A U-shaped notch in each end for the cable's ends.
            for side in [-1.0, 1] {
                let root = side * (length / 2 - notchDepth + notchWidth / 2)
                winder.cuts.append(TemplateGeometry.through(TemplateGeometry.slot(from: Point2(x: root, y: 0), to: Point2(x: side * (length / 2 + notchWidth), y: 0),
                                                                                 width: notchWidth, on: .top)))
            }
            return [TemplatePart(name: "Winder", body: winder)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Winder", lengths: [length, endWidth, thickness]),
                TemplateMeasurement(title: "Waist", lengths: [waist, 2 * waistReach], text: "wide, long"),
                TemplateMeasurement(title: "End notches", lengths: [notchWidth, notchDepth], text: "wide, deep")
            ], printing: "Print it flat. Check that the edges the cable bends round are smooth, and that your cable can bend that tightly.")
        }
    }
}
