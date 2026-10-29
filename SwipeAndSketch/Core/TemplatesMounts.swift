import Foundation
import simd

/// Brackets & Mounts (October 28, 2026): brackets and plates for screwing parts to walls, shelves,
/// and frames. Brackets lie on their sides, their profile flat on the plate, so the layers run
/// round the bends instead of across them.
enum MountTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "mounts.l-bracket", category: .mounts, title: "L-Bracket",
            summary: "Join two surfaces at a right angle, with screw holes in each leg and ribs for extra strength.",
            parameters: [
                TemplateParameter(id: "leg1", title: "First leg", kind: .length(15...200, step: 1), defaultValue: 40),
                TemplateParameter(id: "leg2", title: "Second leg", kind: .length(15...200, step: 1), defaultValue: 40),
                TemplateParameter(id: "width", title: "Width", kind: .length(12...100, step: 1), defaultValue: 30),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...10, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2...8, step: 0.1), defaultValue: 3.4),
                TemplateParameter(id: "holes", title: "Holes per leg", kind: .count(0...2), defaultValue: 1),
                TemplateParameter(id: "ribs", title: "Reinforcement", kind: .toggle, defaultValue: 0, note: "Two triangular ribs inside the corner")
            ],
            name: { values in "L-Bracket \(TemplateFormat.number(values["leg1"])) × \(TemplateFormat.number(values["leg2"]))" },
            make: { values in try LBracket(values).parts() },
            notes: { values in LBracket(values).notes }),
         ProjectTemplate(
            id: "mounts.u-bracket", category: .mounts, title: "U-Bracket",
            summary: "Mount around a rectangular part or rail, with two screw holes between the arms.",
            parameters: [
                TemplateParameter(id: "component", title: "Component width", kind: .length(10...150, step: 0.5), defaultValue: 40, note: "As measured"),
                TemplateParameter(id: "fit", title: "Side clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the component; starts from the Fit in the project menu"),
                TemplateParameter(id: "armHeight", title: "Clear arm height", kind: .length(10...100, step: 1), defaultValue: 30, note: "Inside, from the base up"),
                TemplateParameter(id: "depth", title: "Bracket depth", kind: .length(10...100, step: 1), defaultValue: 25),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(2...10, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "base", title: "Base thickness", kind: .length(2...10, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2...8, step: 0.1), defaultValue: 3.4),
                TemplateParameter(id: "spacing", title: "Hole spacing", kind: .length(8...120, step: 1), defaultValue: 20, note: "Center to center")
            ],
            name: { values in "U-Bracket \(TemplateFormat.number(values["component"])) mm" },
            make: { values in try UBracket(values).parts() },
            notes: { values in UBracket(values).notes }),
         ProjectTemplate(
            id: "mounts.slotted-plate", category: .mounts, title: "Slotted Mounting Plate",
            summary: "Mount parts with room to adjust: a plate with slots instead of round screw holes.",
            parameters: [
                TemplateParameter(id: "width", title: "Width", kind: .length(20...250, step: 1), defaultValue: 80),
                TemplateParameter(id: "depth", title: "Depth", kind: .length(12...150, step: 1), defaultValue: 30),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...10, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "columns", title: "Columns", kind: .count(1...4), defaultValue: 2),
                TemplateParameter(id: "rows", title: "Rows", kind: .count(1...4), defaultValue: 1),
                TemplateParameter(id: "columnPitch", title: "Column spacing", kind: .length(5...150, step: 1), defaultValue: 45, note: "Center to center"),
                TemplateParameter(id: "rowPitch", title: "Row spacing", kind: .length(5...100, step: 1), defaultValue: 12, note: "Center to center"),
                TemplateParameter(id: "slotWidth", title: "Slot width", kind: .length(2...10, step: 0.1), defaultValue: 3.4),
                TemplateParameter(id: "slotLength", title: "Slot length", kind: .length(4...50, step: 0.5), defaultValue: 14, note: "Overall, end to end")
            ],
            name: { values in "Slotted Plate \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))" },
            make: { values in try SlottedPlate(values).parts() },
            notes: { values in SlottedPlate(values).notes }),
         ProjectTemplate(
            id: "mounts.keyhole-plate", category: .mounts, title: "Keyhole Mounting Plate",
            summary: "Hang a part on screw heads left standing out of the wall: lift it on, slide it down.",
            parameters: [
                TemplateParameter(id: "width", title: "Width", kind: .length(25...250, step: 1), defaultValue: 80),
                TemplateParameter(id: "height", title: "Height", kind: .length(15...100, step: 1), defaultValue: 30, note: "Up the wall"),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(2...10, step: 0.5), defaultValue: 5),
                TemplateParameter(id: "count", title: "Keyholes", kind: .count(1...4), defaultValue: 2),
                TemplateParameter(id: "spacing", title: "Keyhole spacing", kind: .length(10...150, step: 1), defaultValue: 45, note: "Center to center"),
                TemplateParameter(id: "entry", title: "Entry diameter", kind: .length(4...16, step: 0.5), defaultValue: 7, note: "Big enough for the screw head"),
                TemplateParameter(id: "neck", title: "Neck width", kind: .length(2...8, step: 0.1), defaultValue: 3.5,
                                  note: "Wider than the screw, narrower than its head"),
                TemplateParameter(id: "travel", title: "Slide travel", kind: .length(3...25, step: 0.5), defaultValue: 8,
                                  note: "From the entry's center to where the screw rests")
            ],
            name: { values in "Keyhole Plate \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["height"]))" },
            make: { values in try KeyholePlate(values).parts() },
            notes: { values in KeyholePlate(values).notes })]
    }

    /// Material left round a hole, as the spec asks of every plate and bracket.
    static let ligament = 2.0

    // MARK: L-bracket

    struct LBracket {
        var leg1, leg2, width, thickness, hole: Double
        var holes: Int
        var ribs: Bool
        init(_ values: TemplateValues) {
            leg1 = values["leg1"]; leg2 = values["leg2"]; width = values["width"]; thickness = values["thickness"]; hole = values["hole"]
            holes = values.count("holes"); ribs = values.flag("ribs")
        }
        /// Hole centers along a leg `length` long, from the corner's outside, spread over the part
        /// past the other leg.
        func centers(_ length: Double) -> [Double] {
            let pitch = (length - thickness) / Double(max(holes, 1))
            return (0..<holes).map { thickness + (Double($0) + 0.5) * pitch }
        }

        func parts() throws -> [TemplatePart] {
            if holes > 0 {
                let shortest = thickness + Double(holes) * (hole + 2 * ligament)
                guard min(leg1, leg2) >= shortest - 1e-9 else {
                    throw TemplateError.tooSmall("The holes need \(TemplateFormat.number(shortest, digits: 1)) mm legs or longer. Use fewer or smaller holes, or longer legs.")
                }
                guard width >= hole + 2 * ligament - 1e-9 else {
                    throw TemplateError.tooSmall("The bracket is too narrow for its holes. Make it \(TemplateFormat.number(hole + 2 * ligament, digits: 1)) mm wide or more.")
                }
                // With ribs at both sides, a screw head (about twice the hole across) still fits between them.
                if ribs {
                    guard width >= 2 * (thickness + hole) - 1e-9 else {
                        throw TemplateError.tooSmall("The ribs leave no room for the screw heads. Make the bracket \(TemplateFormat.number(2 * (thickness + hole), digits: 1)) mm wide or more, or turn reinforcement off.")
                    }
                }
            }
            // On its side: the L in x and y, extruded across its width.
            let t = thickness
            let outline = [Point2(x: 0, y: 0), Point2(x: leg1, y: 0), Point2(x: leg1, y: t), Point2(x: t, y: t), Point2(x: t, y: leg2), Point2(x: 0, y: leg2)]
            var bracket = TemplateGeometry.block(TemplateGeometry.polygon(outline, on: .top), height: width)
            if ribs {
                let reach = 0.6 * (min(leg1, leg2) - t)
                let triangle = [Point2(x: t - 0.5, y: t - 0.5), Point2(x: t + reach, y: t - 0.5), Point2(x: t - 0.5, y: t + reach)]
                for z in [0, width - t] {
                    bracket.cuts.append(TemplateGeometry.step(TemplateGeometry.polygon(triangle, on: TemplateGeometry.horizontal(z)), depth: t, join: true))
                }
            }
            for x in centers(leg1) { bracket.cuts.append(TemplateGeometry.sideHole(hole, at: SIMD3(x, 0, width / 2), along: SIMD3(0, -1, 0), label: "Bracket")) }
            for y in centers(leg2) { bracket.cuts.append(TemplateGeometry.sideHole(hole, at: SIMD3(0, y, width / 2), along: SIMD3(-1, 0, 0), label: "Bracket")) }
            return [TemplatePart(name: "Bracket", body: bracket)]
        }

        var notes: TemplateNotes {
            var measurements = [
                TemplateMeasurement(title: "Legs", lengths: [leg1, leg2], text: "outside"),
                TemplateMeasurement(title: "Width × thickness", lengths: [width, thickness])
            ]
            if holes > 0 {
                measurements.append(TemplateMeasurement(title: "First leg holes", lengths: centers(leg1), separator: ", ", text: "from the outside corner"))
                measurements.append(TemplateMeasurement(title: "Second leg holes", lengths: centers(leg2), separator: ", ", text: "from the outside corner"))
            }
            return TemplateNotes(measurements: measurements,
                                 hardware: holes > 0 ? "\(2 * holes) \(TemplateFormat.screw(forHole: hole)) screws." : nil,
                                 printing: "Print it on its side, the L flat on the plate, so the layers run round the corner.")
        }
    }

    // MARK: U-bracket

    struct UBracket {
        var opening, armHeight, depth, wall, base, hole, spacing, fit: Double
        init(_ values: TemplateValues) {
            fit = values["fit"]
            opening = values["component"] + 2 * values["fit"]
            armHeight = values["armHeight"]; depth = values["depth"]; wall = values["wall"]; base = values["base"]
            hole = values["hole"]; spacing = values["spacing"]
        }

        func parts() throws -> [TemplatePart] {
            // The holes sit between the arms, where a screwdriver reaches them.
            let widest = opening - hole - 2 * ligament
            guard widest >= hole + ligament - 1e-9 else {
                throw TemplateError.tooSmall("The opening is too narrow for two holes between the arms. It needs to be \(TemplateFormat.number(2 * hole + 3 * ligament, digits: 1)) mm wide or more.")
            }
            guard spacing <= widest + 1e-9 else {
                throw TemplateError.tooSmall("The holes must fit between the arms: make their spacing \(TemplateFormat.number(max(0, widest), digits: 1)) mm or less, or the opening wider.")
            }
            guard spacing >= hole + ligament - 1e-9 else {
                throw TemplateError.tooSmall("The holes would run into each other. Space them \(TemplateFormat.number(hole + ligament, digits: 1)) mm apart or more.")
            }
            guard depth >= hole + 2 * ligament - 1e-9 else {
                throw TemplateError.tooSmall("The bracket is too shallow for its holes. Make it \(TemplateFormat.number(hole + 2 * ligament, digits: 1)) mm deep or more.")
            }
            let o = opening / 2, outer = o + wall, top = base + armHeight
            let outline = [Point2(x: -outer, y: 0), Point2(x: outer, y: 0), Point2(x: outer, y: top), Point2(x: o, y: top), Point2(x: o, y: base),
                           Point2(x: -o, y: base), Point2(x: -o, y: top), Point2(x: -outer, y: top)]
            var bracket = TemplateGeometry.block(TemplateGeometry.polygon(outline, on: .top), height: depth)
            for x in [-spacing / 2, spacing / 2] {
                bracket.cuts.append(TemplateGeometry.sideHole(hole, at: SIMD3(x, 0, depth / 2), along: SIMD3(0, -1, 0), label: "Bracket"))
            }
            return [TemplatePart(name: "Bracket", body: bracket)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Clear opening", lengths: [opening, armHeight], text: "wide, tall"),
                TemplateMeasurement(title: "Outside", lengths: [opening + 2 * wall, depth, base + armHeight]),
                TemplateMeasurement(title: "Hole spacing", lengths: [spacing]),
                TemplateMeasurement(title: "Clearance per side", lengths: [fit])
            ], hardware: "Two \(TemplateFormat.screw(forHole: hole)) screws.",
               printing: "Print it on its side, so the opening stays clear and needs no support.")
        }
    }

    // MARK: Slotted plate

    struct SlottedPlate {
        var width, depth, thickness, columnPitch, rowPitch, slotWidth, slotLength: Double
        var columns, rows: Int
        init(_ values: TemplateValues) {
            width = values["width"]; depth = values["depth"]; thickness = values["thickness"]
            columns = values.count("columns"); rows = values.count("rows")
            columnPitch = values["columnPitch"]; rowPitch = values["rowPitch"]
            slotWidth = values["slotWidth"]; slotLength = values["slotLength"]
        }

        func parts() throws -> [TemplatePart] {
            guard slotLength >= slotWidth - 1e-9 else { throw TemplateError.tooSmall("A slot can't be shorter than it is wide. Make it \(TemplateFormat.number(slotWidth)) mm long or more.") }
            if columns > 1 {
                guard columnPitch - slotLength >= ligament - 1e-9 else {
                    throw TemplateError.tooSmall("The slots would leave less than 2 mm between columns. Space them \(TemplateFormat.number(slotLength + ligament)) mm apart or more, or make them shorter.")
                }
            }
            if rows > 1 {
                guard rowPitch - slotWidth >= ligament - 1e-9 else {
                    throw TemplateError.tooSmall("The slots would leave less than 2 mm between rows. Space them \(TemplateFormat.number(slotWidth + ligament, digits: 1)) mm apart or more.")
                }
            }
            let spanX = Double(columns - 1) * columnPitch + slotLength + 2 * ligament
            let spanY = Double(rows - 1) * rowPitch + slotWidth + 2 * ligament
            guard width >= spanX - 1e-9, depth >= spanY - 1e-9 else {
                throw TemplateError.tooSmall("The slots need a plate at least \(TemplateFormat.number(spanX, digits: 1)) × \(TemplateFormat.number(spanY, digits: 1)) mm. Make it bigger, or use fewer or closer slots.")
            }
            var plate = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: min(3, min(width, depth) / 4), on: .top),
                                               height: thickness)
            for row in 0..<rows {
                for column in 0..<columns {
                    let center = Point2(x: (Double(column) - Double(columns - 1) / 2) * columnPitch, y: (Double(row) - Double(rows - 1) / 2) * rowPitch)
                    let reach = Point2(x: (slotLength - slotWidth) / 2, y: 0)
                    plate.cuts.append(TemplateGeometry.through(TemplateGeometry.slot(from: center - reach, to: center + reach, width: slotWidth, on: .top)))
                }
            }
            return [TemplatePart(name: "Plate", body: plate)]
        }

        var notes: TemplateNotes {
            var measurements = [
                TemplateMeasurement(title: "Plate", lengths: [width, depth, thickness]),
                TemplateMeasurement(title: "Slots", lengths: [slotLength, slotWidth], text: "long, wide"),
                TemplateMeasurement(title: "Adjustment", lengths: [slotLength - slotWidth], text: "of travel")
            ]
            if columns > 1 || rows > 1 {
                measurements.append(TemplateMeasurement(title: "Slot spacing", lengths: [columns > 1 ? columnPitch : 0, rows > 1 ? rowPitch : 0],
                                                        text: "across, up"))
            }
            return TemplateNotes(measurements: measurements,
                                 hardware: "\(columns * rows) \(TemplateFormat.screw(forHole: slotWidth)) screws, with washers over the slots.",
                                 printing: "Print it flat.")
        }
    }

    // MARK: Keyhole plate

    struct KeyholePlate {
        var width, height, thickness, spacing, entry, neck, travel: Double
        var count: Int
        init(_ values: TemplateValues) {
            width = values["width"]; height = values["height"]; thickness = values["thickness"]; count = values.count("count")
            spacing = values["spacing"]; entry = values["entry"]; neck = values["neck"]; travel = values["travel"]
        }
        /// From the bottom of the entry to the top of the neck.
        var span: Double { entry / 2 + travel + neck / 2 }
        /// The entry's center, with each keyhole centered up the plate.
        var entryY: Double { -span / 2 + entry / 2 }
        /// The biggest head that rests clear of the entry when the screw is at the top of the neck.
        var largestHead: Double { min(entry, 2 * (travel - entry / 2)) }

        func parts() throws -> [TemplatePart] {
            guard entry > neck + 1e-9 else { throw TemplateError.tooSmall("The entry must be wider than the neck, so the screw head goes in and stays.") }
            guard travel >= (entry + neck) / 2 - 1e-9 else {
                throw TemplateError.tooSmall("The screw head would still be over the entry when it reaches the top. Make the slide travel \(TemplateFormat.number((entry + neck) / 2)) mm or more.")
            }
            guard height >= span + 2 * ligament - 1e-9 else {
                throw TemplateError.tooSmall("The keyholes need a plate \(TemplateFormat.number(span + 2 * ligament, digits: 1)) mm tall or more.")
            }
            if count > 1 {
                guard spacing - entry >= ligament - 1e-9 else {
                    throw TemplateError.tooSmall("The keyholes would run into each other. Space them \(TemplateFormat.number(entry + ligament)) mm apart or more.")
                }
            }
            let spanX = Double(count - 1) * spacing + entry + 2 * ligament
            guard width >= spanX - 1e-9 else {
                throw TemplateError.tooSmall("The keyholes need a plate \(TemplateFormat.number(spanX, digits: 1)) mm wide or more. Use fewer or closer keyholes.")
            }
            // Lying flat, up the wall along y: each entry below the neck it slides up into.
            var plate = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: height, radius: min(3, min(width, height) / 4), on: .top),
                                               height: thickness)
            for index in 0..<count {
                let x = (Double(index) - Double(count - 1) / 2) * spacing
                plate.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(entry, at: Point2(x: x, y: entryY), on: .top)))
                plate.cuts.append(TemplateGeometry.through(TemplateGeometry.slot(from: Point2(x: x, y: entryY), to: Point2(x: x, y: entryY + travel),
                                                                                 width: neck, on: .top)))
            }
            return [TemplatePart(name: "Plate", body: plate)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Plate", lengths: [width, height, thickness]),
                TemplateMeasurement(title: "Entry", lengths: [entry]),
                TemplateMeasurement(title: "Neck", lengths: [neck], text: "wide"),
                TemplateMeasurement(title: "Slide travel", lengths: [travel], text: "up from the entry"),
                TemplateMeasurement(title: "Screw heads", lengths: [neck, largestHead], separator: " to ", text: "across (wider than the neck)")
            ], hardware: "\(count) screw\(count == 1 ? "" : "s") left standing out of the wall, heads wider than \(TemplateFormat.number(neck, digits: 1)) mm and up to \(TemplateFormat.number(largestHead, digits: 1)) mm across.",
               printing: "Print it flat. Hang it with the entries at the bottom: lift it over the screw heads, then let it slide down.")
        }
    }
}
