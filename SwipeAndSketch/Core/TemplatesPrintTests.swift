import Foundation

/// Fit & Print Tests (October 28, 2026): small prints that find the clearances and hole sizes a
/// printer and material need. Each sample's size is engraved beside it, and a notch at the first
/// sample's corner keeps the order readable with the print turned over. Free, so everyone can
/// calibrate before making anything else.
enum PrintTestTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "tests.peg-fit", category: .tests, title: "Peg-and-Hole Fit Test",
            summary: "Find a useful clearance for printed mating parts: a plate of holes, each a little looser, and a peg to try in them.",
            parameters: [
                TemplateParameter(id: "peg", title: "Peg diameter", kind: .length(3...20, step: 0.5), defaultValue: FitTest.pegDiameter),
                TemplateParameter(id: "start", title: "Starting clearance", kind: .length(0.01...1, step: 0.05), defaultValue: FitTest.clearances[0],
                                  note: "Gap on each side of the peg in the tightest hole"),
                TemplateParameter(id: "increment", title: "Clearance increment", kind: .length(0.01...0.2, step: 0.01), defaultValue: 0.05),
                TemplateParameter(id: "samples", title: "Holes", kind: .count(3...10), defaultValue: Double(FitTest.clearances.count)),
                TemplateParameter(id: "thickness", title: "Plate thickness", kind: .length(2...10, step: 0.5), defaultValue: FitTest.plateThickness),
                TemplateParameter(id: "height", title: "Peg height", kind: .length(4...20, step: 1), defaultValue: 8)
            ],
            name: { values in "Peg Fit Test Ø\(TemplateFormat.number(values["peg"]))" },
            make: { values in try PegFit(values).parts() },
            needsPro: false,
            notes: { values in PegFit(values).notes }),
         ProjectTemplate(
            id: "tests.slide-fit", category: .tests, title: "Sliding Fit Test",
            summary: "Compare side clearances for a sliding part: open channels, each a little wider, and a slider to try in them.",
            parameters: [
                TemplateParameter(id: "width", title: "Slider width", kind: .length(5...30, step: 0.5), defaultValue: 10),
                TemplateParameter(id: "thickness", title: "Slider thickness", kind: .length(2...8, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "length", title: "Engagement length", kind: .length(15...60, step: 1), defaultValue: 30),
                TemplateParameter(id: "start", title: "Starting clearance", kind: .length(0.01...1, step: 0.05), defaultValue: 0.1,
                                  note: "Gap on each side of the slider in the tightest channel"),
                TemplateParameter(id: "increment", title: "Clearance increment", kind: .length(0.01...0.2, step: 0.01), defaultValue: 0.05),
                TemplateParameter(id: "samples", title: "Channels", kind: .count(3...9), defaultValue: 5)
            ],
            name: { values in "Sliding Fit Test \(TemplateFormat.number(values["width"])) mm" },
            make: { values in try SlideFit(values).parts() },
            needsPro: false,
            notes: { values in SlideFit(values).notes }),
         ProjectTemplate(
            id: "tests.hole-ladder", category: .tests, title: "Hole Diameter Ladder",
            summary: "Compare printed holes against a pin or screw you've measured: a row of holes, each a little bigger.",
            parameters: [
                TemplateParameter(id: "reference", title: "Reference diameter", kind: .length(1...12, step: 0.1), defaultValue: 3,
                                  note: "What you measured on the pin or fastener"),
                TemplateParameter(id: "offset", title: "Starting offset", kind: .length(-0.5...0.5, step: 0.05), defaultValue: -0.1,
                                  note: "Added to the whole diameter of the first hole, not to each side"),
                TemplateParameter(id: "increment", title: "Diameter increment", kind: .length(0.05...0.2, step: 0.01), defaultValue: 0.05,
                                  note: "Added to the whole diameter from one hole to the next"),
                TemplateParameter(id: "samples", title: "Holes", kind: .count(3...12), defaultValue: 7),
                TemplateParameter(id: "thickness", title: "Plate thickness", kind: .length(2...12, step: 0.5), defaultValue: 4)
            ],
            name: { values in "Hole Ladder Ø\(TemplateFormat.number(values["reference"]))" },
            make: { values in try HoleLadder(values).parts() },
            needsPro: false,
            notes: { values in HoleLadder(values).notes }),
         ProjectTemplate(
            id: "tests.insert-block", category: .tests, title: "Heat-Set Insert Test Block",
            summary: "Compare bore sizes for one heat-set insert: a block of blind bores around the size its maker recommends.",
            parameters: [
                TemplateParameter(id: "bore", title: "Recommended bore", kind: .length(2...12, step: 0.05), defaultValue: 4.2,
                                  note: "The hole diameter your insert's maker gives; 4.2 mm is only an example"),
                TemplateParameter(id: "insertLength", title: "Insert length", kind: .length(2...15, step: 0.5), defaultValue: 4,
                                  note: "As measured"),
                TemplateParameter(id: "depth", title: "Bore depth", kind: .length(2...20, step: 0.5), defaultValue: 5,
                                  note: "At least 0.5 mm more than the insert"),
                TemplateParameter(id: "offset", title: "Starting offset", kind: .length(-0.5...0.5, step: 0.05), defaultValue: -0.1,
                                  note: "Added to the whole diameter of the first bore, not to each side"),
                TemplateParameter(id: "increment", title: "Diameter increment", kind: .length(0.05...0.2, step: 0.01), defaultValue: 0.05),
                TemplateParameter(id: "samples", title: "Bores", kind: .count(3...9), defaultValue: 5)
            ],
            name: { values in "Insert Test Ø\(TemplateFormat.number(values["bore"]))" },
            make: { values in try InsertBlock(values).parts() },
            needsPro: false,
            notes: { values in InsertBlock(values).notes })]
    }

    /// Capital height of the engraved sizes.
    static let labelHeight = 2.5

    /// `count` sizes from `start`, `step` apart.
    static func sequence(_ start: Double, _ step: Double, _ count: Int) -> [Double] { (0..<count).map { start + Double($0) * step } }

    /// Clearances per side, the last within Fit's limit.
    static func clearances(start: Double, increment: Double, count: Int) throws -> [Double] {
        let list = sequence(start, increment, count)
        let last = list.last ?? start
        guard last <= Fit.clearanceRange.upperBound + 1e-9 else {
            throw TemplateError.tooSmall("The last sample's clearance would be \(TemplateFormat.sample(last)) mm, and clearances go up to 2 mm. Use fewer samples, a smaller increment, or a smaller starting clearance.")
        }
        return list
    }

    /// Diameters from `base` plus `offset`, `increment` apart, the first big enough to print.
    static func diameters(base: Double, offset: Double, increment: Double, count: Int, kind: String) throws -> [Double] {
        let list = sequence(base + offset, increment, count)
        guard let first = list.first, first >= 0.5 else {
            throw TemplateError.tooSmall("The first \(kind) would be \(TemplateFormat.sample(list.first ?? 0)) mm across. Use a larger diameter or a smaller negative offset.")
        }
        return list
    }

    /// How labels sit beside samples `room` mm apart: across when they fit, otherwise turned to read
    /// along the plate; and how much of the plate they take.
    static func labelLayout(_ labels: [String], room: Double) -> (angle: Double, extent: Double) {
        let widest = labels.map { TemplateGeometry.textWidth($0, height: labelHeight) }.max() ?? 0
        return widest <= room - 1.5 ? (0, labelHeight) : (90, widest)
    }

    /// A triangular notch cut from the corner at world `corner`, its legs 3 mm along the plate's
    /// edges, pointing into the plate along (`dx`, `dy`) (each ±1).
    static func notch(at corner: Point2, dx: Double, dy: Double) -> ExtrusionCut {
        let triangle = [corner + Point2(x: -dx, y: -dy), corner + Point2(x: 4 * dx, y: -dy), corner + Point2(x: -dx, y: 4 * dy)]
        return TemplateGeometry.through(TemplateGeometry.polygon(triangle, on: .top))
    }

    // MARK: Sample plate

    /// A plate with a row of round holes, blind `depth` deep or through when nil, each with its size
    /// engraved beside it and a notch by the first. Holes sit on y = 0, centered across x.
    struct SamplePlate {
        var diameters: [Double]
        var labels: [String]
        var thickness: Double
        var depth: Double?
        /// Material between the largest neighbors, and from them to the plate's edges.
        var gap: Double
        var edge: Double
        var holeLabel: String

        var widest: Double { diameters.max() ?? 0 }
        var pitch: Double { widest + gap }
        var layout: (angle: Double, extent: Double) { labelLayout(labels, room: pitch) }
        var width: Double { Double(diameters.count - 1) * pitch + widest + 2 * edge }
        var low: Double { -(widest / 2 + edge) }
        var labelY: Double { widest / 2 + 1.5 + layout.extent / 2 }
        var high: Double { widest / 2 + 1.5 + layout.extent + 2 }
        var depthAcross: Double { high - low }
        func x(_ index: Int) -> Double { (Double(index) - Double(diameters.count - 1) / 2) * pitch }

        func body() throws -> SolidBody {
            let outline = TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: (low + high) / 2), width: width, depth: depthAcross, radius: 0, on: .top)
            var plate = TemplateGeometry.block(outline, height: thickness)
            let top = TemplateGeometry.horizontal(thickness)
            for (index, diameter) in diameters.enumerated() {
                plate.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(diameter, label: holeLabel), at: Point2(x: x(index), y: 0), on: top, depth: depth))
            }
            for (index, label) in labels.enumerated() {
                plate.cuts.append(try TemplateGeometry.engraving(label, at: Point2(x: x(index), y: labelY), z: thickness, height: labelHeight, angle: layout.angle))
            }
            plate.cuts.append(notch(at: Point2(x: -width / 2, y: low), dx: 1, dy: 1))
            return plate
        }
    }

    // MARK: Peg and hole

    struct PegFit {
        var peg: Double
        var clearances: Result<[Double], Error>
        var thickness: Double
        var height: Double
        init(_ values: TemplateValues) {
            peg = values["peg"]
            clearances = Result { try PrintTestTemplates.clearances(start: values["start"], increment: values["increment"], count: values.count("samples")) }
            thickness = values["thickness"]
            height = values["height"]
        }

        func plate(_ clearances: [Double]) -> SamplePlate {
            SamplePlate(diameters: clearances.map { peg + 2 * $0 }, labels: clearances.map(TemplateFormat.sample), thickness: thickness,
                        depth: nil, gap: 4, edge: 3, holeLabel: "Fit Test")
        }
        var tab: Double { max(14, peg + 8) }

        func parts() throws -> [TemplatePart] {
            let plate = plate(try clearances.get())
            // The peg stands on a tab beside the plate, exactly its diameter, with a small lead-in.
            let center = Point2(x: -plate.width / 2 + tab / 2, y: plate.low - 6 - tab / 2)
            var piece = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: center, width: tab, depth: tab, radius: 1, on: .top), height: 3)
            let lead = min(0.5, height / 4)
            piece.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(peg, at: center, on: TemplateGeometry.horizontal(3)), depth: height - lead, join: true))
            piece.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(peg, at: center, on: TemplateGeometry.horizontal(3 + height - lead)), depth: lead,
                                                    taper: 45, join: true))
            return [TemplatePart(name: "Hole Plate", body: try plate.body()), TemplatePart(name: "Peg", body: piece)]
        }

        var notes: TemplateNotes {
            guard let clearances = try? clearances.get() else { return TemplateNotes() }
            let plate = plate(clearances)
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Plate", lengths: [plate.width, plate.depthAcross, thickness]),
                TemplateMeasurement(title: "Peg", lengths: [peg], text: "across, \(TemplateFormat.number(height)) mm tall"),
                TemplateMeasurement(title: "Clearance per side", lengths: clearances, separator: ", "),
                TemplateMeasurement(title: "Hole diameters", lengths: plate.diameters, separator: ", ")
            ], printing: "Print the plate flat and the peg standing on its tab. The notch marks the tightest hole; the first hole the peg slides into freely gives your clearance.")
        }
    }

    // MARK: Sliding fit

    struct SlideFit {
        var width: Double
        var thickness: Double
        var length: Double
        var clearances: Result<[Double], Error>
        let wall = 2.0, floor = 2.0
        init(_ values: TemplateValues) {
            width = values["width"]
            thickness = values["thickness"]
            length = values["length"]
            clearances = Result { try PrintTestTemplates.clearances(start: values["start"], increment: values["increment"], count: values.count("samples")) }
        }

        struct Layout {
            var channels: [Double]
            var centers: [Double]
            var carrierWidth: Double
            var labels: [String]
            var label: (angle: Double, extent: Double)
            /// The closed end past the channels, with the labels on it.
            var band: Double
        }

        func layout(_ clearances: [Double]) -> Layout {
            let channels = clearances.map { width + 2 * $0 }
            let carrierWidth = channels.reduce(0, +) + Double(channels.count + 1) * wall
            var centers: [Double] = []
            var x = -carrierWidth / 2 + wall
            for channel in channels { centers.append(x + channel / 2); x += channel + wall }
            let labels = clearances.map(TemplateFormat.sample)
            let label = labelLayout(labels, room: (channels.min() ?? width) + wall)
            return Layout(channels: channels, centers: centers, carrierWidth: carrierWidth, labels: labels, label: label, band: label.extent + 4)
        }

        func parts() throws -> [TemplatePart] {
            let layout = layout(try clearances.get())
            let depth = length + layout.band, height = floor + thickness
            var carrier = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: depth / 2), width: layout.carrierWidth, depth: depth,
                                                                                   radius: 0, on: .top), height: height)
            let top = TemplateGeometry.horizontal(height)
            // Channels open at the near end, as deep as the slider is thick.
            for (channel, x) in zip(layout.channels, layout.centers) {
                let opening = TemplateGeometry.roundedRectangle(center: Point2(x: x, y: (length - 1) / 2), width: channel, depth: length + 1, radius: 0, on: top)
                carrier.cuts.append(TemplateGeometry.step(opening, depth: -thickness))
            }
            for (label, x) in zip(layout.labels, layout.centers) {
                carrier.cuts.append(try TemplateGeometry.engraving(label, at: Point2(x: x, y: length + layout.band / 2), z: height,
                                                                   height: labelHeight, angle: layout.label.angle))
            }
            carrier.cuts.append(notch(at: Point2(x: -layout.carrierWidth / 2, y: depth), dx: 1, dy: -1))

            // The slider lies flat in front of the carrier: a bar longer than the channels, and a
            // wider tab to hold it by.
            let cx = -layout.carrierWidth / 2 + width / 2 + 5, tabTop = -6.0, tabBottom = tabTop - 10, end = tabBottom - (length + 5)
            let w = width / 2
            let outline = [Point2(x: cx - w, y: end), Point2(x: cx + w, y: end), Point2(x: cx + w, y: tabBottom), Point2(x: cx + w + 5, y: tabBottom),
                           Point2(x: cx + w + 5, y: tabTop), Point2(x: cx - w - 5, y: tabTop), Point2(x: cx - w - 5, y: tabBottom), Point2(x: cx - w, y: tabBottom)]
            let slider = TemplateGeometry.block(TemplateGeometry.polygon(outline, on: .top), height: thickness)
            return [TemplatePart(name: "Carrier", body: carrier), TemplatePart(name: "Slider", body: slider)]
        }

        var notes: TemplateNotes {
            guard let clearances = try? clearances.get() else { return TemplateNotes() }
            let layout = layout(clearances)
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Carrier", lengths: [layout.carrierWidth, length + layout.band, floor + thickness]),
                TemplateMeasurement(title: "Slider", lengths: [width, thickness], text: "section, \(TemplateFormat.number(length + 5)) mm long"),
                TemplateMeasurement(title: "Engagement", lengths: [length]),
                TemplateMeasurement(title: "Clearance per side", lengths: clearances, separator: ", "),
                TemplateMeasurement(title: "Channel widths", lengths: layout.channels, separator: ", ")
            ], printing: "Print the carrier channels up and the slider flat. The channels are open on top, so this measures side clearance only; the notch marks the tightest channel.")
        }
    }

    // MARK: Hole diameter ladder

    struct HoleLadder {
        var reference: Double
        var diameters: Result<[Double], Error>
        var thickness: Double
        var offset: Double
        init(_ values: TemplateValues) {
            reference = values["reference"]
            offset = values["offset"]
            diameters = Result { try PrintTestTemplates.diameters(base: values["reference"], offset: values["offset"], increment: values["increment"],
                                                                  count: values.count("samples"), kind: "hole") }
            thickness = values["thickness"]
        }

        func plate(_ diameters: [Double]) -> SamplePlate {
            SamplePlate(diameters: diameters, labels: diameters.map(TemplateFormat.sample), thickness: thickness, depth: nil, gap: 3, edge: 3, holeLabel: "Ladder")
        }

        func parts() throws -> [TemplatePart] { [TemplatePart(name: "Ladder Plate", body: try plate(try diameters.get()).body())] }

        var notes: TemplateNotes {
            guard let diameters = try? diameters.get() else { return TemplateNotes() }
            let plate = plate(diameters)
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Plate", lengths: [plate.width, plate.depthAcross, thickness]),
                TemplateMeasurement(title: "Reference", lengths: [reference]),
                TemplateMeasurement(title: "Hole diameters", lengths: diameters, separator: ", ", text: "(whole diameters, as engraved)")
            ], hardware: "The pin or fastener you measured, to try in each hole.",
               printing: "Print the plate flat. The offsets change each hole's whole diameter, not each side; the notch marks the smallest hole.")
        }
    }

    // MARK: Heat-set insert block

    struct InsertBlock {
        var diameters: Result<[Double], Error>
        var insertLength: Double
        var depth: Double
        init(_ values: TemplateValues) {
            insertLength = values["insertLength"]
            depth = values["depth"]
            diameters = Result { try PrintTestTemplates.diameters(base: values["bore"], offset: values["offset"], increment: values["increment"],
                                                                  count: values.count("samples"), kind: "bore") }
        }
        static let floor = 2.0

        func plate(_ diameters: [Double]) -> SamplePlate {
            SamplePlate(diameters: diameters, labels: diameters.map(TemplateFormat.sample), thickness: depth + Self.floor, depth: depth,
                        gap: 3, edge: 4, holeLabel: "Insert Test")
        }

        func parts() throws -> [TemplatePart] {
            guard depth >= insertLength + 0.5 - 1e-9 else {
                throw TemplateError.tooSmall("The bores must be at least 0.5 mm deeper than the insert is long. Make them \(TemplateFormat.number(insertLength + 0.5)) mm deep or more.")
            }
            return [TemplatePart(name: "Insert Block", body: try plate(try diameters.get()).body())]
        }

        var notes: TemplateNotes {
            guard let diameters = try? diameters.get() else { return TemplateNotes() }
            let plate = plate(diameters)
            return TemplateNotes(measurements: [
                TemplateMeasurement(title: "Block", lengths: [plate.width, plate.depthAcross, plate.thickness]),
                TemplateMeasurement(title: "Bore diameters", lengths: diameters, separator: ", ", text: "(as engraved)"),
                TemplateMeasurement(title: "Bore depth", lengths: [depth], text: "over a 2 mm floor")
            ], hardware: "One heat-set insert per bore (\(diameters.count)), all the same kind.",
               printing: "Print the block bores up. Press an insert into each bore and note which seat straight, crack nothing, and hold.")
        }
    }
}
