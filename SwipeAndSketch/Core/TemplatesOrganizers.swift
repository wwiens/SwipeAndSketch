import Foundation

/// Drawer & Storage Organizers (October 28, 2026): trays, bins, and dividers sized from the
/// drawer's measured inside, each leaving a gap all round so it drops in.
enum OrganizerTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "organizers.fitted-tray", category: .organizers, title: "Fitted Compartment Tray",
            summary: "Divide a drawer into compartments sized for your space, in one tray that drops in.",
            parameters: availableParameters + [
                perimeterParameter,
                TemplateParameter(id: "columns", title: "Columns", kind: .count(1...8), defaultValue: 3),
                TemplateParameter(id: "rows", title: "Rows", kind: .count(1...8), defaultValue: 2),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 1.6),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 1.6)
            ],
            name: { values in "Drawer Tray \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))" },
            make: { values in try FittedTray(values).parts() },
            notes: { values in FittedTray(values).notes }),
         ProjectTemplate(
            id: "organizers.bin-set", category: .organizers, title: "Removable Bin Set",
            summary: "Fill a drawer with separate bins you can lift out, all sized to fit it together.",
            parameters: availableParameters + [
                TemplateParameter(id: "columns", title: "Columns", kind: .count(1...6), defaultValue: 3),
                TemplateParameter(id: "rows", title: "Rows", kind: .count(1...6), defaultValue: 2),
                perimeterParameter,
                TemplateParameter(id: "spacing", title: "Bin spacing", kind: .length(0.2...3, step: 0.1), defaultValue: 1, note: "Gap between neighboring bins"),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 1.6),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 1.6)
            ],
            name: { values in "Drawer Bins \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in try BinSet(values).parts() },
            notes: { values in BinSet(values).notes }),
         ProjectTemplate(
            id: "organizers.dividers", category: .organizers, title: "Interlocking Drawer Dividers",
            summary: "Make a removable grid of divider strips that slot together inside an existing drawer.",
            parameters: [
                TemplateParameter(id: "width", title: "Drawer width", kind: .length(50...400, step: 1), defaultValue: 200, note: "Inside, side to side"),
                TemplateParameter(id: "depth", title: "Drawer depth", kind: .length(50...400, step: 1), defaultValue: 150, note: "Inside, front to back"),
                TemplateParameter(id: "height", title: "Divider height", kind: .length(10...100, step: 1), defaultValue: 30),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "across", title: "Side-to-side dividers", kind: .count(0...7), defaultValue: 2),
                TemplateParameter(id: "along", title: "Front-to-back dividers", kind: .count(0...7), defaultValue: 1),
                perimeterParameter,
                TemplateParameter(id: "fit", title: "Slot clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of a strip in a slot; starts from the Fit in the project menu")
            ],
            name: { values in "Drawer Dividers \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))" },
            make: { values in try Dividers(values).parts() },
            notes: { values in Dividers(values).notes }),
         ProjectTemplate(
            id: "organizers.pocket-insert", category: .organizers, title: "Cylindrical Pocket Insert",
            summary: "Hold round things upright, such as bits, pens, or batteries, in a block of fitted pockets.",
            parameters: [
                TemplateParameter(id: "width", title: "Outside width", kind: .length(40...300, step: 1), defaultValue: 150),
                TemplateParameter(id: "depth", title: "Outside depth", kind: .length(30...300, step: 1), defaultValue: 100),
                TemplateParameter(id: "height", title: "Height", kind: .length(6...60, step: 1), defaultValue: 18),
                TemplateParameter(id: "object", title: "Object diameter", kind: .length(3...60, step: 0.1), defaultValue: 12, note: "As measured"),
                TemplateParameter(id: "pocketDepth", title: "Pocket depth", kind: .length(3...50, step: 0.5), defaultValue: 14),
                TemplateParameter(id: "columns", title: "Columns", kind: .count(1...12), defaultValue: 5),
                TemplateParameter(id: "rows", title: "Rows", kind: .count(1...8), defaultValue: 3),
                TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the object; starts from the Fit in the project menu")
            ],
            name: { values in "Pocket Insert Ø\(TemplateFormat.number(values["object"]))" },
            make: { values in try PocketInsert(values).parts() },
            notes: { values in PocketInsert(values).notes })]
    }

    static let availableParameters = [
        TemplateParameter(id: "width", title: "Available width", kind: .length(50...400, step: 1), defaultValue: 200, note: "The drawer's inside, side to side"),
        TemplateParameter(id: "depth", title: "Available depth", kind: .length(50...400, step: 1), defaultValue: 150, note: "The drawer's inside, front to back"),
        TemplateParameter(id: "height", title: "Available height", kind: .length(10...100, step: 1), defaultValue: 40,
                          note: "The tray stays 2 mm lower")
    ]
    static let perimeterParameter = TemplateParameter(id: "perimeter", title: "Perimeter clearance", kind: .length(0.1...3, step: 0.1), defaultValue: 0.5,
                                                      note: "Gap left between the drawer and each side")
    /// Room left over the organizer, under whatever closes the drawer.
    static let headroom = 2.0
    static let smallestCompartment = 8.0
    static let outerRadius = 3.0

    // MARK: Fitted tray

    struct FittedTray {
        var width, depth, height, wall, floor: Double
        var columns, rows: Int
        init(_ values: TemplateValues) {
            width = values["width"] - 2 * values["perimeter"]
            depth = values["depth"] - 2 * values["perimeter"]
            height = values["height"] - headroom
            wall = values["wall"]; floor = values["floor"]
            columns = values.count("columns"); rows = values.count("rows")
        }
        var compartment: (width: Double, depth: Double) {
            ((width - Double(columns + 1) * wall) / Double(columns), (depth - Double(rows + 1) * wall) / Double(rows))
        }

        func parts() throws -> [TemplatePart] {
            let cell = compartment
            guard cell.width >= smallestCompartment - 1e-9, cell.depth >= smallestCompartment - 1e-9 else {
                throw TemplateError.tooSmall("Each compartment must be at least 8 × 8 mm inside. Use fewer columns or rows, or thinner walls.")
            }
            // The walls and dividers as one lattice, the compartments holes in it, standing on a
            // floor that reaches halfway into the outer walls.
            let radius = min(outerRadius, min(width, depth) / 4)
            let outline = TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: radius, on: .top)
            let holes = (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    TemplateGeometry.roundedRectangle(center: Point2(x: -width / 2 + wall + cell.width / 2 + Double(column) * (cell.width + wall),
                                                                     y: -depth / 2 + wall + cell.depth / 2 + Double(row) * (cell.depth + wall)),
                                                      width: cell.width, depth: cell.depth, radius: 1, on: .top)
                }
            }
            var tray = TemplateGeometry.block(TemplateGeometry.region(outline, holes: holes), height: height)
            tray.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: width - wall, depth: depth - wall, radius: max(0.5, radius - wall / 2), on: .top),
                                                   depth: floor, join: true))
            return [TemplatePart(name: "Tray", body: tray)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Outside", lengths: [width, depth, height]),
                TemplateMeasurement(title: "Each compartment", lengths: [compartment.width, compartment.depth, height - floor], text: "clear"),
                TemplateMeasurement(title: "Compartments", text: "\(columns * rows)")
            ], printing: "Print it floor down.")
        }
    }

    // MARK: Bin set

    struct BinSet {
        var bin: (width: Double, depth: Double)
        var height, wall, floor, spacing: Double
        var columns, rows: Int
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows")
            spacing = values["spacing"]
            let width = values["width"] - 2 * values["perimeter"], depth = values["depth"] - 2 * values["perimeter"]
            bin = ((width - Double(columns - 1) * spacing) / Double(columns), (depth - Double(rows - 1) * spacing) / Double(rows))
            height = values["height"] - headroom
            wall = values["wall"]; floor = values["floor"]
        }
        var inside: (width: Double, depth: Double) { (bin.width - 2 * wall, bin.depth - 2 * wall) }

        /// "Bin A1": rows lettered from the front, columns numbered from the left.
        static func name(row: Int, column: Int) -> String { "Bin \(Character(UnicodeScalar(UInt8(65 + row))))\(column + 1)" }

        func parts() throws -> [TemplatePart] {
            guard inside.width >= smallestCompartment - 1e-9, inside.depth >= smallestCompartment - 1e-9 else {
                throw TemplateError.tooSmall("Each bin must be at least 8 × 8 mm inside. Use fewer columns or rows, or thinner walls.")
            }
            let radius = min(outerRadius, min(bin.width, bin.depth) / 4)
            let top = TemplateGeometry.horizontal(height)
            return (0..<rows).flatMap { row in
                (0..<columns).map { column -> TemplatePart in
                    let center = Point2(x: (Double(column) - Double(columns - 1) / 2) * (bin.width + spacing),
                                        y: (Double(row) - Double(rows - 1) / 2) * (bin.depth + spacing))
                    var body = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: center, width: bin.width, depth: bin.depth, radius: radius, on: .top),
                                                      height: height)
                    body.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: center, width: inside.width, depth: inside.depth,
                                                                                             radius: max(0.5, radius - wall), on: top), depth: -(height - floor)))
                    return TemplatePart(name: Self.name(row: row, column: column), body: body)
                }
            }
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Each bin", lengths: [bin.width, bin.depth, height]),
                TemplateMeasurement(title: "Inside each", lengths: [inside.width, inside.depth, height - floor]),
                TemplateMeasurement(title: "Bins", text: "\(columns * rows), named by row (A from the front) and column")
            ], printing: "Print the bins open side up.")
        }
    }

    // MARK: Interlocking dividers

    struct Dividers {
        var across: Int, along: Int
        /// The strips' lengths: side to side, and front to back.
        var width, depth: Double
        var height, thickness, fit: Double
        init(_ values: TemplateValues) {
            across = values.count("across"); along = values.count("along")
            width = values["width"] - 2 * values["perimeter"]
            depth = values["depth"] - 2 * values["perimeter"]
            height = values["height"]; thickness = values["thickness"]; fit = values["fit"]
        }
        var slotWidth: Double { thickness + 2 * fit }
        var slotDepth: Double { height / 2 + fit / 2 }
        /// Where the strips cross: along a side-to-side strip (x) and a front-to-back one (y).
        var crossingsX: [Double] { (0..<along).map { -width / 2 + Double($0 + 1) * width / Double(along + 1) } }
        var crossingsY: [Double] { (0..<across).map { -depth / 2 + Double($0 + 1) * depth / Double(across + 1) } }

        func parts() throws -> [TemplatePart] {
            guard across + along > 0 else { throw TemplateError.tooSmall("Add at least one divider.") }
            // At least 2 mm of strip between neighboring slots (and from a slot to a strip's end).
            for (length, slots) in [(width, along), (depth, across)] where slots > 0 {
                guard length / Double(slots + 1) - slotWidth >= 2 - 1e-9 else {
                    throw TemplateError.tooSmall("The slots would leave less than 2 mm of strip between them. Use fewer dividers or thinner strips.")
                }
            }
            // Lying flat, one above the other: side-to-side strips slotted from the top, front-to-back
            // strips from the bottom, so each pair crosses with half of each strip.
            var parts: [TemplatePart] = []
            var y = 0.0
            func strip(_ name: String, length: Double, slots: [Double], fromTop: Bool) {
                var body = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: y + height / 2), width: length, depth: height,
                                                                                    radius: 0, on: .top), height: thickness)
                for x in slots {
                    let center = Point2(x: x, y: fromTop ? y + height - slotDepth / 2 + 0.5 : y + slotDepth / 2 - 0.5)
                    body.cuts.append(TemplateGeometry.through(TemplateGeometry.roundedRectangle(center: center, width: slotWidth, depth: slotDepth + 1,
                                                                                                radius: 0, on: .top)))
                }
                parts.append(TemplatePart(name: name, body: body))
                y += height + 5
            }
            for index in 0..<across { strip("Side-to-Side Divider \(index + 1)", length: width, slots: crossingsX, fromTop: true) }
            for index in 0..<along { strip("Front-to-Back Divider \(index + 1)", length: depth, slots: crossingsY, fromTop: false) }
            return parts
        }

        var notes: TemplateNotes {
            let cellWidth = (width - Double(along) * thickness) / Double(along + 1)
            let cellDepth = (depth - Double(across) * thickness) / Double(across + 1)
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Assembled", lengths: [width, depth, height]),
                TemplateMeasurement(title: "Strips", text: "\(across) side to side, \(along) front to back"),
                TemplateMeasurement(title: "Slots", lengths: [slotWidth, slotDepth], text: "wide, deep"),
                TemplateMeasurement(title: "Each compartment", lengths: [cellWidth, cellDepth], text: "about")
            ], printing: "Print the strips lying flat. Stand the side-to-side strips slots up and press the front-to-back strips down onto them.")
        }
    }

    // MARK: Pocket insert

    struct PocketInsert {
        var width, depth, height, object, pocketDepth, fit: Double
        var columns, rows: Int
        init(_ values: TemplateValues) {
            width = values["width"]; depth = values["depth"]; height = values["height"]; object = values["object"]
            pocketDepth = values["pocketDepth"]; fit = values["fit"]
            columns = values.count("columns"); rows = values.count("rows")
        }
        var pocket: Double { object + 2 * fit }
        var pitch: (x: Double, y: Double) { (width / Double(columns), depth / Double(rows)) }

        func parts() throws -> [TemplatePart] {
            guard height - pocketDepth >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("Leave at least 2 mm under the pockets: make the insert \(TemplateFormat.number(pocketDepth + 2)) mm tall or more, or the pockets shallower.")
            }
            // Pockets spread evenly, each in its own share of the block, with 2 mm round each.
            guard pitch.x - pocket >= 4 - 1e-9, pitch.y - pocket >= 4 - 1e-9 else {
                throw TemplateError.tooSmall("The pockets would leave less than 2 mm between them or at the edges. Use fewer columns or rows, or a bigger insert.")
            }
            let radius = min(outerRadius, min(width, depth) / 4)
            var insert = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: radius, on: .top), height: height - pocketDepth)
            let plane = TemplateGeometry.horizontal(height - pocketDepth)
            let pockets = (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    TemplateGeometry.circle(pocket, at: Point2(x: (Double(column) - Double(columns - 1) / 2) * pitch.x,
                                                               y: (Double(row) - Double(rows - 1) / 2) * pitch.y), on: plane, points: 48)
                }
            }
            insert.cuts.append(TemplateGeometry.step(TemplateGeometry.region(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: radius, on: plane),
                                                                             holes: pockets), depth: pocketDepth, join: true))
            return [TemplatePart(name: "Insert", body: insert)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Outside", lengths: [width, depth, height]),
                TemplateMeasurement(title: "Pockets", lengths: [pocket], text: "across, \(TemplateFormat.number(pocketDepth)) mm deep"),
                TemplateMeasurement(title: "Spacing", lengths: [pitch.x, pitch.y], text: "center to center"),
                TemplateMeasurement(title: "Pocket count", text: "\(columns * rows)")
            ], printing: "Print it pockets up.")
        }
    }
}
