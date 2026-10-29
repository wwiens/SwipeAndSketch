import Foundation

/// A board's outline and mounting holes, from its published mechanical drawing. Coordinates run
/// from the board's lower-left corner (the long side along x).
struct BoardFootprint: Sendable {
    var title: String
    /// For project and group names ("Case for Raspberry Pi"): another maker's board is named only
    /// after "for", as their trademark rules ask (October 26, 2026).
    var shortTitle: String
    var width: Double
    var length: Double
    var holes: [Point2]
    var holeDiameter: Double
    /// The screw its holes take: "M2", "M2.5", or "M3".
    var screw: String
    /// Room a case leaves above the board by default, for its tallest parts.
    var headroom: Double

    /// Raspberry Pi 5, 4 Model B, and 3 Model B/B+ share this outline and hole pattern (58 × 49 mm).
    static let piModelB = BoardFootprint(title: "Raspberry Pi 5 / 4 / 3 Model B", shortTitle: "Raspberry Pi", width: 85, length: 56,
                                         holes: corners(3.5, 3.5, 61.5, 52.5), holeDiameter: 2.7, screw: "M2.5", headroom: 20)
    /// Raspberry Pi Zero, Zero W, and Zero 2 W (58 × 23 mm).
    static let piZero = BoardFootprint(title: "Raspberry Pi Zero / Zero 2 W", shortTitle: "Raspberry Pi Zero", width: 65, length: 30,
                                       holes: corners(3.5, 3.5, 61.5, 26.5), holeDiameter: 2.7, screw: "M2.5", headroom: 8)
    /// Raspberry Pi Pico, Pico W, and Pico 2 (47 × 11.4 mm, 2 mm from the short ends).
    static let pico = BoardFootprint(title: "Raspberry Pi Pico", shortTitle: "Raspberry Pi Pico", width: 51, length: 21,
                                     holes: corners(2, 4.8, 49, 16.2), holeDiameter: 2.1, screw: "M2", headroom: 6)
    /// Arduino Uno R3 and R4: four holes, not in a rectangle.
    static let arduinoUno = BoardFootprint(title: "Arduino Uno", shortTitle: "Arduino Uno", width: 68.6, length: 53.3,
                                           holes: [Point2(x: 13.97, y: 2.54), Point2(x: 15.24, y: 50.8), Point2(x: 66.04, y: 7.62), Point2(x: 66.04, y: 35.56)],
                                           holeDiameter: 3.2, screw: "M3", headroom: 16)

    static let catalog: [BoardFootprint] = [.piModelB, .piZero, .pico, .arduinoUno]

    /// A name for a `part` made for this board: "Case for Raspberry Pi", or "Board Case" for a custom one.
    func named(_ part: String) -> String { shortTitle == "Board" ? "Board \(part)" : "\(part) for \(shortTitle)" }

    private static func corners(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Point2] {
        [Point2(x: x0, y: y0), Point2(x: x1, y: y0), Point2(x: x1, y: y1), Point2(x: x0, y: y1)]
    }

    /// A board of the custom sizes: four holes `inset` from each corner.
    static func custom(width: Double, length: Double, inset: Double, screw: String) -> BoardFootprint {
        let inset = min(inset, min(width, length) / 2 - 1)
        return BoardFootprint(title: "Custom board", shortTitle: "Board", width: width, length: length,
                              holes: corners(inset, inset, width - inset, length - inset),
                              holeDiameter: Screws.clearance(screw), screw: screw, headroom: 15)
    }
}

/// Holes for the small metric screws boards take.
enum Screws {
    static let sizes = ["M2", "M2.5", "M3"]
    /// A free fit for the screw.
    static func clearance(_ screw: String) -> Double { ["M2": 2.4, "M2.5": 2.9, "M3": 3.4][screw] ?? 3.4 }
    /// A hole a screw cuts its own thread into, in printed plastic.
    static func pilot(_ screw: String) -> Double { ["M2": 1.7, "M2.5": 2.1, "M3": 2.6, "M4": 3.4][screw] ?? 2.6 }

    /// How a screw holds in a printed standoff or boss.
    enum Fixing: Int, CaseIterable, Sendable {
        case selfTapping, insert, through
        var title: String {
            switch self { case .selfTapping: "Screw into plastic"; case .insert: "Heat-set insert"; case .through: "Through with a nut" }
        }
    }

    /// The hole for `screw` held by `fixing`, and how deep it may go in `available` millimeters of
    /// material (nil: through).
    static func hole(_ screw: String, _ fixing: Fixing, available: Double) -> (spec: HoleSpec, depth: Double?) {
        switch fixing {
        case .selfTapping:
            return (TemplateGeometry.plainHole(pilot(screw), label: "\(screw) pilot"), max(1, available - 0.8))
        case .insert where HolePresets.sizes.contains(screw):
            let depth = HolePresets.defaultDepth(.insert, size: screw) ?? 6
            return (HolePresets.spec(.insert, size: screw), max(1, min(depth, available - 0.8)))
        case .insert:
            return (TemplateGeometry.plainHole(pilot(screw), label: "\(screw) pilot"), max(1, available - 0.8))
        case .through:
            return (HolePresets.spec(.simple, size: screw), nil)
        }
    }
}

/// Mounting plates and cases for electronics boards.
enum BoardTemplates {
    static var templates: [ProjectTemplate] {
        [mount(id: "electronics.pi-mount", board: 0, title: "Mount for Raspberry Pi",
               summary: "A plate with standoffs on the Raspberry Pi's mounting holes, and countersunk holes to screw it to a wall or shelf."),
         enclosure(id: "electronics.pi-case", board: 0, title: "Case for Raspberry Pi",
                   summary: "A case with standoffs for the board and a lid that presses on. Cut openings for its ports with Sketch and Extrude."),
         enclosure(id: "electronics.pi-zero-case", board: 1, title: "Case for Raspberry Pi Zero",
                   summary: "A slim case for a Raspberry Pi Zero, with standoffs and a press-on lid."),
         mount(id: "electronics.pico-mount", board: 2, title: "Mount for Raspberry Pi Pico",
               summary: "A small plate with standoffs on the Raspberry Pi Pico's holes, for M2 screws."),
         mount(id: "electronics.arduino-mount", board: 3, title: "Mount for Arduino Uno",
               summary: "A plate with standoffs on the Arduino Uno's four holes."),
         enclosure(id: "electronics.arduino-case", board: 3, title: "Case for Arduino Uno",
                   summary: "A case with standoffs for an Arduino Uno and a press-on lid. Cut openings for USB and power with Sketch and Extrude."),
         enclosure(id: "electronics.custom-case", board: BoardFootprint.catalog.count, title: "Custom Board Case",
                   summary: "A case for any board: enter its size and how far its four holes are from the corners."),
         prototypeTray]
    }

    static var boardChoices: [String] { BoardFootprint.catalog.map(\.title) + ["Custom board"] }

    /// The board parameters every electronics template starts with.
    static func boardParameters(_ board: Int) -> [TemplateParameter] {
        let isCustom: @Sendable (TemplateValues) -> Bool = { $0.choice("board") == BoardFootprint.catalog.count }
        return [
            TemplateParameter(id: "board", title: "Board", kind: .choice(boardChoices), defaultValue: Double(board)),
            TemplateParameter(id: "boardWidth", title: "Board width", kind: .length(10...300, step: 1), defaultValue: 70, isShown: isCustom),
            TemplateParameter(id: "boardLength", title: "Board depth", kind: .length(10...300, step: 1), defaultValue: 50, isShown: isCustom),
            TemplateParameter(id: "holeInset", title: "Holes from corners", kind: .length(2...30, step: 0.5), defaultValue: 3.5,
                              note: "From each edge to the hole's center", isShown: isCustom),
            TemplateParameter(id: "screw", title: "Screw", kind: .choice(Screws.sizes), defaultValue: 1, isShown: isCustom),
            TemplateParameter(id: "fixing", title: "Screws hold by", kind: .choice(Screws.Fixing.allCases.map(\.title)), defaultValue: 0)
        ]
    }

    static func footprint(_ values: TemplateValues) -> BoardFootprint {
        let index = values.choice("board")
        if BoardFootprint.catalog.indices.contains(index) { return BoardFootprint.catalog[index] }
        return .custom(width: values["boardWidth"], length: values["boardLength"], inset: values["holeInset"],
                       screw: Screws.sizes[min(max(values.choice("screw"), 0), Screws.sizes.count - 1)])
    }

    static func fixing(_ values: TemplateValues) -> Screws.Fixing { Screws.Fixing(rawValue: values.choice("fixing")) ?? .selfTapping }

    // MARK: Mounting plate

    static func mount(id: String, board: Int, title: String, summary: String) -> ProjectTemplate {
        ProjectTemplate(
            id: id, category: .electronics, title: title, summary: summary,
            parameters: boardParameters(board) + [
                TemplateParameter(id: "standoff", title: "Standoff height", kind: .length(2...30, step: 0.5), defaultValue: 5,
                                  note: "Room under the board for pins and wires"),
                TemplateParameter(id: "margin", title: "Margin", kind: .length(2...40, step: 1), defaultValue: 8, note: "Plate beyond the board on each side"),
                TemplateParameter(id: "thickness", title: "Plate thickness", kind: .length(1.6...10, step: 0.2), defaultValue: 3),
                TemplateParameter(id: "mountingHoles", title: "Mounting holes", kind: .toggle, defaultValue: 1,
                                  note: "Countersunk M3 holes in the plate's corners")
            ],
            name: { values in footprint(values).named("Mount") },
            make: { values in
                [TemplatePart(name: "Mount", body: try mountingPlate(footprint(values), fixing: fixing(values), standoff: values["standoff"],
                                                                     margin: values["margin"], thickness: values["thickness"],
                                                                     mountingHoles: values.flag("mountingHoles")))]
            })
    }

    static func standoffDiameter(_ board: BoardFootprint, _ fixing: Screws.Fixing) -> Double {
        let hole = Screws.hole(board.screw, fixing, available: 10).spec.diameter
        return max(board.holeDiameter + 3, hole + 2.4, 5)
    }

    /// The board's holes in world coordinates, with the board centered on `center`.
    static func holes(of board: BoardFootprint, centeredOn center: Point2) -> [Point2] {
        board.holes.map { center + $0 - Point2(x: board.width / 2, y: board.length / 2) }
    }

    /// Standoffs standing on `floor` (a horizontal plane height) under the board's holes, each with
    /// its screw hole going down into the material under it too.
    static func standoffs(_ board: BoardFootprint, at center: Point2, floor: Double, height: Double, below: Double, fixing: Screws.Fixing) -> [ExtrusionCut] {
        let diameter = standoffDiameter(board, fixing)
        let base = TemplateGeometry.horizontal(floor), top = TemplateGeometry.horizontal(floor + height)
        let points = holes(of: board, centeredOn: center)
        var steps = points.map { TemplateGeometry.step(TemplateGeometry.circle(diameter, at: $0, on: base), depth: height, join: true) }
        let (spec, depth) = Screws.hole(board.screw, fixing, available: height + below)
        steps += points.map { TemplateGeometry.hole(spec, at: $0, on: top, depth: depth) }
        return steps
    }

    static func mountingPlate(_ board: BoardFootprint, fixing: Screws.Fixing, standoff: Double, margin: Double, thickness: Double,
                              mountingHoles: Bool) throws -> SolidBody {
        let width = board.width + 2 * margin, depth = board.length + 2 * margin
        var body = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: min(4, margin), on: .top), height: thickness)
        var steps = standoffs(board, at: .zero, floor: thickness, height: standoff, below: thickness, fixing: fixing)
        if mountingHoles {
            let spec = HolePresets.spec(.countersink, size: "M3")
            let inset = min(5, margin / 2 + 1)
            let top = TemplateGeometry.horizontal(thickness)
            for sx in [-1.0, 1] { for sy in [-1.0, 1] {
                steps.append(TemplateGeometry.hole(spec, at: Point2(x: sx * (width / 2 - inset), y: sy * (depth / 2 - inset)), on: top, depth: nil))
            } }
        }
        body.cuts = steps
        return body
    }

    // MARK: Case

    static func enclosure(id: String, board: Int, title: String, summary: String) -> ProjectTemplate {
        ProjectTemplate(
            id: id, category: .electronics, title: title, summary: summary,
            parameters: boardParameters(board) + [
                TemplateParameter(id: "headroom", title: "Room above the board", kind: .length(3...80, step: 1),
                                  defaultValue: BoardFootprint.catalog.indices.contains(board) ? BoardFootprint.catalog[board].headroom : 15,
                                  note: "For its tallest connectors"),
                TemplateParameter(id: "standoff", title: "Standoff height", kind: .length(2...20, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "gap", title: "Space around the board", kind: .length(0.5...20, step: 0.5), defaultValue: 2),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.2...5, step: 0.2), defaultValue: 2),
                TemplateParameter(id: "fit", title: "Lid fit", kind: .length(0.05...0.6, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the lid's rim; starts from the Fit in the project menu"),
                TemplateParameter(id: "vents", title: "Vent slots", kind: .toggle, defaultValue: board == 0 ? 1 : 0),
                TemplateParameter(id: "notch", title: "Cable notch", kind: .toggle, defaultValue: 0, note: "An opening at the top of one end wall")
            ],
            name: { values in footprint(values).named("Case") },
            make: { values in
                let board = footprint(values)
                let boardThickness = 1.6
                let inside = BoxTemplates.Inside(width: board.width + 2 * values["gap"], depth: board.length + 2 * values["gap"],
                                                 height: values["standoff"] + boardThickness + values["headroom"])
                let box = BoxTemplates.SlipLidBox(inside: inside, wall: values["wall"], floor: 2, radius: values["wall"] + 2,
                                                  fit: values["fit"], vents: values.flag("vents"), notch: values.flag("notch"))
                var parts = try box.parts(caseName: "Case")
                parts[0].body.cuts += standoffs(board, at: box.boxCenter, floor: box.floor, height: values["standoff"], below: box.floor,
                                                fixing: fixing(values))
                return parts
            })
    }

    // MARK: Prototyping tray (October 28, 2026, second expansion)

    static var prototypeTray: ProjectTemplate {
        ProjectTemplate(
            id: "electronics.prototype-tray", category: .electronics, title: "Electronics Prototyping Tray",
            summary: "Mount several boards of one size on an open tray, each on four standoffs.",
            parameters: [
                TemplateParameter(id: "width", title: "Tray width", kind: .length(80...300, step: 1), defaultValue: 180),
                TemplateParameter(id: "depth", title: "Tray depth", kind: .length(50...220, step: 1), defaultValue: 100),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "rim", title: "Rim height", kind: .length(0...12, step: 1), defaultValue: 5, note: "Above the floor; 0 for none"),
                TemplateParameter(id: "rimThickness", title: "Rim thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "columns", title: "Board columns", kind: .count(1...3), defaultValue: 2),
                TemplateParameter(id: "rows", title: "Board rows", kind: .count(1...3), defaultValue: 1),
                TemplateParameter(id: "boardWidth", title: "Board width", kind: .length(20...120, step: 0.5), defaultValue: 70),
                TemplateParameter(id: "boardDepth", title: "Board depth", kind: .length(15...100, step: 0.5), defaultValue: 45),
                TemplateParameter(id: "holeInset", title: "Holes from corners", kind: .length(2...15, step: 0.5), defaultValue: 3.5,
                                  note: "From each edge to the hole's center"),
                TemplateParameter(id: "columnPitch", title: "Board spacing across", kind: .length(25...150, step: 1), defaultValue: 80, note: "Center to center"),
                TemplateParameter(id: "rowPitch", title: "Board spacing front to back", kind: .length(20...120, step: 1), defaultValue: 60,
                                  note: "Center to center"),
                TemplateParameter(id: "standoff", title: "Standoff height", kind: .length(4...15, step: 0.5), defaultValue: 6),
                TemplateParameter(id: "standoffDiameter", title: "Standoff diameter", kind: .length(5...12, step: 0.5), defaultValue: 7),
                TemplateParameter(id: "screw", title: "Screw", kind: .choice(Screws.sizes), defaultValue: 2),
                TemplateParameter(id: "fixing", title: "Screws hold by", kind: .choice([Screws.Fixing.selfTapping.title, Screws.Fixing.insert.title]),
                                  defaultValue: 0)
            ],
            name: { values in "Prototyping Tray \(values.count("columns") * values.count("rows")) Boards" },
            make: { values in [TemplatePart(name: "Tray", body: try PrototypeTray(values).body())] },
            notes: { values in PrototypeTray(values).notes })
    }

    struct PrototypeTray {
        var width, depth, floor, rim, rimThickness, columnPitch, rowPitch, standoff, standoffDiameter: Double
        var columns, rows: Int
        var board: BoardFootprint
        var fixing: Screws.Fixing
        init(_ values: TemplateValues) {
            width = values["width"]; depth = values["depth"]; floor = values["floor"]; rim = values["rim"]; rimThickness = values["rimThickness"]
            columns = values.count("columns"); rows = values.count("rows"); columnPitch = values["columnPitch"]; rowPitch = values["rowPitch"]
            standoff = values["standoff"]; standoffDiameter = values["standoffDiameter"]
            let screw = Screws.sizes[min(max(values.choice("screw"), 0), Screws.sizes.count - 1)]
            board = BoardFootprint(title: "Board", shortTitle: "Board", width: values["boardWidth"], length: values["boardDepth"],
                                   holes: [Point2(x: values["holeInset"], y: values["holeInset"]), Point2(x: values["boardWidth"] - values["holeInset"], y: values["holeInset"]),
                                           Point2(x: values["boardWidth"] - values["holeInset"], y: values["boardDepth"] - values["holeInset"]),
                                           Point2(x: values["holeInset"], y: values["boardDepth"] - values["holeInset"])],
                                   holeDiameter: Screws.clearance(screw), screw: screw, headroom: 0)
            fixing = values.choice("fixing") == 1 ? .insert : .selfTapping
        }
        var boards: [Point2] {
            (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    Point2(x: (Double(column) - Double(columns - 1) / 2) * columnPitch, y: (Double(row) - Double(rows - 1) / 2) * rowPitch)
                }
            }
        }
        /// The bore in each standoff: as deep as it may go, keeping 1 mm at the standoff's foot.
        var bore: (spec: HoleSpec, depth: Double?) { Screws.hole(board.screw, fixing, available: standoff - 1 + 0.8) }

        func body() throws -> SolidBody {
            let inset = board.holes[0].x
            guard inset >= standoffDiameter / 2 - 1e-9, inset <= min(board.width, board.length) / 2 - standoffDiameter / 2 + 1e-9 else {
                throw TemplateError.tooSmall("The holes must sit at least half a standoff (\(TemplateFormat.number(standoffDiameter / 2, digits: 1)) mm) in from the board's edges, and the four mustn't overlap.")
            }
            let spec = bore.spec
            guard (standoffDiameter - spec.diameter) / 2 >= 1.2 - 1e-9 else {
                throw TemplateError.tooSmall("The standoffs are too thin round their \(TemplateFormat.number(spec.diameter, digits: 1)) mm holes. Make them \(TemplateFormat.number(spec.diameter + 2.4, digits: 1)) mm across or more.")
            }
            if fixing == .insert, let needed = HolePresets.defaultDepth(.insert, size: board.screw), standoff - 1 < needed - 1e-9 {
                throw TemplateError.tooSmall("A \(board.screw) insert needs \(TemplateFormat.number(needed, digits: 1)) mm of standoff. Make the standoffs \(TemplateFormat.number(needed + 1, digits: 1)) mm tall or more, or have the screws hold by screwing into plastic.")
            }
            guard columns < 2 || columnPitch >= board.width - 1e-9, rows < 2 || rowPitch >= board.length - 1e-9 else {
                throw TemplateError.tooSmall("The boards would overlap. Space them at least a board's size apart.")
            }
            let inside = (width: width - 2 * (rim > 0 ? rimThickness : 0), depth: depth - 2 * (rim > 0 ? rimThickness : 0))
            let span = (x: Double(columns - 1) * columnPitch + board.width, y: Double(rows - 1) * rowPitch + board.length)
            guard span.x <= inside.width + 1e-9, span.y <= inside.depth + 1e-9 else {
                throw TemplateError.tooSmall("The boards need \(TemplateFormat.number(span.x, digits: 1)) × \(TemplateFormat.number(span.y, digits: 1)) mm inside the rim. Make the tray bigger, or use fewer or closer boards.")
            }
            var tray = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: 3, on: .top), height: floor + rim)
            if rim > 0 {
                tray.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: inside.width, depth: inside.depth, radius: max(0.5, 3 - rimThickness),
                                                                                         on: TemplateGeometry.horizontal(floor + rim)), depth: -rim))
            }
            let base = TemplateGeometry.horizontal(floor), top = TemplateGeometry.horizontal(floor + standoff)
            let points = boards.flatMap { holes(of: board, centeredOn: $0) }
            for point in points { tray.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(standoffDiameter, at: point, on: base, points: 48), depth: standoff, join: true)) }
            let (holeSpec, holeDepth) = bore
            for point in points { tray.cuts.append(TemplateGeometry.hole(holeSpec, at: point, on: top, depth: holeDepth)) }
            return tray
        }

        var notes: TemplateNotes {
            let count = boards.count * 4
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Tray", lengths: [width, depth, floor + rim]),
                TemplateMeasurement(title: "Boards", lengths: [board.width, board.length], text: "\(columns) × \(rows)"),
                TemplateMeasurement(title: "Holes", lengths: [board.width - 2 * board.holes[0].x, board.length - 2 * board.holes[0].x], text: "apart on each board"),
                TemplateMeasurement(title: "Standoffs", lengths: [standoffDiameter, standoff], text: "across, tall")
            ], hardware: "\(count) \(board.screw) screws" + (fixing == .insert ? " and \(count) \(board.screw) heat-set inserts." : "."),
               printing: "Print it floor down.")
        }
    }
}
