import Foundation
import simd

/// Workshop & Jigs (October 28, 2026, second expansion): racks, holders, and jigs for the bench.
enum WorkshopTemplates {
    static var templates: [ProjectTemplate] { [hexKeyHolder] }

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
}
