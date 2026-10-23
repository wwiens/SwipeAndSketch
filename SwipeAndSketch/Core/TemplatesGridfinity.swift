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
             summary: "A bin split into compartments by thin walls, for screws, parts, and small tools.")]
    }

    // MARK: Baseplate

    static func baseplate(id: String, title: String, magnets: Bool, summary: String) -> ProjectTemplate {
        ProjectTemplate(
            id: id, category: .gridfinity, title: title, summary: summary,
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(1...8), defaultValue: magnets ? 3 : 4, note: "Grid units of 42 mm"),
                TemplateParameter(id: "rows", title: "Depth", kind: .count(1...8), defaultValue: 3, note: "Grid units of 42 mm"),
                TemplateParameter(id: "magnets", title: "Magnet pockets", kind: .toggle, defaultValue: magnets ? 1 : 0,
                                  note: "Adds a floor with a pocket for a 6 × 2 mm magnet under each bin corner")
            ],
            name: { values in "Gridfinity Baseplate \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in
                [TemplatePart(name: "Baseplate", body: try plate(columns: values.count("columns"), rows: values.count("rows"), magnets: values.flag("magnets")))]
            })
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

    // MARK: Bins

    static let magnetChoices = ["None", "Outer corners", "Every cell"]

    static func bin(id: String, title: String, dividers: (Int, Int), summary: String) -> ProjectTemplate {
        ProjectTemplate(
            id: id, category: .gridfinity, title: title, summary: summary,
            parameters: [
                TemplateParameter(id: "columns", title: "Width", kind: .count(1...8), defaultValue: dividers.0 > 0 ? 3 : 2, note: "Grid units of 42 mm"),
                TemplateParameter(id: "rows", title: "Depth", kind: .count(1...8), defaultValue: dividers.1 > 0 ? 2 : 1, note: "Grid units of 42 mm"),
                TemplateParameter(id: "height", title: "Height", kind: .count(2...15), defaultValue: dividers.0 > 0 ? 3 : 6, note: "Height units of 7 mm"),
                TemplateParameter(id: "dividersX", title: "Dividers across", kind: .count(0...7), defaultValue: Double(dividers.0)),
                TemplateParameter(id: "dividersY", title: "Dividers front to back", kind: .count(0...7), defaultValue: Double(dividers.1)),
                TemplateParameter(id: "lip", title: "Stacking lip", kind: .toggle, defaultValue: 1, note: "Lets another bin stack on top"),
                TemplateParameter(id: "magnets", title: "Magnet holes", kind: .choice(magnetChoices), defaultValue: 0,
                                  note: "Pockets underneath for 6 × 2 mm magnets")
            ],
            name: { values in "Gridfinity Bin \(values.count("columns"))×\(values.count("rows"))×\(values.count("height"))" },
            make: { values in
                [TemplatePart(name: "Bin", body: try bin(columns: values.count("columns"), rows: values.count("rows"), height: values.count("height"),
                                                         dividers: (values.count("dividersX"), values.count("dividersY")),
                                                         lip: values.flag("lip"), magnets: values.choice("magnets")))]
            })
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

        // The feet: cut away the region around them in three steps (45° out, straight, 45° out).
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
        steps.append(TemplateGeometry.step(around(0, foot: bottom, radius: bottomRadius), depth: f.lower, taper: 45))
        steps.append(TemplateGeometry.step(around(f.lower, foot: middle, radius: middleRadius), depth: f.straight))
        steps.append(TemplateGeometry.step(around(f.lower + f.straight, foot: middle, radius: middleRadius), depth: f.upper, taper: 45))

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
