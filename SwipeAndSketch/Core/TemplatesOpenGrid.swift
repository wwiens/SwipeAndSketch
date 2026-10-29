import Foundation
import simd

/// openGrid (October 29, 2026; openGrid by David D, CC BY 4.0): boards rebuilt from the
/// published profile, openGrid's official connectors, mounts, and M3 nut snaps (OpenGridGeometry.swift),
/// a fit test, and accessories of Swipe & Sketch's own design that screw to Metric Screw Snaps.
/// The templates with openGrid's own parts are free (user decision, October 29, 2026), since its
/// license lets anyone use them; the accessories are Pro and leave the snaps to the free set.
enum OpenGridTemplates {
    static var templates: [ProjectTemplate] {
        [board, connectorPegs, mountingSnaps, screwSnaps, mountingPlate, hook, shelf, bin, cableGuide, cableTray, toolRack,
         gridfinityShelf, fitTest]
    }

    static let pitch = OpenGrid.pitch

    static var boardParameter: TemplateParameter {
        TemplateParameter(id: "board", title: "Board", kind: .choice(["Full", "Lite"]), defaultValue: 0,
                          note: "Full boards are 6.8 mm thick, Lite boards 4 mm")
    }

    static var familyParameter: TemplateParameter {
        TemplateParameter(id: "family", title: "Snap", kind: .choice(["Normal", "Directional"]), defaultValue: 1,
                          note: "Directional snaps hold firmer on a wall; they go in arrow side up")
    }

    static func boardType(_ values: TemplateValues) -> OpenGrid.BoardType { values.choice("board") == 1 ? .lite : .full }

    /// openGrid's printing guide, credited as its suggestion rather than something tested here.
    static let printSettings = "openGrid's guide suggests a 0.4 mm nozzle, 0.2 mm layers, 15% infill or more, and 3 walls, in PLA or PETG; print a small test first."

    /// `count` spots for parts `size` apart (plus a gap), in rows, centered on the origin.
    static func layout(_ count: Int, size: (x: Double, y: Double), gap: Double = 5) -> [SIMD3<Double>] {
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up))), rows = (count + columns - 1) / columns
        let dx = size.x + gap, dy = size.y + gap
        return (0..<count).map { index in
            SIMD3((Double(index % columns) - Double(columns - 1) / 2) * dx, (Double(rows - 1) / 2 - Double(index / columns)) * dy, 0)
        }
    }

    /// Copies of an official part, laid out and named "\(name) 1", "\(name) 2", ….
    static func copies(of part: OpenGridPart, count: Int, name: String, gap: Double = 5) throws -> [TemplatePart] {
        let shape = try part.shape
        let solid = try ImportedShapes.shared.solid(registering: shape)
        let size = solid.bounds.max - solid.bounds.min
        return try layout(count, size: (size.x, size.y), gap: gap).enumerated().map { index, spot in
            TemplatePart(name: count == 1 ? name : "\(name) \(index + 1)", body: try OpenGrid.body(shape, at: spot), shape: shape)
        }
    }

    // MARK: Board

    static var board: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.board", category: .opengrid, title: "Board",
            summary: "Build a mounting board sized for your wall or desk.",
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(1...10), defaultValue: 6, note: "Cells across, 28 mm each"),
                TemplateParameter(id: "rows", title: "Height", kind: .count(1...10), defaultValue: 6, note: "Cells up"),
                boardParameter,
                TemplateParameter(id: "pocketsTop", title: "Connector pockets, top", kind: .toggle, defaultValue: 1,
                                  note: "Pockets between the cells for the pegs that join it to the next board"),
                TemplateParameter(id: "pocketsBottom", title: "Connector pockets, bottom", kind: .toggle, defaultValue: 1),
                TemplateParameter(id: "pocketsLeft", title: "Connector pockets, left", kind: .toggle, defaultValue: 1),
                TemplateParameter(id: "pocketsRight", title: "Connector pockets, right", kind: .toggle, defaultValue: 1),
                TemplateParameter(id: "screwHoles", title: "Screw holes", kind: .toggle, defaultValue: 1,
                                  note: "Countersunk, at every inner grid corner, as on openGrid's Lite boards",
                                  isShown: { $0.choice("board") == 1 })
            ],
            name: { values in
                "openGrid \(boardType(values) == .lite ? "Lite " : "")Board \(values.count("columns")) × \(values.count("rows"))"
            },
            make: { values in
                let board = BoardLayout(values)
                let shape = try OpenGrid.boardShape(columns: board.columns, rows: board.rows, type: board.type, pockets: board.pockets,
                                                    screwHoles: board.screwHoles)
                return [TemplatePart(name: "Board", body: try OpenGrid.body(shape, at: .zero), shape: shape)]
            },
            needsPro: false,
            notes: { values in BoardLayout(values).notes })
    }

    struct BoardLayout {
        var columns, rows: Int
        var type: OpenGrid.BoardType
        var pockets: Set<OpenGrid.Edge>
        var screwHoles: Bool
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); type = boardType(values)
            let flags: [(OpenGrid.Edge, String)] = [(.top, "pocketsTop"), (.bottom, "pocketsBottom"), (.left, "pocketsLeft"), (.right, "pocketsRight")]
            pockets = Set(flags.filter { values.flag($0.1) }.map(\.0))
            screwHoles = type == .lite && values.flag("screwHoles")
        }
        /// Pockets only go between cells, as on the official boards.
        var pocketCount: Int {
            pockets.reduce(0) { $0 + (($1.isHorizontal ? columns : rows) - 1) }
        }
        var holeCount: Int { screwHoles ? (columns - 1) * (rows - 1) : 0 }

        var notes: TemplateNotes {
            let width = Double(columns) * pitch, height = Double(rows) * pitch
            var measurements = [
                TemplateMeasurement(title: "Outside", lengths: [width, height, type.thickness]),
                TemplateMeasurement(title: "Snap openings", text: "\(columns * rows), on a 28 mm grid")
            ]
            if pocketCount > 0 { measurements.append(TemplateMeasurement(title: "Connector pockets", text: "\(pocketCount)")) }
            if holeCount > 0 { measurements.append(TemplateMeasurement(title: "Screw holes", lengths: [4.1], text: "\(holeCount), countersunk")) }
            var hardware: String
            switch type {
            case .full:
                hardware = "Mount it with the Board Mounting Snap Set: snaps that fit its cells from the front, and countersunk screws through them."
            case .lite where holeCount > 0:
                hardware = "\(holeCount) countersunk screws no thicker than 4 mm, with heads up to 7.2 mm across, and wall plugs to suit the wall. Lite mounting snaps can add more points."
            case .lite:
                hardware = "This board has no inner grid corners, so no screw holes: mount it with Lite snaps from the Board Mounting Snap Set."
            }
            if pocketCount > 0 { hardware += " Join it to the next board with the Board Connector Peg Set." }
            let bed = width > 250 || height > 250 ? " It's wider than most print beds; several smaller boards joined with pegs may suit better." : ""
            let face = type == .lite ? "front face (the chamfered one) down, as openGrid's own Lite files are laid out" : "on either face; a Full board is the same both ways"
            return TemplateNotes(measurements: measurements, hardware: hardware, printing: "Print it flat, \(face).\(bed) \(printSettings)")
        }
    }

    // MARK: Connector pegs

    static var connectorPegs: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.connector-pegs", category: .opengrid, title: "Board Connector Peg Set",
            summary: "Print matching pegs for neighboring board edges.",
            parameters: [
                boardParameter,
                TemplateParameter(id: "count", title: "Quantity", kind: .count(1...48), defaultValue: 12)
            ],
            name: { values in "openGrid \(boardType(values).title) Connectors" },
            make: { values in
                try copies(of: boardType(values) == .full ? .connector : .liteConnector, count: values.count("count"), name: "Connector", gap: 4)
            },
            needsPro: false,
            notes: { values in
                let part: OpenGridPart = boardType(values) == .full ? .connector : .liteConnector
                let size = (try? ImportedShapes.shared.solid(registering: part.shape)).map { $0.bounds.max - $0.bounds.min } ?? .zero
                return TemplateNotes(measurements: [
                    TemplateMeasurement(title: "Each connector", lengths: [size.x, size.y, size.z]),
                    TemplateMeasurement(title: "For", text: "\(boardType(values).title) boards' edge pockets")
                ], hardware: nil,
                printing: "Print them flat, as laid out. Push a connector into every pocket along one board's edge, then press the next board on. They line boards up; each board still needs its own mounting.")
            })
    }

    // MARK: Mounting snaps

    static var mountingSnaps: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.mounting-snaps", category: .opengrid, title: "Board Mounting Snap Set",
            summary: "Make screw-through mounts for attaching a board to a surface.",
            parameters: [
                boardParameter,
                TemplateParameter(id: "count", title: "Quantity", kind: .count(1...24), defaultValue: 4),
                TemplateParameter(id: "style", title: "Screw head", kind: .choice(["Exposed", "Covered"]), defaultValue: 0,
                                  note: "Covered mounts take a cover that hides the screw", isShown: { $0.choice("board") == 0 })
            ],
            name: { values in "openGrid \(boardType(values).title) Mounting Snaps" },
            make: { values in
                let count = values.count("count")
                switch (boardType(values), values.choice("style")) {
                case (.lite, _): return try copies(of: .liteWallMount, count: count, name: "Mount")
                case (.full, 0): return try copies(of: .wallMount, count: count, name: "Mount")
                case (.full, _):
                    // Each mount with its cover beside it.
                    let mounts = try copies(of: .openWallMount, count: count, name: "Mount", gap: 33)
                    let cover = try OpenGridPart.openWallMountCover.shape
                    return try mounts.enumerated().flatMap { index, mount in
                        let spot = mount.body.profile.plane.origin + SIMD3(29, 0, 0)
                        return [mount, TemplatePart(name: count == 1 ? "Cover" : "Cover \(index + 1)", body: try OpenGrid.body(cover, at: spot), shape: cover)]
                    }
                }
            },
            needsPro: false,
            notes: { values in
                let count = values.count("count"), covered = boardType(values) == .full && values.choice("style") == 1
                return TemplateNotes(measurements: [
                    TemplateMeasurement(title: "Screw hole", lengths: [4.1], text: "with a 90° countersink 7.3 mm across"),
                    TemplateMeasurement(title: "Parts", text: covered ? "\(count) mounts and \(count) covers" : "\(count) mounts")
                ], hardware: "\(count) countersunk screws no thicker than 4 mm, with heads up to 7.3 mm across, and wall plugs or anchors chosen for the wall.",
                printing: "Print them flat side down, as laid out. Press each into a cell from the front of the board and screw through it into the wall\(covered ? ", then press its cover in" : ""). \(printSettings)")
            })
    }

    // MARK: Screw snaps

    static var screwSnaps: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.screw-snaps", category: .opengrid, title: "Metric Screw Snap Set",
            summary: "Create removable screw attachment points for your accessories.",
            parameters: [
                boardParameter,
                familyParameter,
                TemplateParameter(id: "count", title: "Quantity", kind: .count(1...24), defaultValue: 4)
            ],
            name: { values in "openGrid \(boardType(values).title) M3 Screw Snaps" },
            make: { values in
                try copies(of: .screwSnap(boardType(values), directional: values.choice("family") == 1), count: values.count("count"), name: "Screw Snap")
            },
            needsPro: false,
            notes: { values in
                let type = boardType(values), count = values.count("count"), depth = SnapScrews(type: type, plate: 0).snapDepth
                return TemplateNotes(measurements: [
                    TemplateMeasurement(title: "Nut pocket", lengths: [5.5, 2.4], text: "across flats × deep, in the back"),
                    TemplateMeasurement(title: "Screw hole", lengths: [3.4]),
                    TemplateMeasurement(title: "Snap", lengths: [depth], text: "thick")
                ], hardware: "\(count) M3 nuts, pressed into the backs, and M3 screws as long as the accessory is thick plus \(TemplateFormat.number(depth - 0.8))–\(TemplateFormat.number(depth)) mm. The openGrid accessories here say which.",
                printing: "Print them as laid out, back down. Press a nut into each before fitting it to the board\(values.choice("family") == 1 ? "; a directional snap goes in with its arrow side up, first" : ""). \(printSettings)")
            })
    }

    // MARK: Fit test

    static var fitTest: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.fit-test", category: .opengrid, title: "Interface Fit Test",
            summary: "Test a board and snap combination before printing a larger setup.",
            parameters: [boardParameter, familyParameter],
            name: { values in "openGrid \(boardType(values).title) Fit Test" },
            make: { values in
                let type = boardType(values)
                let board = try OpenGrid.boardShape(columns: 1, rows: 1, type: type, pockets: [], screwHoles: false)
                let snap = try OpenGridPart.screwSnap(type, directional: values.choice("family") == 1).shape
                return [TemplatePart(name: "Board Sample", body: try OpenGrid.body(board, at: SIMD3(-17, 0, 0)), shape: board),
                        TemplatePart(name: "Test Snap", body: try OpenGrid.body(snap, at: SIMD3(17, 0, 0)), shape: snap)]
            },
            needsPro: false,
            notes: { values in
                let type = boardType(values)
                return TemplateNotes(measurements: [
                    TemplateMeasurement(title: "Board sample", lengths: [pitch, pitch, type.thickness], text: "one cell of a \(type.title) board"),
                    TemplateMeasurement(title: "Test snap", text: "openGrid's \(type == .lite ? "Lite " : "")M3 nut \(values.choice("family") == 1 ? "directional " : "")snap")
                ], hardware: nil,
                printing: "Print both with the printer, material, and settings you'll use for the rest. The snap should click in from the front, sit flush, and hold; \(values.choice("family") == 1 ? "it goes in arrow side first and comes out by tilting its lower edge out" : "it pulls out with a firm tug"). If it's too tight or loose, change the print settings, not the model. \(printSettings)")
            })
    }
}

// MARK: Accessories

/// The M3 screws that hold an accessory to Metric Screw Snaps, and their holes: a screw goes
/// through the accessory's `plate` and the snap into the M3 nut in the snap's back. The longest
/// standard length that stays inside the snap is chosen, and the head is sunk into the plate as far
/// as it takes for the tip to reach at least 1.6 mm into the 2.4 mm nut.
struct SnapScrews {
    static let lengths: [Double] = [6, 8, 10, 12, 14, 16, 18, 20, 25, 30]
    static let counterbore = HolePresets.spec(.counterbore, size: "M3")
    /// A screw's center stays this far from an edge: the counterbore and 2 mm of material.
    static let edge = counterbore.counterboreDiameter / 2 + 2
    /// Kept clear beside a screw for the driver and the screw head.
    static let access = 4.0
    /// Kept clear above a screw's axis for the driver's shaft reaching over a lip.
    static let shaft = 2.5
    static let pitch = OpenGrid.pitch

    var type: OpenGrid.BoardType
    var plate: Double
    var snapDepth: Double { type == .full ? 6.8 : 3.4 }

    func screw() throws -> (length: Double, recess: Double) {
        guard let length = Self.lengths.last(where: { $0 <= plate + snapDepth + 1e-9 }) else {
            throw TemplateError.tooSmall("The mounting plate is too thin for an M3 screw.")
        }
        let grip = min(plate, length - (snapDepth - 0.8))
        guard grip >= 2 - 1e-9 else {
            throw TemplateError.tooSmall("The mounting plate is too thin to hold an M3 screw's head; make it thicker.")
        }
        return (length, plate - grip)
    }

    /// A screw hole entering the face through `point` that faces `normal`.
    func hole(at point: SIMD3<Double>, facing normal: SIMD3<Double>) throws -> ExtrusionCut {
        let recess = try screw().recess
        var spec = recess > 0.05 ? Self.counterbore : HolePresets.spec(.simple, size: "M3")
        if recess > 0.05 { spec.counterboreDepth = recess }
        var cut = ExtrusionCut(profile: TemplateGeometry.circle(spec.diameter, around: point, facing: normal), depth: 1, throughAll: true)
        cut.hole = spec
        return cut
    }

    func hardware(_ count: Int) -> String {
        let length = (try? screw().length).map { TemplateFormat.number($0) } ?? "?"
        return "\(count) Metric Screw Snaps (\(type.title), from the free set in openGrid), \(count) M3 nuts, and \(count) M3 × \(length) mm socket-head screws."
    }

    /// The most cells apart two screws can be, centered, keeping `margin` inside a `span`.
    static func cells(fitting span: Double, margin: Double) -> Int { max(0, Int(((span - 2 * margin) / pitch + 1e-9).rounded(.down))) }

    /// Screw positions along a span, `cells` apart end to end: the two ends, and for a long span
    /// (when `most` allows) the middle, or two more a third of the way in.
    static func positions(cells: Int, upTo most: Int = 2) -> [Double] {
        let third = Int((Double(cells) / 3).rounded())
        let steps = most < 3 || cells < 4 ? [0, cells] : cells % 2 == 0 || most == 3 ? [0, cells / 2, cells] : [0, third, cells - third, cells]
        return Array(Set(steps)).sorted().map { (Double($0) - Double(cells) / 2) * pitch }
    }

    /// "4 screws, 3 cells apart across and 1 up".
    static func pattern(count: Int, across: Int, up: Int?) -> String {
        let a = across == 1 ? "1 cell" : "\(across) cells"
        guard let up else { return "\(count) screws, \(a) apart" }
        return "\(count) screws, \(a) apart across and \(up) up"
    }
}

extension OpenGridTemplates {
    /// The Hook, Shelf, Bin, Cable Tray, Tool Rack, and Gridfinity Shelf hang from a backing this thick.
    static let backing = 5.0

    static func rectangle(x: ClosedRange<Double>, y: ClosedRange<Double>, z: Double) -> SketchProfile {
        TemplateGeometry.roundedRectangle(center: Point2(x: (x.lowerBound + x.upperBound) / 2, y: (y.lowerBound + y.upperBound) / 2),
                                          width: x.upperBound - x.lowerBound, depth: y.upperBound - y.lowerBound, radius: 0,
                                          on: TemplateGeometry.horizontal(z))
    }

    /// The tallest backing that takes only one row of screws; above it, two rows 28 mm apart.
    static let twoRows = 6 + pitch + SnapScrews.edge

    /// Two rows of screws 28 mm apart near the top of a backing `height` tall (above `bottom`), or one
    /// row across the middle of a short one.
    static func screwRows(height: Double, bottom: Double = 0) -> [Double] {
        height - bottom >= twoRows - 1e-9 ? [height - 6, height - 6 - pitch] : [bottom + (height - bottom) / 2]
    }

    // MARK: Mounting plate

    static var mountingPlate: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.mounting-plate", category: .opengrid, title: "Accessory Mounting Plate",
            summary: "Start a custom accessory on a board-compatible mounting plate.",
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(2...8), defaultValue: 3, note: "Cells across"),
                TemplateParameter(id: "rows", title: "Height", kind: .count(1...6), defaultValue: 2, note: "Cells up"),
                TemplateParameter(id: "thickness", title: "Thickness", kind: .length(3...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "points", title: "Mounting points", kind: .choice(["Two", "Four"]), defaultValue: 1),
                boardParameter
            ],
            name: { values in "openGrid Plate \(values.count("columns")) × \(values.count("rows"))" },
            make: { values in try [TemplatePart(name: "Mounting Plate", body: MountingPlate(values).body())] },
            notes: { values in MountingPlate(values).notes })
    }

    struct MountingPlate {
        var columns, rows: Int, thickness: Double, four: Bool, screws: SnapScrews
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); thickness = values["thickness"]; four = values.choice("points") == 1
            screws = SnapScrews(type: boardType(values), plate: thickness)
        }
        var size: (width: Double, height: Double) { (Double(columns) * pitch - 0.5, Double(rows) * pitch - 0.5) }
        var points: [Point2] {
            let x = Double(columns - 1) * pitch / 2, y = Double(rows - 1) * pitch / 2
            return four ? [Point2(x: -x, y: -y), Point2(x: x, y: -y), Point2(x: -x, y: y), Point2(x: x, y: y)] : [Point2(x: -x, y: y), Point2(x: x, y: y)]
        }

        /// Lying back down, the board side on z = 0 and "up" the wall along +y.
        func body() throws -> SolidBody {
            guard !four || rows >= 2 else { throw TemplateError.tooSmall("Four mounting points need a plate at least 2 cells high. Choose Two, or make it taller.") }
            var plate = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: size.width, depth: size.height, radius: 2, on: .top), height: thickness)
            plate.cuts = try points.map { try screws.hole(at: SIMD3($0.x, $0.y, thickness), facing: SIMD3(0, 0, 1)) }
            return plate
        }

        var notes: TemplateNotes {
            let recess = (try? screws.screw().recess) ?? 0
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Plate", lengths: [size.width, size.height, thickness]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: points.count, across: columns - 1, up: four ? rows - 1 : nil)),
                TemplateMeasurement(title: "From the board", lengths: [thickness + max(0, 3 - recess)], text: "with the screw heads")
            ], hardware: screws.hardware(points.count),
            printing: "Print it flat, back down. Add your accessory to its front with the modeling tools, keeping clear of the 6.1 mm screw heads.")
        }
    }

    // MARK: Hook

    static var hook: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.hook", category: .opengrid, title: "Hook",
            summary: "Hang a small item on a hook sized for it.",
            parameters: [
                TemplateParameter(id: "projection", title: "Reach", kind: .length(15...80, step: 1), defaultValue: 30, note: "From the board to the front of the tip"),
                TemplateParameter(id: "width", title: "Hook width", kind: .length(8...25, step: 0.5), defaultValue: 12),
                TemplateParameter(id: "section", title: "Thickness", kind: .length(4...10, step: 0.5), defaultValue: 6, note: "Of the arm and the tip"),
                TemplateParameter(id: "tip", title: "Tip rise", kind: .length(4...25, step: 0.5), defaultValue: 10, note: "Above the arm"),
                boardParameter
            ],
            name: { values in "openGrid Hook \(TemplateFormat.number(values["projection"])) mm" },
            make: { values in try [TemplatePart(name: "Hook", body: Hook(values).body())] },
            notes: { values in Hook(values).notes })
    }

    struct Hook {
        var projection, width, section, tip: Double, screws: SnapScrews
        init(_ values: TemplateValues) {
            projection = values["projection"]; width = values["width"]; section = values["section"]; tip = values["tip"]
            screws = SnapScrews(type: boardType(values), plate: backing)
        }
        /// The screws sit a cell either side of the hook, or two for a wide one.
        var columns: Int { width / 2 <= pitch / 2 - SnapScrews.access + 1e-9 ? 2 : 3 }
        var length: Double { Double(columns) * pitch - 0.5 }
        var height: Double { pitch - 0.5 }
        var throat: Double { projection - section - backing }

        /// On its side for strength: x out from the board, y up the wall, z along the wall.
        func body() throws -> SolidBody {
            guard throat >= 6 - 1e-9 else {
                throw TemplateError.tooSmall("The hook needs at least 6 mm between the board and its tip. Make its reach \(TemplateFormat.number(section + backing + 6)) mm or more.")
            }
            var hook = TemplateGeometry.block(rectangle(x: 0...backing, y: -height / 2...height / 2, z: 0), height: length)
            let bottom = -height / 2, top = bottom + section, gusset = min(section, throat / 2)
            let arm = [Point2(x: backing, y: bottom), Point2(x: projection, y: bottom), Point2(x: projection, y: top + tip),
                       Point2(x: projection - section, y: top + tip), Point2(x: projection - section, y: top),
                       Point2(x: backing + gusset, y: top), Point2(x: backing, y: top + gusset)]
            hook.cuts = [TemplateGeometry.step(TemplateGeometry.polygon(arm, on: TemplateGeometry.horizontal((length - width) / 2)), depth: width, join: true)]
            let offset = Double(columns - 1) * pitch / 2
            for z in [length / 2 - offset, length / 2 + offset] {
                hook.cuts.append(try screws.hole(at: SIMD3(backing, 0, z), facing: SIMD3(1, 0, 0)))
            }
            return hook
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Clear throat", lengths: [throat], text: "between the board and the tip"),
                TemplateMeasurement(title: "Reach", lengths: [projection - backing], text: "past the backing, \(TemplateFormat.number(projection)) mm from the board"),
                TemplateMeasurement(title: "Backing", lengths: [length, height, backing]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: 2, across: columns - 1, up: nil))
            ], hardware: screws.hardware(2),
            printing: "Print it on its side, as laid out, so the layers run along the arm. Check how much it holds before hanging anything heavy.")
        }
    }

    // MARK: Shelf

    static var shelf: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.shelf", category: .opengrid, title: "Shelf",
            summary: "Add a shelf with room for the items you want to display.",
            parameters: [
                TemplateParameter(id: "width", title: "Usable width", kind: .length(56...224, step: 1), defaultValue: 112, note: "Between the braces"),
                TemplateParameter(id: "depth", title: "Depth", kind: .length(40...150, step: 1), defaultValue: 80, note: "From the back to the lip"),
                TemplateParameter(id: "deck", title: "Shelf thickness", kind: .length(3...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "lip", title: "Front lip", kind: .length(0...20, step: 1), defaultValue: 8, note: "Above the shelf; 0 for none"),
                TemplateParameter(id: "back", title: "Back height", kind: .length(56...112, step: 1), defaultValue: 56),
                TemplateParameter(id: "brace", title: "Brace thickness", kind: .length(4...10, step: 0.5), defaultValue: 6),
                boardParameter
            ],
            name: { values in "openGrid Shelf \(TemplateFormat.number(values["width"])) mm" },
            make: { values in try [TemplatePart(name: "Shelf", body: Shelf(values).body())] },
            notes: { values in Shelf(values).notes })
    }

    /// A deck on the bed with a backing behind it and a triangular brace at each end; the same
    /// frame for the Gridfinity Shelf: x along the wall, y out from it, z up.
    struct ShelfFrame {
        var inner, depth, deck, back, brace: Double
        /// What sits on the deck at the front edge, and how high the lip rises above the deck.
        var lip: Double
        var screws: SnapScrews
        var half: Double { inner / 2 + brace }
        var lipThickness: Double { lip > 0 ? deck : 0 }
        var brace45: Double { min(depth, back - deck) }
        var columns: Int { SnapScrews.cells(fitting: inner, margin: SnapScrews.access) }
        var rows: [Double] { screwRows(height: back, bottom: deck) }

        func body(clearing above: Double) throws -> SolidBody {
            guard columns >= 1 else { throw TemplateError.tooSmall("The shelf is too narrow for its screws.") }
            if let lowest = rows.min(), lowest - SnapScrews.shaft < above - 1e-9 {
                throw TemplateError.tooSmall("The lip would block a screwdriver from the lower screws. Make the lip lower or the back taller.")
            }
            var shelf = TemplateGeometry.block(rectangle(x: -half...half, y: 0...(backing + depth + lipThickness), z: 0), height: deck)
            shelf.cuts.append(TemplateGeometry.step(rectangle(x: -half...half, y: 0...backing, z: deck), depth: back - deck, join: true))
            for side in [-1.0, 1] {
                let x = side * inner / 2
                guard let plane = SketchPlane.through(SIMD3(x, 0, 0), normal: SIMD3(side, 0, 0)) else { continue }
                let triangle = TemplateGeometry.polygon([SIMD3(x, backing, deck), SIMD3(x, backing, back), SIMD3(x, backing + brace45, deck)], on: plane)
                shelf.cuts.append(TemplateGeometry.step(triangle, depth: brace, join: true))
            }
            for x in SnapScrews.positions(cells: columns) {
                for z in rows { shelf.cuts.append(try screws.hole(at: SIMD3(x, backing, z), facing: SIMD3(0, 1, 0))) }
            }
            return shelf
        }

        func lipStep(top: Double) -> ExtrusionCut {
            TemplateGeometry.step(rectangle(x: -half...half, y: (backing + depth)...(backing + depth + deck), z: deck), depth: top - deck, join: true)
        }

        var mounting: TemplateMeasurement {
            TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: 2 * rows.count, across: columns, up: rows.count > 1 ? 1 : nil))
        }
    }

    struct Shelf {
        var frame: ShelfFrame
        init(_ values: TemplateValues) {
            frame = ShelfFrame(inner: values["width"], depth: values["depth"], deck: values["deck"], back: values["back"], brace: values["brace"],
                               lip: values["lip"], screws: SnapScrews(type: boardType(values), plate: backing))
        }
        func body() throws -> SolidBody {
            var shelf = try frame.body(clearing: frame.deck + frame.lip)
            if frame.lip > 0 { shelf.cuts.append(frame.lipStep(top: frame.deck + frame.lip)) }
            return shelf
        }
        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Shelf", lengths: [frame.inner, frame.depth], text: "between the braces and in front of the back"),
                TemplateMeasurement(title: "On the board", lengths: [2 * frame.half, frame.back]),
                TemplateMeasurement(title: "From the board", lengths: [backing + frame.depth + frame.lipThickness]),
                TemplateMeasurement(title: "Braces", lengths: [frame.brace45], text: "along the shelf"),
                frame.mounting
            ], hardware: frame.screws.hardware(2 * frame.rows.count),
            printing: "Print it as it hangs, shelf down; it needs no supports. Check how much it holds before loading it.")
        }
    }

    // MARK: Storage bin

    static var bin: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.bin", category: .opengrid, title: "Storage Bin",
            summary: "Keep small parts in an open bin on your board.",
            parameters: [
                TemplateParameter(id: "width", title: "Inside width", kind: .length(40...200, step: 1), defaultValue: 100),
                TemplateParameter(id: "depth", title: "Inside depth", kind: .length(30...120, step: 1), defaultValue: 60),
                TemplateParameter(id: "height", title: "Inside height", kind: .length(30...150, step: 1), defaultValue: 60),
                TemplateParameter(id: "wall", title: "Wall", kind: .length(1.6...5, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "floor", title: "Floor", kind: .length(1.6...5, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "front", title: "Front height", kind: .length(15...100, step: 1), defaultValue: 30, note: "The lowered front, above the floor"),
                boardParameter
            ],
            name: { values in "openGrid Bin \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))" },
            make: { values in try [TemplatePart(name: "Bin", body: Bin(values).body())] },
            notes: { values in Bin(values).notes })
    }

    struct Bin {
        var width, depth, height, wall, floor, front: Double, screws: SnapScrews
        init(_ values: TemplateValues) {
            width = values["width"]; depth = values["depth"]; height = values["height"]; wall = values["wall"]; floor = values["floor"]; front = values["front"]
            screws = SnapScrews(type: boardType(values), plate: backing)
        }
        var outer: Double { width / 2 + wall }
        /// The screws go in ears beside the bin, a whole number of cells apart, where nothing is in the way.
        var spread: Int { Int(((outer + SnapScrews.access) / (pitch / 2) - 1e-9).rounded(.up)) }
        var ears: Double { Double(spread) * pitch / 2 + SnapScrews.edge }
        var top: Double { floor + height }
        var rows: [Double] { screwRows(height: top) }

        /// Standing on its floor: x along the wall, y out from it, z up.
        func body() throws -> SolidBody {
            guard front <= height - 5 + 1e-9 else { throw TemplateError.tooSmall("The front must be at least 5 mm lower than the inside height.") }
            var bin = TemplateGeometry.block(rectangle(x: -outer...outer, y: 0...(backing + depth + wall), z: 0), height: top)
            bin.cuts = [
                TemplateGeometry.step(rectangle(x: -width / 2...width / 2, y: backing...(backing + depth), z: top), depth: -height),
                TemplateGeometry.step(rectangle(x: -width / 2...width / 2, y: (backing + depth - 1)...(backing + depth + wall + 1), z: top), depth: -(height - front)),
                TemplateGeometry.step(rectangle(x: -ears...ears, y: 0...backing, z: 0), depth: top, join: true)
            ]
            for x in [-1.0, 1] { for z in rows { bin.cuts.append(try screws.hole(at: SIMD3(x * Double(spread) * pitch / 2, backing, z), facing: SIMD3(0, 1, 0))) } }
            return bin
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Inside", lengths: [width, depth, height]),
                TemplateMeasurement(title: "Holds", text: "\(TemplateFormat.number(width * depth * height / 1_000_000, digits: 2)) L"),
                TemplateMeasurement(title: "Front opening", lengths: [height - front], text: "down from the top"),
                TemplateMeasurement(title: "On the board", lengths: [2 * ears, top]),
                TemplateMeasurement(title: "From the board", lengths: [backing + depth + wall]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: 2 * rows.count, across: spread, up: rows.count > 1 ? 1 : nil))
            ], hardware: screws.hardware(2 * rows.count),
            printing: "Print it standing on its floor; it needs no supports. The screws go through the ears beside it.")
        }
    }

    // MARK: Cable guide

    static var cableGuide: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.cable-guide", category: .opengrid, title: "Cable Guide",
            summary: "Route a row of cables across a board.",
            parameters: [
                TemplateParameter(id: "channels", title: "Channels", kind: .count(1...10), defaultValue: 4),
                TemplateParameter(id: "cable", title: "Cable diameter", kind: .length(2...16, step: 0.5), defaultValue: 6, note: "Measured"),
                Gridfinity.fitParameter,
                TemplateParameter(id: "web", title: "Between channels", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "length", title: "Guide length", kind: .length(10...35, step: 1), defaultValue: 16, note: "Along the cables"),
                boardParameter
            ],
            name: { values in "openGrid Cable Guide \(values.count("channels")) × \(TemplateFormat.number(values["cable"])) mm" },
            make: { values in try [TemplatePart(name: "Cable Guide", body: CableGuide(values).body())] },
            notes: { values in CableGuide(values).notes })
    }

    struct CableGuide {
        var channels: Int, cable, fit, web, length: Double, screws: SnapScrews
        static let plate = 4.0, floor = 2.0
        init(_ values: TemplateValues) {
            channels = values.count("channels"); cable = values["cable"]; fit = values["fit"]; web = values["web"]; length = values["length"]
            screws = SnapScrews(type: boardType(values), plate: Self.plate)
        }
        var channel: Double { cable + 2 * fit }
        var width: Double { Double(channels) * channel + Double(channels + 1) * web }
        var thickness: Double { max(Self.floor + channel, Self.plate + 1) }
        var spread: Int { Int(((width / 2 + SnapScrews.access) / (pitch / 2) - 1e-9).rounded(.up)) }
        var ears: Double { Double(spread) * pitch / 2 + SnapScrews.edge }
        var earHeight: Double { max(length, 2 * SnapScrews.edge + 2) }

        /// Back down on the bed (the board side on z = 0), the cables running along y.
        func body() throws -> SolidBody {
            var guide = TemplateGeometry.block(rectangle(x: -ears...ears, y: -earHeight / 2...earHeight / 2, z: 0), height: Self.plate)
            guide.cuts = [TemplateGeometry.step(rectangle(x: -width / 2...width / 2, y: -length / 2...length / 2, z: Self.plate), depth: thickness - Self.plate, join: true)]
            let center = Self.floor + channel / 2
            for index in 0..<channels {
                let x = -width / 2 + web + channel / 2 + Double(index) * (channel + web)
                guard let plane = SketchPlane.through(SIMD3(0, earHeight / 2 + 1, 0), normal: SIMD3(0, 1, 0)) else { continue }
                guide.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(channel, around: SIMD3(x, earHeight / 2 + 1, center), facing: SIMD3(0, 1, 0))))
                let open = [SIMD3(x - channel / 2, earHeight / 2 + 1, center), SIMD3(x + channel / 2, earHeight / 2 + 1, center),
                            SIMD3(x + channel / 2, earHeight / 2 + 1, thickness + 1), SIMD3(x - channel / 2, earHeight / 2 + 1, thickness + 1)]
                guide.cuts.append(TemplateGeometry.through(TemplateGeometry.polygon(open, on: plane)))
            }
            for x in [-1.0, 1] { guide.cuts.append(try screws.hole(at: SIMD3(x * Double(spread) * pitch / 2, 0, Self.plate), facing: SIMD3(0, 0, 1))) }
            return guide
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Channels", lengths: [channel], text: "\(channels), open at the front"),
                TemplateMeasurement(title: "Guide", lengths: [width, length, thickness]),
                TemplateMeasurement(title: "On the board", lengths: [2 * ears, earHeight]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: 2, across: spread, up: nil))
            ], hardware: screws.hardware(2),
            printing: "Print it back down, channels up. It routes cables in open channels they lift out of; it doesn't grip them.")
        }
    }

    // MARK: Cable tray

    static var cableTray: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.cable-tray", category: .opengrid, title: "Cable Tray",
            summary: "Support and organize a cable bundle along a board.",
            parameters: [
                TemplateParameter(id: "length", title: "Inside length", kind: .length(84...280, step: 1), defaultValue: 168),
                TemplateParameter(id: "projection", title: "Inside depth", kind: .length(30...100, step: 1), defaultValue: 60),
                TemplateParameter(id: "wallHeight", title: "Wall height", kind: .length(15...50, step: 1), defaultValue: 25),
                TemplateParameter(id: "wall", title: "Wall and floor", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "slotWidth", title: "Tie slot width", kind: .length(3...8, step: 0.5), defaultValue: 5, note: "Your cable ties' width, and a little more"),
                TemplateParameter(id: "slots", title: "Tie points", kind: .count(2...8), defaultValue: 4, note: "Each a pair of slots a tie goes down and back up through"),
                boardParameter
            ],
            name: { values in "openGrid Cable Tray \(TemplateFormat.number(values["length"])) mm" },
            make: { values in try [TemplatePart(name: "Cable Tray", body: CableTray(values).body())] },
            notes: { values in CableTray(values).notes })
    }

    struct CableTray {
        var length, projection, wallHeight, wall, slotWidth: Double, slots: Int, screws: SnapScrews
        static let slotLength = 3.0
        init(_ values: TemplateValues) {
            length = values["length"]; projection = values["projection"]; wallHeight = values["wallHeight"]; wall = values["wall"]
            slotWidth = values["slotWidth"]; slots = values.count("slots")
            screws = SnapScrews(type: boardType(values), plate: backing)
        }
        var outer: Double { length / 2 + wall }
        var spread: Int { Int(((outer + SnapScrews.access) / (pitch / 2) - 1e-9).rounded(.up)) }
        var ears: Double { Double(spread) * pitch / 2 + SnapScrews.edge }
        var top: Double { wall + wallHeight }
        var backHeight: Double { max(top, twoRows) }
        var rows: [Double] { screwRows(height: backHeight) }
        var slotRows: [Double] { [backing + projection * 0.3, backing + projection * 0.7] }

        /// Standing on its floor: x along the wall, y out from it, z up.
        func body() throws -> SolidBody {
            let spacing = length / Double(slots)
            guard spacing - slotWidth >= 2 - 1e-9 && spacing / 2 - slotWidth / 2 >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The tie slots are too close together. Use fewer tie points, narrower slots, or a longer tray.")
            }
            var tray = TemplateGeometry.block(rectangle(x: -outer...outer, y: 0...(backing + projection + wall), z: 0), height: top)
            tray.cuts = [
                TemplateGeometry.step(rectangle(x: -length / 2...length / 2, y: backing...(backing + projection), z: top), depth: -wallHeight),
                TemplateGeometry.step(rectangle(x: -ears...ears, y: 0...backing, z: 0), depth: backHeight, join: true)
            ]
            for index in 0..<slots {
                let x = -length / 2 + (Double(index) + 0.5) * spacing
                for y in slotRows {
                    tray.cuts.append(TemplateGeometry.through(rectangle(x: (x - slotWidth / 2)...(x + slotWidth / 2), y: (y - Self.slotLength / 2)...(y + Self.slotLength / 2), z: 0)))
                }
            }
            for x in [-1.0, 1] { for z in rows { tray.cuts.append(try screws.hole(at: SIMD3(x * Double(spread) * pitch / 2, backing, z), facing: SIMD3(0, 1, 0))) } }
            return tray
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Inside", lengths: [length, projection, wallHeight]),
                TemplateMeasurement(title: "Tie slots", lengths: [slotWidth, Self.slotLength], text: "\(slots) pairs, \(TemplateFormat.number(projection * 0.4)) mm apart"),
                TemplateMeasurement(title: "On the board", lengths: [2 * ears, backHeight]),
                TemplateMeasurement(title: "From the board", lengths: [backing + projection + wall]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: 2 * rows.count, across: spread, up: rows.count > 1 ? 1 : nil))
            ], hardware: screws.hardware(2 * rows.count) + " Cable ties, if you want to tie the bundle down.",
            printing: "Print it standing on its floor; it needs no supports. It's for a board on a wall, open side up, not under a desk.")
        }
    }

    // MARK: Tool rack

    static var toolRack: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.tool-rack", category: .opengrid, title: "Tool Rack",
            summary: "Hold a row of tools in a removable board-mounted rack.",
            parameters: [
                TemplateParameter(id: "tools", title: "Tools", kind: .count(2...10), defaultValue: 6),
                TemplateParameter(id: "shaft", title: "Shaft diameter", kind: .length(2...15, step: 0.1), defaultValue: 6, note: "Measured where it passes through the rack"),
                Gridfinity.fitParameter,
                TemplateParameter(id: "handle", title: "Handle diameter", kind: .length(8...45, step: 0.5), defaultValue: 20, note: "The part that rests on the rack"),
                TemplateParameter(id: "pitch", title: "Spacing", kind: .length(12...60, step: 0.5), defaultValue: 26, note: "Center to center"),
                TemplateParameter(id: "support", title: "Rack thickness", kind: .length(5...15, step: 0.5), defaultValue: 8),
                TemplateParameter(id: "projection", title: "Depth", kind: .length(25...70, step: 1), defaultValue: 35, note: "From the back"),
                boardParameter
            ],
            name: { values in "openGrid Tool Rack \(values.count("tools")) × \(TemplateFormat.number(values["shaft"])) mm" },
            make: { values in try [TemplatePart(name: "Tool Rack", body: ToolRack(values).body())] },
            notes: { values in ToolRack(values).notes })
    }

    struct ToolRack {
        var tools: Int, shaft, fit, handle, spacing, support, projection: Double, screws: SnapScrews
        init(_ values: TemplateValues) {
            tools = values.count("tools"); shaft = values["shaft"]; fit = values["fit"]; handle = values["handle"]; spacing = values["pitch"]
            support = values["support"]; projection = values["projection"]
            screws = SnapScrews(type: boardType(values), plate: backing)
        }
        var opening: Double { shaft + 2 * fit }
        var width: Double { max(Double(tools - 1) * spacing + handle + 6, pitch + 2 * SnapScrews.edge) }
        var height: Double { max(pitch - 0.5, support + 2 * SnapScrews.edge) }
        var cells: Int { SnapScrews.cells(fitting: width, margin: SnapScrews.edge) }
        var screwXs: [Double] { SnapScrews.positions(cells: cells, upTo: 4) }

        /// Upside down, rack on the bed: x along the wall, y out from it, z down the wall.
        func body() throws -> SolidBody {
            guard handle >= opening + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The handles must be at least 2 mm wider than the openings, or the tools fall through.")
            }
            guard spacing >= handle + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The tools are closer together than their handles. Space them at least \(TemplateFormat.number(handle + 2)) mm apart.")
            }
            guard projection >= handle + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The rack is too shallow for the handles. Make it at least \(TemplateFormat.number(handle + 2)) mm deep.")
            }
            var rack = TemplateGeometry.block(rectangle(x: -width / 2...width / 2, y: 0...(backing + projection), z: 0), height: support)
            rack.cuts = [TemplateGeometry.step(rectangle(x: -width / 2...width / 2, y: 0...backing, z: support), depth: height - support, join: true)]
            for index in 0..<tools {
                let x = (Double(index) - Double(tools - 1) / 2) * spacing
                rack.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(opening, at: Point2(x: x, y: backing + projection / 2), on: TemplateGeometry.horizontal(support))))
            }
            let z = support + (height - support) / 2
            for x in screwXs { rack.cuts.append(try screws.hole(at: SIMD3(x, backing, z), facing: SIMD3(0, 1, 0))) }
            return rack
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Openings", lengths: [opening], text: "\(tools), \(TemplateFormat.number(spacing)) mm apart"),
                TemplateMeasurement(title: "Rack", lengths: [width, projection, support]),
                TemplateMeasurement(title: "On the board", lengths: [width, height]),
                TemplateMeasurement(title: "Mounting", text: SnapScrews.pattern(count: screwXs.count, across: cells, up: nil))
            ], hardware: screws.hardware(screwXs.count),
            printing: "Print it upside down, rack on the bed, as laid out; hang it rack up. Take the tools out to reach the screws.")
        }
    }

    // MARK: Gridfinity shelf

    static var gridfinityShelf: ProjectTemplate {
        ProjectTemplate(
            id: "opengrid.gridfinity-shelf", category: .opengrid, title: "Gridfinity Shelf",
            summary: "Mount Gridfinity bins on a board-compatible shelf.",
            parameters: [
                TemplateParameter(id: "columns", title: "Gridfinity columns", kind: .count(1...6), defaultValue: 2),
                TemplateParameter(id: "rows", title: "Gridfinity rows", kind: .count(1...3), defaultValue: 2, note: "Front to back"),
                TemplateParameter(id: "deck", title: "Shelf thickness", kind: .length(3...8, step: 0.5), defaultValue: 4, note: "Under the baseplate"),
                TemplateParameter(id: "back", title: "Back height", kind: .length(56...112, step: 1), defaultValue: 56),
                TemplateParameter(id: "lip", title: "Front lip", kind: .length(0...15, step: 0.5), defaultValue: 6, note: "Above the baseplate; 0 for none"),
                boardParameter
            ],
            name: { values in "openGrid Gridfinity Shelf \(values.count("columns")) × \(values.count("rows"))" },
            make: { values in try [TemplatePart(name: "Gridfinity Shelf", body: GridfinityShelf(values).body())] },
            notes: { values in GridfinityShelf(values).notes })
    }

    struct GridfinityShelf {
        var columns, rows: Int, frame: ShelfFrame
        static let brace = 6.0
        /// The baseplate's height: its pocket profile.
        static let plateHeight = Gridfinity.pocketSteps.lower + Gridfinity.pocketSteps.straight + Gridfinity.pocketSteps.upper - 0.2
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows")
            frame = ShelfFrame(inner: Double(columns) * Gridfinity.pitch, depth: Double(rows) * Gridfinity.pitch, deck: values["deck"], back: values["back"],
                               brace: Self.brace, lip: values["lip"], screws: SnapScrews(type: boardType(values), plate: backing))
        }
        var plateTop: Double { frame.deck + Self.plateHeight }

        func body() throws -> SolidBody {
            var shelf = try frame.body(clearing: plateTop + frame.lip)
            let plate = try Gridfinity.plate(columns: columns, rows: rows, magnets: false)
            guard let placed = plate.transformed(by: .move(SIMD3(0, backing + frame.depth / 2, frame.deck))) else { throw TemplateError.failed("Gridfinity Shelf") }
            shelf.cuts.append(.merge(placed))
            if frame.lip > 0 { shelf.cuts.append(frame.lipStep(top: plateTop + frame.lip)) }
            return shelf
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Bins", text: "\(columns) × \(rows) Gridfinity cells, on a floor \(TemplateFormat.number(frame.deck)) mm thick"),
                TemplateMeasurement(title: "Shelf", lengths: [2 * frame.half, backing + frame.depth + frame.lipThickness]),
                TemplateMeasurement(title: "On the board", lengths: [2 * frame.half, frame.back]),
                TemplateMeasurement(title: "From the board", lengths: [backing + frame.depth + frame.lipThickness]),
                frame.mounting
            ], hardware: frame.screws.hardware(2 * frame.rows.count),
            printing: "Print it as it hangs, shelf down; it needs no supports. Mount it empty, then set the bins in; they lift straight out.")
        }
    }
}
