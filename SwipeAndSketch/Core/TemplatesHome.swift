import Foundation
import simd

/// Home & Garden (October 28, 2026, second expansion): planters, trays, and other things for around
/// the house. A valid solid isn't proof of a watertight print; the notes say to test that.
enum HomeTemplates {
    static var templates: [ProjectTemplate] { [drainingTray] }

    static var fitParameter: TemplateParameter {
        TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                          note: "Gap on each side; starts from the Fit in the project menu")
    }

    // MARK: Draining tray

    static var drainingTray: ProjectTemplate {
        ProjectTemplate(
            id: "home.draining-tray", category: .home, title: "Draining Tray",
            summary: "Let wet things drain through a slotted insert into the tray underneath, for soap, sponges, or brushes.",
            parameters: [
                TemplateParameter(id: "width", title: "Inside width", kind: .length(60...250, step: 1), defaultValue: 140),
                TemplateParameter(id: "depth", title: "Inside depth", kind: .length(40...180, step: 1), defaultValue: 90),
                TemplateParameter(id: "rim", title: "Rim height", kind: .length(10...35, step: 1), defaultValue: 15, note: "Above the floor"),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.6...5, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(1.6...5, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "insert", title: "Insert thickness", kind: .length(2...6, step: 0.5), defaultValue: 3),
                fitParameter,
                TemplateParameter(id: "gap", title: "Gap under the insert", kind: .length(3...15, step: 0.5), defaultValue: 6, note: "Where the water collects"),
                TemplateParameter(id: "slotWidth", title: "Slot width", kind: .length(2...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "slotPitch", title: "Slot spacing", kind: .length(5...16, step: 0.5), defaultValue: 8, note: "Center to center")
            ],
            name: { values in "Draining Tray \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))" },
            make: { values in try DrainingTray(values).parts() },
            notes: { values in DrainingTray(values).notes })
    }

    struct DrainingTray {
        var width, depth, rim, wall, floor, thickness, fit, gap, slotWidth, slotPitch: Double
        init(_ values: TemplateValues) {
            width = values["width"]; depth = values["depth"]; rim = values["rim"]; wall = values["wall"]; floor = values["floor"]
            thickness = values["insert"]; fit = values["fit"]; gap = values["gap"]; slotWidth = values["slotWidth"]; slotPitch = values["slotPitch"]
        }
        /// The ledges reach 3 mm in from the walls; the insert rests on them.
        static let ledge = 3.0
        static let border = 4.0
        /// A finger notch in the insert's front edge, and the band it needs.
        static let notch = 20.0
        var insert: (width: Double, depth: Double) { (width - 2 * fit, depth - 2 * fit) }
        var outside: (width: Double, depth: Double) { (width + 2 * wall, depth + 2 * wall) }
        /// Slots across the insert, front to back, clear of its border and the finger notch.
        var slotCount: Int { max(0, Int(((insert.width - 2 * Self.border - slotWidth) / slotPitch).rounded(.down)) + 1) }
        var slotSpan: (from: Double, to: Double) { (-insert.depth / 2 + Self.notch / 2 + Self.border, insert.depth / 2 - Self.border) }

        func parts() throws -> [TemplatePart] {
            guard Self.ledge - fit >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The insert would rest on less than 2 mm of ledge. Use a clearance of \(TemplateFormat.number(Self.ledge - 2)) mm or less.")
            }
            guard gap + thickness <= rim + 1e-9 else {
                throw TemplateError.tooSmall("The insert would stand above the rim. Make the rim \(TemplateFormat.number(gap + thickness)) mm or taller, or the gap or insert thinner.")
            }
            guard slotPitch - slotWidth >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The slots would leave less than 2 mm between them. Space them \(TemplateFormat.number(slotWidth + 2)) mm apart or more.")
            }
            guard slotCount > 0, slotSpan.to - slotSpan.from >= slotWidth + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The insert is too small for slots. Make the tray bigger or the slots smaller.")
            }
            // The catch tray, with a ledge round its inside up to the gap's height.
            var tray = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: outside.width, depth: outside.depth, radius: 4, on: .top), height: floor + rim)
            let rimPlane = TemplateGeometry.horizontal(floor + rim)
            tray.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: width, depth: depth, radius: max(0.5, 4 - wall), on: rimPlane), depth: -rim))
            let floorPlane = TemplateGeometry.horizontal(floor), inset = Self.ledge
            let ledge = TemplateGeometry.region(TemplateGeometry.roundedRectangle(width: width + 1, depth: depth + 1, radius: max(0.5, 4 - wall), on: floorPlane),
                                                holes: [TemplateGeometry.roundedRectangle(width: width - 2 * inset, depth: depth - 2 * inset, radius: 1, on: floorPlane)])
            tray.cuts.append(TemplateGeometry.step(ledge, depth: gap, join: true))

            // The insert lies flat beside it, with round-ended slots and a finger notch at the front.
            let center = Point2(x: outside.width / 2 + 10 + insert.width / 2, y: 0)
            var plate = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: center, width: insert.width, depth: insert.depth,
                                                                                 radius: max(0.5, 4 - wall - fit), on: .top), height: thickness)
            let reach = (slotSpan.to - slotSpan.from - slotWidth) / 2, middle = (slotSpan.from + slotSpan.to) / 2
            for index in 0..<slotCount {
                let x = center.x + (Double(index) - Double(slotCount - 1) / 2) * slotPitch
                plate.cuts.append(TemplateGeometry.through(TemplateGeometry.slot(from: Point2(x: x, y: middle - reach), to: Point2(x: x, y: middle + reach),
                                                                                 width: slotWidth, on: .top)))
            }
            plate.cuts.append(TemplateGeometry.through(TemplateGeometry.circle(Self.notch, at: Point2(x: center.x, y: -insert.depth / 2), on: .top)))
            return [TemplatePart(name: "Catch Tray", body: tray), TemplatePart(name: "Slotted Insert", body: plate)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Tray", lengths: [outside.width, outside.depth, floor + rim]),
                TemplateMeasurement(title: "Insert", lengths: [insert.width, insert.depth, thickness]),
                TemplateMeasurement(title: "Water under the insert", lengths: [gap], text: "deep"),
                TemplateMeasurement(title: "Slots", lengths: [slotWidth], text: "wide, \(slotCount) of them \(TemplateFormat.number(slotPitch)) mm apart")
            ], printing: "Print the tray floor down and the insert flat. Fill the tray with water to check it holds before relying on it.")
        }
    }
}
