import Foundation
import simd

/// Workshop & Jigs (October 28, 2026, second expansion): racks, holders, and jigs for the bench.
enum WorkshopTemplates {
    static var templates: [ProjectTemplate] { [screwdriverRack, hexKeyHolder, paintRack] }

    static var fitParameter: TemplateParameter {
        TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                          note: "Gap on each side; starts from the Fit in the project menu")
    }

    // MARK: Hex key holder

    static var hexKeyHolder: ProjectTemplate {
        let custom: @Sendable (TemplateValues) -> Bool = { $0.choice("sequence") == 1 }
        return ProjectTemplate(
            id: "workshop.hex-key-holder", category: .workshop, title: "Hex Key Holder",
            summary: "Give each hex key its own labeled pocket, in order of size.",
            parameters: [
                TemplateParameter(id: "sequence", title: "Sizes", kind: .choice(["Metric starter", "Custom"]), defaultValue: 0,
                                  note: "Metric starter: 1.5, 2, 2.5, 3, 4, 5, 6, and 8 mm"),
                TemplateParameter(id: "first", title: "First size", kind: .length(1.5...8, step: 0.5), defaultValue: 2, note: "Across the flats",
                                  isShown: custom),
                TemplateParameter(id: "increment", title: "Size increment", kind: .length(0.25...2, step: 0.25), defaultValue: 0.5, isShown: custom),
                TemplateParameter(id: "count", title: "Keys", kind: .count(2...10), defaultValue: 6, isShown: custom),
                TemplateParameter(id: "depth", title: "Pocket depth", kind: .length(8...30, step: 1), defaultValue: 15),
                TemplateParameter(id: "under", title: "Material under the pockets", kind: .length(2...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "between", title: "Material between pockets", kind: .length(2...6, step: 0.5), defaultValue: 3),
                fitParameter
            ],
            name: { values in values.choice("sequence") == 0 ? "Hex Key Holder, Metric" : "Hex Key Holder \(values.count("count")) Keys" },
            make: { values in [TemplatePart(name: "Hex Key Holder", body: try HexKeyHolder(values).body())] },
            notes: { values in HexKeyHolder(values).notes })
    }

    struct HexKeyHolder {
        static let metricStarter = [1.5, 2, 2.5, 3, 4, 5, 6, 8]
        var sizes: [Double]
        var depth, under, between, fit: Double
        init(_ values: TemplateValues) {
            sizes = values.choice("sequence") == 0 ? Self.metricStarter
                : (0..<values.count("count")).map { values["first"] + Double($0) * values["increment"] }
            depth = values["depth"]; under = values["under"]; between = values["between"]; fit = values["fit"]
        }
        var labels: [String] { sizes.map { TemplateFormat.number($0) } }
        /// Pockets across the flats, and how far their corners reach.
        var flats: [Double] { sizes.map { $0 + 2 * fit } }
        var reaches: [Double] { flats.map { $0 / 3.squareRoot() } }
        var border: Double { max(between, 3) }
        /// Pocket centers along x, corner to corner `between` apart, the row centered.
        var centers: [Double] {
            var xs: [Double] = []
            for (index, reach) in reaches.enumerated() { xs.append(index == 0 ? 0 : xs[index - 1] + reaches[index - 1] + reach + between) }
            let mid = ((xs.first ?? 0) - reaches[0] + (xs.last ?? 0) + (reaches.last ?? 0)) / 2
            return xs.map { $0 - mid }
        }
        var layout: (angle: Double, extent: Double) {
            let xs = centers
            let room = zip(xs, xs.dropFirst()).map { $1 - $0 }.min() ?? 20
            return PrintTestTemplates.labelLayout(labels, room: room)
        }
        var width: Double { (reaches.first ?? 0) + (reaches.last ?? 0) + ((centers.last ?? 0) - (centers.first ?? 0)) + 2 * border }
        var low: Double { -((flats.max() ?? 0) / 2 + border) }
        var labelY: Double { (flats.max() ?? 0) / 2 + 1.5 + layout.extent / 2 }
        var high: Double { (flats.max() ?? 0) / 2 + 1.5 + layout.extent + 2 }
        var height: Double { under + depth }

        func body() throws -> SolidBody {
            let top = TemplateGeometry.horizontal(height)
            var holder = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: (low + high) / 2), width: width, depth: high - low,
                                                                                  radius: 2, on: .top), height: height)
            for (x, flats) in zip(centers, flats) {
                holder.cuts.append(TemplateGeometry.step(TemplateGeometry.hexagon(acrossFlats: flats, at: Point2(x: x, y: 0), on: top), depth: -depth))
            }
            let layout = layout
            for (x, label) in zip(centers, labels) {
                holder.cuts.append(try TemplateGeometry.engraving(label, at: Point2(x: x, y: labelY), z: height, height: PrintTestTemplates.labelHeight,
                                                                  angle: layout.angle))
            }
            return holder
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Keys", lengths: sizes, separator: ", ", text: "across the flats, as engraved"),
                TemplateMeasurement(title: "Pockets", lengths: [depth], text: "deep, each its key plus \(TemplateFormat.number(fit)) mm a side"),
                TemplateMeasurement(title: "Holder", lengths: [width, high - low, height])
            ], printing: "Print it pockets up. The labels give each key's own size, not the pocket's.")
        }
    }

    // MARK: Screwdriver rack

    static var screwdriverRack: ProjectTemplate {
        ProjectTemplate(
            id: "workshop.screwdriver-rack", category: .workshop, title: "Screwdriver Rack",
            summary: "Hang screwdrivers by their handles in a rack that screws to the wall.",
            parameters: [
                TemplateParameter(id: "count", title: "Tools", kind: .count(2...12), defaultValue: 6),
                TemplateParameter(id: "shaft", title: "Shaft diameter", kind: .length(2...15, step: 0.1), defaultValue: 6, note: "As measured"),
                fitParameter,
                TemplateParameter(id: "handle", title: "Handle diameter", kind: .length(8...45, step: 0.5), defaultValue: 20,
                                  note: "The narrowest part of the handle that rests on the rack"),
                TemplateParameter(id: "pitch", title: "Tool spacing", kind: .length(10...60, step: 1), defaultValue: 26, note: "Center to center"),
                TemplateParameter(id: "railDepth", title: "Rail depth", kind: .length(20...70, step: 1), defaultValue: 35, note: "Out from the wall"),
                TemplateParameter(id: "railThickness", title: "Rail thickness", kind: .length(4...15, step: 0.5), defaultValue: 8),
                TemplateParameter(id: "flangeHeight", title: "Back height", kind: .length(20...60, step: 1), defaultValue: 30),
                TemplateParameter(id: "flangeThickness", title: "Back thickness", kind: .length(3...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "hole", title: "Mounting holes", kind: .length(3...8, step: 0.1), defaultValue: 4.5)
            ],
            name: { values in "Screwdriver Rack \(values.count("count"))" },
            make: { values in [TemplatePart(name: "Screwdriver Rack", body: try ScrewdriverRack(values).body())] },
            notes: { values in ScrewdriverRack(values).notes })
    }

    struct ScrewdriverRack {
        var count: Int
        var opening, handle, pitch, railDepth, railThickness, flangeHeight, flangeThickness, hole: Double
        init(_ values: TemplateValues) {
            count = values.count("count"); opening = values["shaft"] + 2 * values["fit"]; handle = values["handle"]; pitch = values["pitch"]
            railDepth = values["railDepth"]; railThickness = values["railThickness"]
            flangeHeight = values["flangeHeight"]; flangeThickness = values["flangeThickness"]; hole = values["hole"]
        }
        /// The mounting holes sit beyond the end tools' handles.
        var endRoom: Double { hole + 8 }
        var width: Double { Double(count - 1) * pitch + handle + 2 * endRoom }
        /// How far out from the wall each tool hangs, its handle clear of the back.
        var reach: Double { flangeThickness + handle / 2 + 1 }
        var holeHeight: Double { railThickness + (flangeHeight - railThickness) / 2 }

        func body() throws -> SolidBody {
            guard handle >= opening + 4 - 1e-9 else {
                throw TemplateError.tooSmall("The handle needs to be at least 4 mm wider than the shaft's hole (\(TemplateFormat.number(opening, digits: 1)) mm) to rest on the rack.")
            }
            guard pitch >= handle + 1 - 1e-9 else {
                throw TemplateError.tooSmall("The handles would touch. Space the tools \(TemplateFormat.number(handle + 1)) mm apart or more.")
            }
            guard railDepth - reach - opening / 2 >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The holes would break out of the rail's front. Make the rail \(TemplateFormat.number((reach + opening / 2 + 2).rounded(.up))) mm deep or more.")
            }
            guard flangeHeight - railThickness >= hole + 4 - 1e-9 else {
                throw TemplateError.tooSmall("The back is too low for screw holes above the rail. Make it \(TemplateFormat.number((railThickness + hole + 4).rounded(.up))) mm tall or more.")
            }
            // Lying on its back: the wall plate flat on the plate (x along, y up the wall), the rail
            // standing up from its lower edge (z out from the wall).
            var rack = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: flangeHeight / 2), width: width, depth: flangeHeight,
                                                                                radius: 0, on: .top), height: flangeThickness)
            rack.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: railThickness / 2), width: width, depth: railThickness,
                                                                                     radius: 0, on: TemplateGeometry.horizontal(flangeThickness)),
                                                   depth: railDepth - flangeThickness, join: true))
            for index in 0..<count {
                let x = (Double(index) - Double(count - 1) / 2) * pitch
                rack.cuts.append(TemplateGeometry.sideHole(opening, at: SIMD3(x, 0, reach), along: SIMD3(0, -1, 0), label: "Shaft"))
            }
            let back = TemplateGeometry.horizontal(flangeThickness)
            for x in [-(width / 2 - endRoom / 2), width / 2 - endRoom / 2] {
                rack.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(hole, label: "Mounting"), at: Point2(x: x, y: holeHeight), on: back, depth: nil))
            }
            return rack
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Rack", lengths: [width, flangeHeight, railDepth], text: "wide, tall, deep"),
                TemplateMeasurement(title: "Shaft holes", lengths: [opening], text: "\(count), \(TemplateFormat.number(pitch)) mm apart"),
                TemplateMeasurement(title: "Handle rest", lengths: [(handle - opening) / 2], text: "each side of a hole"),
                TemplateMeasurement(title: "Mounting holes", lengths: [width - endRoom], text: "apart")
            ], hardware: "Two \(TemplateFormat.screw(forHole: hole)) screws, with wall anchors if the wall needs them.",
               printing: "Print it on its back, the rail standing up. Check how it holds your tools before trusting a wall to it.")
        }
    }

    // MARK: Paint bottle rack

    static var paintRack: ProjectTemplate {
        ProjectTemplate(
            id: "workshop.paint-rack", category: .workshop, title: "Paint Bottle Rack",
            summary: "Stand bottles on stepped rows, each row higher than the one in front, so every label shows.",
            parameters: [
                TemplateParameter(id: "bottle", title: "Bottle diameter", kind: .length(12...50, step: 0.1), defaultValue: 26, note: "As measured"),
                fitParameter,
                TemplateParameter(id: "columns", title: "Bottles per row", kind: .count(2...8), defaultValue: 4),
                TemplateParameter(id: "rows", title: "Rows", kind: .count(1...4), defaultValue: 2),
                TemplateParameter(id: "pocketDepth", title: "Well depth", kind: .length(4...20, step: 0.5), defaultValue: 8),
                TemplateParameter(id: "front", title: "Front row height", kind: .length(8...30, step: 1), defaultValue: 12),
                TemplateParameter(id: "rise", title: "Rise per row", kind: .length(10...40, step: 1), defaultValue: 20),
                TemplateParameter(id: "between", title: "Material between wells", kind: .length(2...8, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "border", title: "Edge border", kind: .length(2...8, step: 0.5), defaultValue: 3)
            ],
            name: { values in "Paint Rack \(values.count("columns"))×\(values.count("rows"))" },
            make: { values in [TemplatePart(name: "Paint Rack", body: try PaintRack(values).body())] },
            notes: { values in PaintRack(values).notes })
    }

    struct PaintRack {
        var well, depth, front, rise, between, border: Double
        var columns, rows: Int
        init(_ values: TemplateValues) {
            well = values["bottle"] + 2 * values["fit"]; depth = values["pocketDepth"]; front = values["front"]; rise = values["rise"]
            between = values["between"]; border = values["border"]; columns = values.count("columns"); rows = values.count("rows")
        }
        var width: Double { Double(columns) * well + Double(columns - 1) * between + 2 * border }
        /// Each row's depth front to back: at least 2 mm from a well to the step on either side.
        var row: Double { well + max(between, 4) }
        var length: Double { Double(rows) * row + 2 * border }
        func deck(_ index: Int) -> Double { front + Double(index) * rise }
        func rowStart(_ index: Int) -> Double { border + Double(index) * row }

        func body() throws -> SolidBody {
            guard front - depth >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("Leave at least 2 mm under the front wells: make the front row \(TemplateFormat.number(depth + 2)) mm tall or more, or the wells shallower.")
            }
            // The stepped side profile (y back, z up), extruded across the width.
            let x0 = -width / 2
            var points = [SIMD3(x0, 0, 0), SIMD3(x0, length, 0), SIMD3(x0, length, deck(rows - 1))]
            for index in stride(from: rows - 1, to: 0, by: -1) {
                points += [SIMD3(x0, rowStart(index), deck(index)), SIMD3(x0, rowStart(index), deck(index - 1))]
            }
            points.append(SIMD3(x0, 0, deck(0)))
            let plane = SketchPlane.through(SIMD3(x0, 0, 0), normal: SIMD3(1, 0, 0)) ?? .right
            var rack = TemplateGeometry.block(TemplateGeometry.polygon(points, on: plane), height: width)
            for index in 0..<rows {
                let top = TemplateGeometry.horizontal(deck(index)), y = rowStart(index) + row / 2
                for column in 0..<columns {
                    let x = -width / 2 + border + well / 2 + Double(column) * (well + between)
                    rack.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(well, at: Point2(x: x, y: y), on: top, points: 48), depth: -depth))
                }
            }
            return rack
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Rack", lengths: [width, length, deck(rows - 1)]),
                TemplateMeasurement(title: "Wells", lengths: [well], text: "across, \(TemplateFormat.number(depth)) mm deep, \(columns * rows) in all"),
                TemplateMeasurement(title: "Rows", lengths: (0..<rows).map(deck), separator: ", ", text: "high")
            ], printing: "Print it flat base down.")
        }
    }
}
