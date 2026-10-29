import Foundation

/// Gridfinity templates: Zack Freedman's open modular storage system (MIT licensed). Bins sit on a
/// 42 mm grid, are 7 mm per height unit, and click into baseplates by a stepped foot under each
/// grid cell. The sizes below follow the published specification.
///
/// Each stepped profile is built in a few steps for the whole grid at once: a region with one hole
/// per cell (a foot or a pocket), extruded and tapered 45° by the kernel, rather than one step per
/// cell. Only magnet holes take a step each.
enum Gridfinity {
    static let pitch = 42.0
    static let heightUnit = 7.0
    /// Bins are this much smaller than their cells, so neighbors fit side by side.
    static let binGap = 0.5
    static let binRadius = 3.75
    /// The foot under each cell, from the bottom: a 45° step out, straight up, and a 45° step out
    /// to the full cell.
    static let footSteps = (lower: 0.8, straight: 1.8, upper: 2.15)
    /// The baseplate pocket, from the bottom: the same shape with a 0.7 mm lower step.
    static let pocketSteps = (lower: 0.7, straight: 1.8, upper: 2.15)
    /// The stacking lip, from the bottom: like the pocket, but its top step is 1.9 mm, as it starts
    /// from the bin's outline rather than the full cell.
    static let lipSteps = (lower: 0.7, straight: 1.8, upper: 1.9)
    static let plateRadius = 4.0
    /// Magnets (6 × 2 mm discs) sit 13 mm from a cell's center along both axes.
    static let magnetOffset = 13.0
    static let magnetHole = (diameter: 6.5, depth: 2.4)
    static let wall = 1.2
    static let floorHeight = 6.0
    static let dividerThickness = 1.2
    /// The stacking lip rises this far above the bin's height and takes the foot of a bin above.
    static let lipHeight = 4.2

    static var templates: [ProjectTemplate] {
        [baseplate(id: "gridfinity.baseplate", title: "Baseplate", magnets: false,
                   summary: "The grid bins sit in. Print it to fit a drawer or shelf; the bins click into its pockets."),
         baseplate(id: "gridfinity.magnet-baseplate", title: "Magnet Baseplate", magnets: true,
                   summary: "A baseplate with a floor and a pocket for a 6 × 2 mm magnet under each bin corner, so bins stay put."),
         bin(id: "gridfinity.bin", title: "Bin", dividers: (0, 0),
             summary: "A storage bin sized in grid units, with the stacking lip so another bin can sit on top."),
         bin(id: "gridfinity.divided-bin", title: "Divided Bin", dividers: (2, 1),
             summary: "A bin split into compartments by thin walls, for screws, parts, and small tools.")] + accessories
    }

    // MARK: Baseplate

    static func baseplate(id: String, title: String, magnets: Bool, summary: String) -> ProjectTemplate {
        ProjectTemplate(
            id: id, category: .gridfinity, title: title, summary: summary,
            // The free Baseplate has no magnet pockets; the Magnet Baseplate (Pro) can turn them off.
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(1...8), defaultValue: magnets ? 3 : 4, note: "Grid units of 42 mm"),
                TemplateParameter(id: "rows", title: "Depth", kind: .count(1...8), defaultValue: 3, note: "Grid units of 42 mm")
            ] + (magnets ? [
                TemplateParameter(id: "magnets", title: "Magnet pockets", kind: .toggle, defaultValue: 1,
                                  note: "Adds a floor with a pocket for a 6 × 2 mm magnet under each bin corner")
            ] : []),
            name: { values in "Gridfinity Baseplate \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in
                [TemplatePart(name: "Baseplate", body: try plate(columns: values.count("columns"), rows: values.count("rows"), magnets: values.flag("magnets")))]
            },
            needsPro: magnets)
    }

    /// The pocket centers, one per cell, with the grid centered on the origin.
    static func cellCenters(columns: Int, rows: Int) -> [Point2] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                Point2(x: (Double(column) - Double(columns - 1) / 2) * pitch, y: (Double(row) - Double(rows - 1) / 2) * pitch)
            }
        }
    }

    static func plate(columns: Int, rows: Int, magnets: Bool) throws -> SolidBody {
        let width = Double(columns) * pitch, depth = Double(rows) * pitch
        let cells = cellCenters(columns: columns, rows: rows)
        // Pockets are a hair smaller than the cells, so the ridges between them have a top (the
        // specification's knife edge, 0.2 mm lower); a bin seats exactly as on a full-height plate.
        let top = pitch - 0.4, s = pocketSteps
        let topRadius = plateRadius - 0.2
        let upper = s.upper - 0.2
        let middle = top - 2 * upper, bottom = middle - 2 * s.lower
        let lowerRadius = topRadius - upper - s.lower, middleRadius = topRadius - upper
        let margin = 10.0
        func square(_ z: Double, grow: Double = 0) -> SketchProfile {
            TemplateGeometry.roundedRectangle(width: width + 2 * grow, depth: depth + 2 * grow, radius: 0, on: TemplateGeometry.horizontal(z))
        }
        func grid(_ z: Double, pocket: Double, radius: Double) -> SketchProfile {
            let plane = TemplateGeometry.horizontal(z)
            return TemplateGeometry.region(square(z, grow: margin), holes: cells.map {
                TemplateGeometry.roundedRectangle(center: $0, width: pocket, depth: pocket, radius: radius, on: plane)
            })
        }
        var body: SolidBody
        var steps: [ExtrusionCut] = []
        // Magnet plates stand on a floor with the magnet pockets in it (one region, so a big plate
        // is a few steps, not one per pocket) over a skin that closes them underneath.
        let skin = 0.8
        let floor = magnets ? skin + magnetHole.depth : 0
        if magnets {
            body = TemplateGeometry.block(square(0, grow: margin), height: skin)
            let plane = TemplateGeometry.horizontal(skin)
            let pockets = cells.flatMap(magnetCorners).map { TemplateGeometry.circle(magnetHole.diameter, at: $0, on: plane, points: 32) }
            steps.append(TemplateGeometry.step(TemplateGeometry.region(square(skin, grow: margin), holes: pockets), depth: magnetHole.depth, join: true))
            steps.append(TemplateGeometry.step(grid(floor, pocket: bottom, radius: lowerRadius), depth: s.lower, taper: 45, join: true))
        } else {
            // The pockets widen upward, so the region around them narrows: a positive taper.
            body = TemplateGeometry.block(grid(0, pocket: bottom, radius: lowerRadius), height: s.lower, taper: 45)
        }
        steps.append(TemplateGeometry.step(grid(floor + s.lower, pocket: middle, radius: middleRadius), depth: s.straight, join: true))
        steps.append(TemplateGeometry.step(grid(floor + s.lower + s.straight, pocket: middle, radius: middleRadius), depth: upper, taper: 45, join: true))
        // Trim everything outside the plate's outline.
        let outline = TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: plateRadius, on: .top)
        steps.append(TemplateGeometry.through(TemplateGeometry.region(square(0, grow: 2 * margin), holes: [outline])))
        body.cuts = steps
        return body
    }

    static func magnetCorners(of cell: Point2) -> [Point2] {
        [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { cell + Point2(x: $0.0 * magnetOffset, y: $0.1 * magnetOffset) }
    }

    /// The feet under every cell of a `width` × `depth` body standing on z = 0: the region around
    /// them cut away in three steps (45° out, straight, 45° out).
    static func feet(width: Double, depth: Double, cells: [Point2]) -> [ExtrusionCut] {
        let f = footSteps
        let foot = pitch - binGap
        let middle = foot - 2 * f.upper, bottom = middle - 2 * f.lower
        let middleRadius = binRadius - f.upper, bottomRadius = middleRadius - f.lower
        let margin = 10.0
        func around(_ z: Double, foot size: Double, radius: Double) -> SketchProfile {
            let plane = TemplateGeometry.horizontal(z)
            let outer = TemplateGeometry.roundedRectangle(width: width + 2 * margin, depth: depth + 2 * margin, radius: 0, on: plane)
            return TemplateGeometry.region(outer, holes: cells.map {
                TemplateGeometry.roundedRectangle(center: $0, width: size, depth: size, radius: radius, on: plane)
            })
        }
        return [TemplateGeometry.step(around(0, foot: bottom, radius: bottomRadius), depth: f.lower, taper: 45),
                TemplateGeometry.step(around(f.lower, foot: middle, radius: middleRadius), depth: f.straight),
                TemplateGeometry.step(around(f.lower + f.straight, foot: middle, radius: middleRadius), depth: f.upper, taper: 45)]
    }

    /// Half the width of a foot's narrowest part, at the bottom: anything drilled through a foot
    /// stays inside this, so it never breaks out through the tapers.
    static var footBottomHalf: Double { (pitch - binGap) / 2 - footSteps.upper - footSteps.lower }

    // MARK: Bins

    static let magnetChoices = ["None", "Outer corners", "Every cell"]

    static func bin(id: String, title: String, dividers: (Int, Int), summary: String) -> ProjectTemplate {
        // The free Bin is a plain bin with its lip; the Divided Bin (Pro) adds dividers and
        // magnet holes, and with no dividers is a plain bin that can take magnets.
        let divided = dividers.0 > 0 || dividers.1 > 0
        return ProjectTemplate(
            id: id, category: .gridfinity, title: title, summary: summary,
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(1...8), defaultValue: dividers.0 > 0 ? 3 : 2, note: "Grid units of 42 mm"),
                TemplateParameter(id: "rows", title: "Depth", kind: .count(1...8), defaultValue: dividers.1 > 0 ? 2 : 1, note: "Grid units of 42 mm"),
                TemplateParameter(id: "height", title: "Height", kind: .count(2...15), defaultValue: dividers.0 > 0 ? 3 : 6, note: "Height units of 7 mm")
            ] + (divided ? [
                TemplateParameter(id: "dividersX", title: "Dividers across", kind: .count(0...7), defaultValue: Double(dividers.0)),
                TemplateParameter(id: "dividersY", title: "Dividers front to back", kind: .count(0...7), defaultValue: Double(dividers.1))
            ] : []) + [
                TemplateParameter(id: "lip", title: "Stacking lip", kind: .toggle, defaultValue: 1, note: "Lets another bin stack on top")
            ] + (divided ? [
                TemplateParameter(id: "magnets", title: "Magnet holes", kind: .choice(magnetChoices), defaultValue: 0,
                                  note: "Pockets underneath for 6 × 2 mm magnets")
            ] : []),
            name: { values in "Gridfinity Bin \(values.count("columns"))×\(values.count("rows"))×\(values.count("height"))" },
            make: { values in
                [TemplatePart(name: "Bin", body: try bin(columns: values.count("columns"), rows: values.count("rows"), height: values.count("height"),
                                                         dividers: (values.count("dividersX"), values.count("dividersY")),
                                                         lip: values.flag("lip"), magnets: values.choice("magnets")))]
            },
            needsPro: divided)
    }

    /// A bin `columns` × `rows` cells and `height` units tall, standing on the origin.
    static func bin(columns: Int, rows: Int, height: Int, dividers: (Int, Int), lip: Bool, magnets: Int) throws -> SolidBody {
        let width = Double(columns) * pitch - binGap, depth = Double(rows) * pitch - binGap
        let top = Double(height) * heightUnit
        let cells = cellCenters(columns: columns, rows: rows)
        let outline = TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: binRadius, on: .top)
        var body = TemplateGeometry.block(outline, height: top + (lip ? lipHeight : 0))
        var steps: [ExtrusionCut] = []

        // Magnet pockets: the bottom of the bin is redone as one region with a hole for each
        // (rather than a step per pocket), and the feet are then cut from it like the rest.
        if magnets > 0 {
            var points = cells.flatMap(magnetCorners)
            if magnets == 1 {
                // Only the pocket nearest each corner of the bin.
                let corners = [Point2(x: -width, y: -depth), Point2(x: width, y: -depth), Point2(x: width, y: depth), Point2(x: -width, y: depth)]
                points = corners.compactMap { corner in points.min { $0.distance(to: corner) < $1.distance(to: corner) } }
            }
            body = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: binRadius,
                                                                            on: TemplateGeometry.horizontal(magnetHole.depth)),
                                          height: top + (lip ? lipHeight : 0) - magnetHole.depth)
            let base = TemplateGeometry.roundedRectangle(width: width + 10, depth: depth + 10, radius: 0, on: .top)
            let pockets = points.map { TemplateGeometry.circle(magnetHole.diameter, at: $0, on: .top, points: 32) }
            steps.append(TemplateGeometry.step(TemplateGeometry.region(base, holes: pockets), depth: magnetHole.depth, join: true))
        }

        steps += feet(width: width, depth: depth, cells: cells)

        // The inside, from the top of the walls down to the floor.
        let innerWidth = width - 2 * wall, innerDepth = depth - 2 * wall, innerRadius = binRadius - wall
        steps.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: innerWidth, depth: innerDepth, radius: innerRadius,
                                                                             on: TemplateGeometry.horizontal(top)), depth: -(top - floorHeight)))

        // Dividers: one lattice standing on the floor, the compartments holes in it. Its edges run
        // into the walls (as do the compartments' outer sides), so no face of it lies on a wall.
        if dividers.0 > 0 || dividers.1 > 0 {
            let across = dividers.0 + 1, along = dividers.1 + 1
            let cellWidth = (innerWidth - Double(dividers.0) * dividerThickness) / Double(across)
            let cellDepth = (innerDepth - Double(dividers.1) * dividerThickness) / Double(along)
            guard cellWidth >= 5, cellDepth >= 5 else { throw TemplateError.tooSmall("Too many dividers for a bin this size. Make it bigger or use fewer dividers.") }
            let plane = TemplateGeometry.horizontal(floorHeight), overlap = 0.6, reach = 0.3
            var compartments: [SketchProfile] = []
            for row in 0..<along {
                for column in 0..<across {
                    var low = Point2(x: -innerWidth / 2 + Double(column) * (cellWidth + dividerThickness),
                                     y: -innerDepth / 2 + Double(row) * (cellDepth + dividerThickness))
                    var high = low + Point2(x: cellWidth, y: cellDepth)
                    if column == 0 { low.x -= reach }
                    if row == 0 { low.y -= reach }
                    if column == across - 1 { high.x += reach }
                    if row == along - 1 { high.y += reach }
                    let size = high - low
                    // Small corners where dividers meet; at the bin's own corners, the walls' curve.
                    let corner = innerRadius + reach, small = 0.8
                    let radii = [column == across - 1 && row == 0 ? corner : small, column == across - 1 && row == along - 1 ? corner : small,
                                 column == 0 && row == along - 1 ? corner : small, column == 0 && row == 0 ? corner : small]
                    compartments.append(TemplateGeometry.roundedRectangle(center: (low + high) * 0.5, width: size.x, depth: size.y,
                                                                          radii: radii, on: plane))
                }
            }
            let outer = TemplateGeometry.roundedRectangle(width: innerWidth + 2 * overlap, depth: innerDepth + 2 * overlap,
                                                          radius: innerRadius + overlap, on: plane)
            steps.append(TemplateGeometry.step(TemplateGeometry.region(outer, holes: compartments), depth: top - floorHeight, join: true))
        }

        if lip {
            // The stacking lip, from its top down: 45° in, straight, 45° in (the baseplate pocket's
            // shape, so a foot above seats in it), then 45° back out to the walls underneath. Like
            // the baseplate's ridges, its knife edge is 0.2 mm lower, leaving a top to print.
            let s = lipSteps
            let upper = s.upper - 0.2
            let opening = width - 0.4, openingRadius = binRadius - 0.2
            let narrow = opening - 2 * upper, narrowRadius = openingRadius - upper
            let narrowest = narrow - 2 * s.lower, narrowestRadius = narrowRadius - s.lower
            let support = (innerWidth - narrowest) / 2
            var z = top + lipHeight
            func ring(_ size: Double, _ radius: Double) -> SketchProfile {
                TemplateGeometry.roundedRectangle(width: size, depth: size - width + depth, radius: radius, on: TemplateGeometry.horizontal(z))
            }
            steps.append(TemplateGeometry.step(ring(opening, openingRadius), depth: -upper, taper: 45)); z -= upper
            steps.append(TemplateGeometry.step(ring(narrow, narrowRadius), depth: -s.straight)); z -= s.straight
            steps.append(TemplateGeometry.step(ring(narrow, narrowRadius), depth: -s.lower, taper: 45)); z -= s.lower
            steps.append(TemplateGeometry.step(ring(narrowest, narrowestRadius), depth: -support, taper: -45))
        }
        body.cuts = steps
        return body
    }
}

// MARK: Accessories (October 28, 2026, second expansion)

extension Gridfinity {
    static var accessories: [ProjectTemplate] {
        [ProjectTemplate(
            id: "gridfinity.label-bin", category: .gridfinity, title: "Bin with Label Shelf",
            summary: "Organize small parts in a bin with a shelf along the front for a label.",
            // Free, like the plain Bin, with no dividers or magnet holes (user decision, October 28, 2026).
            parameters: gridParameters(columns: 3, rows: 2, maxColumns: 6) + [
                TemplateParameter(id: "height", title: "Height", kind: .count(3...12), defaultValue: 4, note: "Height units of 7 mm"),
                TemplateParameter(id: "shelfDepth", title: "Label shelf depth", kind: .length(6...18, step: 1), defaultValue: 10),
                TemplateParameter(id: "shelfThickness", title: "Shelf thickness", kind: .length(1.2...3, step: 0.1), defaultValue: 1.6),
                TemplateParameter(id: "lip", title: "Stacking lip", kind: .toggle, defaultValue: 1, note: "Lets another bin stack on top")
            ],
            name: { values in "Gridfinity Label Bin \(values.count("columns"))×\(values.count("rows"))×\(values.count("height"))" },
            make: { values in [TemplatePart(name: "Label Bin", body: try LabelBin(values).body())] },
            needsPro: false,
            notes: { values in LabelBin(values).notes }),
         ProjectTemplate(
            id: "gridfinity.tool-insert", category: .gridfinity, title: "Tool Pocket Insert",
            summary: "Make fitted pockets for bits, drivers, or tools in a solid block on Gridfinity feet.",
            parameters: gridParameters(columns: 3, rows: 2, maxColumns: 6) + [
                TemplateParameter(id: "height", title: "Height", kind: .count(2...10), defaultValue: 4, note: "Height units of 7 mm"),
                TemplateParameter(id: "shape", title: "Pocket shape", kind: .choice(["Round", "Hexagonal", "Rectangular"]), defaultValue: 0),
                TemplateParameter(id: "size", title: "Measured size", kind: .length(2...35, step: 0.1), defaultValue: 8,
                                  note: "Diameter, or across the flats of a hexagon", isShown: { $0.choice("shape") != 2 }),
                TemplateParameter(id: "pocketWidth", title: "Measured width", kind: .length(3...40, step: 0.1), defaultValue: 8,
                                  isShown: { $0.choice("shape") == 2 }),
                TemplateParameter(id: "pocketLength", title: "Measured depth", kind: .length(3...60, step: 0.1), defaultValue: 16,
                                  isShown: { $0.choice("shape") == 2 }),
                TemplateParameter(id: "pocketColumns", title: "Pocket columns", kind: .count(1...12), defaultValue: 4),
                TemplateParameter(id: "pocketRows", title: "Pocket rows", kind: .count(1...8), defaultValue: 2),
                TemplateParameter(id: "columnPitch", title: "Column spacing", kind: .length(5...80, step: 1), defaultValue: 20, note: "Center to center"),
                TemplateParameter(id: "rowPitch", title: "Row spacing", kind: .length(5...80, step: 1), defaultValue: 24, note: "Center to center"),
                TemplateParameter(id: "pocketDepth", title: "Pocket depth", kind: .length(3...50, step: 0.5), defaultValue: 14),
                fitParameter
            ],
            name: { values in "Gridfinity Tool Insert \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in [TemplatePart(name: "Tool Insert", body: try ToolInsert(values).body())] },
            notes: { values in ToolInsert(values).notes }),
         ProjectTemplate(
            id: "gridfinity.bottle-holder", category: .gridfinity, title: "Bottle Holder",
            summary: "Keep bottles upright in wells on Gridfinity feet, for paints, glues, and oils.",
            parameters: gridParameters(columns: 2, rows: 2, maxColumns: 6) + [
                TemplateParameter(id: "height", title: "Height", kind: .count(3...12), defaultValue: 5, note: "Height units of 7 mm"),
                TemplateParameter(id: "bottle", title: "Bottle diameter", kind: .length(8...70, step: 0.1), defaultValue: 28,
                                  note: "The widest part that goes into the well"),
                TemplateParameter(id: "bottleColumns", title: "Bottle columns", kind: .count(1...6), defaultValue: 2),
                TemplateParameter(id: "bottleRows", title: "Bottle rows", kind: .count(1...6), defaultValue: 2),
                TemplateParameter(id: "pocketDepth", title: "Well depth", kind: .length(8...60, step: 0.5), defaultValue: 20),
                fitParameter
            ],
            name: { values in "Gridfinity Bottle Holder Ø\(TemplateFormat.number(values["bottle"]))" },
            make: { values in [TemplatePart(name: "Bottle Holder", body: try BottleHolder(values).body())] },
            notes: { values in BottleHolder(values).notes }),
         ProjectTemplate(
            id: "gridfinity.adapter-base", category: .gridfinity, title: "Adapter Base",
            summary: "Mount a part of your own on Gridfinity feet: a flat plate with screw holes.",
            parameters: gridParameters(columns: 2, rows: 2, maxColumns: 6) + [
                TemplateParameter(id: "plate", title: "Plate thickness", kind: .length(2...10, step: 0.5), defaultValue: 4,
                                  note: "Above the 6 mm Gridfinity floor"),
                TemplateParameter(id: "holeColumns", title: "Hole columns", kind: .count(0...4), defaultValue: 2, note: "0 for no holes"),
                TemplateParameter(id: "holeRows", title: "Hole rows", kind: .count(1...4), defaultValue: 2),
                TemplateParameter(id: "columnPitch", title: "Column spacing", kind: .length(5...150, step: 1), defaultValue: 42, note: "Center to center"),
                TemplateParameter(id: "rowPitch", title: "Row spacing", kind: .length(5...150, step: 1), defaultValue: 42, note: "Center to center"),
                TemplateParameter(id: "hole", title: "Hole diameter", kind: .length(2...8, step: 0.1), defaultValue: 3.4)
            ],
            name: { values in "Gridfinity Adapter Base \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in [TemplatePart(name: "Adapter Base", body: try AdapterBase(values).body())] },
            notes: { values in AdapterBase(values).notes })]
    }

    static func gridParameters(columns: Int, rows: Int, maxColumns: Int) -> [TemplateParameter] {
        [TemplateParameter(id: "columns", title: "Width", kind: .count(1...maxColumns), defaultValue: Double(columns), note: "Grid units of 42 mm"),
         TemplateParameter(id: "rows", title: "Depth", kind: .count(1...6), defaultValue: Double(rows), note: "Grid units of 42 mm")]
    }

    static var fitParameter: TemplateParameter {
        TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                          note: "Gap on each side; starts from the Fit in the project menu")
    }

    /// A body's outside size: whole cells less the gap that lets neighbors sit side by side.
    static func footprint(columns: Int, rows: Int) -> (width: Double, depth: Double) {
        (Double(columns) * pitch - binGap, Double(rows) * pitch - binGap)
    }

    /// A solid block on Gridfinity feet, `top` tall: its full outline up to `solid`, then `region`
    /// (the outline with pockets as holes, on the plane at `solid`) up to `top`.
    static func footedBlock(columns: Int, rows: Int, top: Double, solid: Double? = nil, pockets: (SketchPlane) -> [SketchProfile] = { _ in [] }) -> SolidBody {
        let size = footprint(columns: columns, rows: rows)
        let base = solid ?? top
        var body = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: size.width, depth: size.depth, radius: binRadius, on: .top), height: base)
        body.cuts = feet(width: size.width, depth: size.depth, cells: cellCenters(columns: columns, rows: rows))
        if base < top {
            let plane = TemplateGeometry.horizontal(base)
            let outline = TemplateGeometry.roundedRectangle(width: size.width, depth: size.depth, radius: binRadius, on: plane)
            body.cuts.append(TemplateGeometry.step(TemplateGeometry.region(outline, holes: pockets(plane)), depth: top - base, join: true))
        }
        return body
    }

    /// Whether a shape reaching `radius` from `center` stays `margin` inside a body's rounded outline.
    static func inside(_ center: Point2, radius: Double, margin: Double, width: Double, depth: Double) -> Bool {
        let limit = Point2(x: width / 2 - margin - radius, y: depth / 2 - margin - radius)
        guard abs(center.x) <= limit.x + 1e-9, abs(center.y) <= limit.y + 1e-9 else { return false }
        // In a corner, keep clear of its round.
        let arc = Point2(x: width / 2 - binRadius, y: depth / 2 - binRadius)
        let corner = Point2(x: abs(center.x), y: abs(center.y))
        guard corner.x > arc.x, corner.y > arc.y else { return true }
        return corner.distance(to: arc) + radius <= binRadius - margin + 1e-9
    }

    // MARK: Label bin

    struct LabelBin {
        var columns, rows, height: Int
        var shelfDepth, shelfThickness: Double
        var lip: Bool
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); height = values.count("height")
            shelfDepth = values["shelfDepth"]; shelfThickness = values["shelfThickness"]; lip = values.flag("lip")
        }
        var size: (width: Double, depth: Double) { footprint(columns: columns, rows: rows) }
        var inside: (width: Double, depth: Double) { (size.width - 2 * wall, size.depth - 2 * wall) }
        var top: Double { Double(height) * heightUnit }
        /// The shelf's top, 2 mm under the walls' top, and where its 45° underside meets the wall.
        var shelfTop: Double { top - 2 }
        var shelfBottom: Double { shelfTop - shelfThickness - shelfDepth }

        func body() throws -> SolidBody {
            guard shelfBottom >= floorHeight + 3 - 1e-9 else {
                throw TemplateError.tooSmall("The shelf and its support reach too near the floor. Make the bin taller or the shelf shallower.")
            }
            guard shelfDepth <= inside.depth - 10 + 1e-9 else {
                throw TemplateError.tooSmall("The shelf would cover most of the bin. Make it shallower or the bin deeper.")
            }
            var body = try bin(columns: columns, rows: rows, height: height, dividers: (0, 0), lip: lip, magnets: 0)
            // The shelf along the front wall: its profile across the bin, reaching into the walls,
            // then everything outside the bin's outline trimmed off again.
            let x0 = -inside.width / 2 - 0.6, front = -inside.depth / 2, into = front - 0.6
            let plane = SketchPlane.through(SIMD3(x0, 0, 0), normal: SIMD3(1, 0, 0)) ?? .right
            let profile = TemplateGeometry.polygon([SIMD3(x0, into, shelfTop), SIMD3(x0, front + shelfDepth, shelfTop),
                                                    SIMD3(x0, front + shelfDepth, shelfTop - shelfThickness), SIMD3(x0, into, shelfBottom - 0.6)], on: plane)
            body.cuts.append(TemplateGeometry.step(profile, depth: inside.width + 1.2, join: true))
            let outline = TemplateGeometry.roundedRectangle(width: size.width, depth: size.depth, radius: binRadius, on: .top)
            body.cuts.append(TemplateGeometry.through(TemplateGeometry.region(
                TemplateGeometry.roundedRectangle(width: size.width + 20, depth: size.depth + 20, radius: 0, on: .top), holes: [outline])))
            return body
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Grid", text: "\(columns) × \(rows) units, \(height) high"),
                TemplateMeasurement(title: "Outside", lengths: [size.width, size.depth, top + (lip ? lipHeight : 0)], text: lip ? "with the lip" : nil),
                TemplateMeasurement(title: "Inside", lengths: [inside.width, inside.depth, top - floorHeight]),
                TemplateMeasurement(title: "Label shelf", lengths: [shelfDepth], text: "deep, \(TemplateFormat.number(top - shelfTop)) mm under the top")
            ], printing: "Print it feet down.")
        }
    }

    // MARK: Pocket blocks

    /// Pockets in a solid block on feet: their outlines, all `depth` deep from the top.
    struct PocketLayout {
        var columns, rows: Int
        var top: Double
        var depth: Double
        var centers: [Point2]
        /// How far each pocket reaches from its center along x and y, and at most (its corners).
        var reach: (x: Double, y: Double, corner: Double)
        var shape: (Point2, SketchPlane) -> SketchProfile

        var size: (width: Double, depth: Double) { footprint(columns: columns, rows: rows) }
        var floor: Double { top - depth }

        func validate(spacing: (x: Double, y: Double)) throws {
            guard floor >= floorHeight - 1e-9 else {
                throw TemplateError.tooSmall("The pockets would reach below the 6 mm Gridfinity floor. Make them \(TemplateFormat.number(top - floorHeight)) mm deep or less, or the block taller.")
            }
            let xs = Set(centers.map { ($0.x * 1e6).rounded() }).count, ys = Set(centers.map { ($0.y * 1e6).rounded() }).count
            guard (xs < 2 || spacing.x - 2 * reach.x >= 2 - 1e-9), (ys < 2 || spacing.y - 2 * reach.y >= 2 - 1e-9) else {
                throw TemplateError.tooSmall("The pockets would leave less than 2 mm between them. Space them further apart or use fewer.")
            }
            guard centers.allSatisfy({ inside($0, radius: reach.corner, margin: 2, width: size.width, depth: size.depth) && abs($0.x) + reach.x <= size.width / 2 - 2 + 1e-9 && abs($0.y) + reach.y <= size.depth / 2 - 2 + 1e-9 }) else {
                throw TemplateError.tooSmall("The pockets would come within 2 mm of the edge. Use fewer or closer pockets, or a bigger grid.")
            }
        }

        func body() -> SolidBody {
            footedBlock(columns: columns, rows: rows, top: top, solid: floor) { plane in centers.map { shape($0, plane) } }
        }
    }

    static func grid(columns: Int, rows: Int, pitch: (x: Double, y: Double)) -> [Point2] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                Point2(x: (Double(column) - Double(columns - 1) / 2) * pitch.x, y: (Double(row) - Double(rows - 1) / 2) * pitch.y)
            }
        }
    }

    // MARK: Tool insert

    struct ToolInsert {
        var columns, rows, height, pocketColumns, pocketRows, shape: Int
        var size, pocketWidth, pocketLength, columnPitch, rowPitch, depth, fit: Double
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); height = values.count("height")
            shape = values.choice("shape"); size = values["size"]; pocketWidth = values["pocketWidth"]; pocketLength = values["pocketLength"]
            pocketColumns = values.count("pocketColumns"); pocketRows = values.count("pocketRows")
            columnPitch = values["columnPitch"]; rowPitch = values["rowPitch"]; depth = values["pocketDepth"]; fit = values["fit"]
        }

        var layout: PocketLayout {
            let top = Double(height) * heightUnit
            let centers = grid(columns: pocketColumns, rows: pocketRows, pitch: (columnPitch, rowPitch))
            switch shape {
            case 1:
                let flats = size + 2 * fit, r = flats / 3.squareRoot()
                return PocketLayout(columns: columns, rows: rows, top: top, depth: depth, centers: centers, reach: (r, flats / 2, r)) {
                    TemplateGeometry.hexagon(acrossFlats: flats, at: $0, on: $1)
                }
            case 2:
                let w = pocketWidth + 2 * fit, l = pocketLength + 2 * fit
                return PocketLayout(columns: columns, rows: rows, top: top, depth: depth, centers: centers,
                                    reach: (w / 2, l / 2, (w * w + l * l).squareRoot() / 2)) {
                    TemplateGeometry.roundedRectangle(center: $0, width: w, depth: l, radius: 0, on: $1)
                }
            default:
                let d = size + 2 * fit
                return PocketLayout(columns: columns, rows: rows, top: top, depth: depth, centers: centers, reach: (d / 2, d / 2, d / 2)) {
                    TemplateGeometry.circle(d, at: $0, on: $1, points: 48)
                }
            }
        }

        func body() throws -> SolidBody {
            let layout = layout
            try layout.validate(spacing: (columnPitch, rowPitch))
            return layout.body()
        }

        var notes: TemplateNotes {
            let layout = layout
            var pocket: TemplateMeasurement
            switch shape {
            case 1: pocket = TemplateMeasurement(title: "Pockets", lengths: [size + 2 * fit], text: "across the flats (hexagonal)")
            case 2: pocket = TemplateMeasurement(title: "Pockets", lengths: [pocketWidth + 2 * fit, pocketLength + 2 * fit])
            default: pocket = TemplateMeasurement(title: "Pockets", lengths: [size + 2 * fit], text: "across (round)")
            }
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Outside", lengths: [layout.size.width, layout.size.depth, layout.top]),
                pocket,
                TemplateMeasurement(title: "Pocket depth", lengths: [depth], text: "\(pocketColumns * pocketRows) pockets"),
                TemplateMeasurement(title: "Spacing", lengths: [columnPitch, rowPitch], text: "center to center"),
                TemplateMeasurement(title: "Under the pockets", lengths: [layout.floor])
            ], printing: "Print it feet down.")
        }
    }

    // MARK: Bottle holder

    struct BottleHolder {
        var columns, rows, height, bottleColumns, bottleRows: Int
        var bottle, depth, fit: Double
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); height = values.count("height")
            bottle = values["bottle"]; bottleColumns = values.count("bottleColumns"); bottleRows = values.count("bottleRows")
            depth = values["pocketDepth"]; fit = values["fit"]
        }
        var well: Double { bottle + 2 * fit }
        /// Wells spread evenly, each in its own share of the footprint.
        var spacing: (x: Double, y: Double) {
            let size = footprint(columns: columns, rows: rows)
            return (size.width / Double(bottleColumns), size.depth / Double(bottleRows))
        }
        var layout: PocketLayout {
            let d = well
            return PocketLayout(columns: columns, rows: rows, top: Double(height) * heightUnit, depth: depth,
                                centers: grid(columns: bottleColumns, rows: bottleRows, pitch: spacing), reach: (d / 2, d / 2, d / 2)) {
                TemplateGeometry.circle(d, at: $0, on: $1, points: 48)
            }
        }

        func body() throws -> SolidBody {
            let layout = layout
            try layout.validate(spacing: spacing)
            return layout.body()
        }

        var notes: TemplateNotes {
            let layout = layout
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Outside", lengths: [layout.size.width, layout.size.depth, layout.top]),
                TemplateMeasurement(title: "Wells", lengths: [well], text: "across, \(TemplateFormat.number(depth)) mm deep"),
                TemplateMeasurement(title: "Spacing", lengths: [spacing.x, spacing.y], text: "center to center"),
                TemplateMeasurement(title: "Under the wells", lengths: [layout.floor])
            ], printing: "Print it feet down. Bottles stand in the wells; don't stack a bin on top of them.")
        }
    }

    // MARK: Adapter base

    struct AdapterBase {
        var columns, rows, holeColumns, holeRows: Int
        var plate, columnPitch, rowPitch, hole: Double
        init(_ values: TemplateValues) {
            columns = values.count("columns"); rows = values.count("rows"); plate = values["plate"]
            holeColumns = values.count("holeColumns"); holeRows = values.count("holeRows")
            columnPitch = values["columnPitch"]; rowPitch = values["rowPitch"]; hole = values["hole"]
        }
        /// The plate stands on the bins' 6 mm floor datum.
        var top: Double { floorHeight + plate }
        var holes: [Point2] { holeColumns == 0 ? [] : grid(columns: holeColumns, rows: holeRows, pitch: (columnPitch, rowPitch)) }

        func body() throws -> SolidBody {
            let holes = holes
            if holeColumns > 1 || holeRows > 1 {
                guard (holeColumns < 2 || columnPitch >= hole + 2 - 1e-9), (holeRows < 2 || rowPitch >= hole + 2 - 1e-9) else {
                    throw TemplateError.tooSmall("The holes would leave less than 2 mm between them. Space them further apart.")
                }
            }
            // Each hole goes straight through a foot, inside its narrowest part, so it never cuts
            // into the tapers that seat the base.
            let cells = cellCenters(columns: columns, rows: rows)
            for point in holes {
                guard let cell = cells.min(by: { $0.distance(to: point) < $1.distance(to: point) }),
                      max(abs(point.x - cell.x), abs(point.y - cell.y)) + hole / 2 + 2 <= footBottomHalf + 1e-9 else {
                    throw TemplateError.tooSmall("A hole would cut into the feet between grid cells. Put the holes within \(TemplateFormat.number(footBottomHalf - hole / 2 - 2, digits: 1)) mm of a cell's center (cells are 42 mm apart).")
                }
            }
            var body = footedBlock(columns: columns, rows: rows, top: top)
            let face = TemplateGeometry.horizontal(top)
            for point in holes { body.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(hole, label: "Adapter"), at: point, on: face, depth: nil)) }
            return body
        }

        var notes: TemplateNotes {
            let size = footprint(columns: columns, rows: rows)
            var measurements = [
                TemplateMeasurement(title: "Outside", lengths: [size.width, size.depth, top]),
                TemplateMeasurement(title: "Plate", lengths: [plate], text: "over the 6 mm floor")
            ]
            if !holes.isEmpty {
                measurements.append(TemplateMeasurement(title: "Holes", lengths: [hole], text: "\(holes.count), through"))
                measurements.append(TemplateMeasurement(title: "Hole spacing", lengths: [holeColumns > 1 ? columnPitch : 0, holeRows > 1 ? rowPitch : 0], text: "across, front to back"))
            }
            return TemplateNotes(measurements: measurements,
                                 hardware: holes.isEmpty ? nil : "\(holes.count) \(TemplateFormat.screw(forHole: hole)) screws, with nuts or washers as your part needs.",
                                 printing: "Print it feet down; the top is the flat mounting face.")
        }
    }
}
