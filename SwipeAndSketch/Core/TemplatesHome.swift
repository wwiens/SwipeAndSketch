import Foundation
import simd

/// Home & Garden (October 28, 2026, second expansion): planters, trays, and other things for around
/// the house. A valid solid isn't proof of a watertight print; the notes say to test that.
enum HomeTemplates {
    static var templates: [ProjectTemplate] { [planter, drainingTray] }

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

    // MARK: Planter with saucer

    static var planter: ProjectTemplate {
        let round: @Sendable (TemplateValues) -> Bool = { $0.choice("shape") == 0 }
        let rectangular: @Sendable (TemplateValues) -> Bool = { $0.choice("shape") == 1 }
        return ProjectTemplate(
            id: "home.planter", category: .home, title: "Planter with Saucer",
            summary: "Make a planter with drain holes, narrowing toward its foot, and a saucer to stand it in.",
            parameters: [
                TemplateParameter(id: "shape", title: "Shape", kind: .choice(["Round", "Rectangular"]), defaultValue: 0),
                TemplateParameter(id: "diameter", title: "Top inside diameter", kind: .length(35...180, step: 1), defaultValue: 80, isShown: round),
                TemplateParameter(id: "width", title: "Top inside width", kind: .length(35...180, step: 1), defaultValue: 80, isShown: rectangular),
                TemplateParameter(id: "depth", title: "Top inside depth", kind: .length(35...180, step: 1), defaultValue: 80, isShown: rectangular),
                TemplateParameter(id: "height", title: "Inside height", kind: .length(30...180, step: 1), defaultValue: 80, note: "From the floor up"),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.6...5, step: 0.1), defaultValue: 2.4, note: "Measured level"),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "draft", title: "Flare (degrees)", kind: .length(0...12, step: 1), defaultValue: 5,
                                  note: "How far the walls lean out from upright, in degrees"),
                TemplateParameter(id: "drains", title: "Drain holes", kind: .count(0...12), defaultValue: 5),
                TemplateParameter(id: "drain", title: "Drain hole diameter", kind: .length(2...8, step: 0.5), defaultValue: 4),
                TemplateParameter(id: "saucerGap", title: "Saucer clearance", kind: .length(1...6, step: 0.5), defaultValue: 2, note: "Gap on each side"),
                TemplateParameter(id: "saucerRim", title: "Saucer rim height", kind: .length(8...25, step: 1), defaultValue: 12, note: "Inside, above its floor")
            ],
            name: { values in
                values.choice("shape") == 0 ? "Planter Ø\(TemplateFormat.number(values["diameter"]))"
                    : "Planter \(TemplateFormat.number(values["width"])) × \(TemplateFormat.number(values["depth"]))"
            },
            make: { values in try Planter(values).parts() },
            notes: { values in Planter(values).notes })
    }

    struct Planter {
        var round: Bool
        var top: (width: Double, depth: Double)
        var height, wall, floor, draft, drain, saucerGap, saucerRim: Double
        var drains: Int
        init(_ values: TemplateValues) {
            round = values.choice("shape") == 0
            top = round ? (values["diameter"], values["diameter"]) : (values["width"], values["depth"])
            height = values["height"]; wall = values["wall"]; floor = values["floor"]; draft = values["draft"]
            drains = values.count("drains"); drain = values["drain"]; saucerGap = values["saucerGap"]; saucerRim = values["saucerRim"]
        }
        static let saucerWall = 2.0, saucerFloor = 2.0, rib = 2.0, ribWidth = 3.0
        /// How far each side narrows over a height `h`.
        func inset(_ h: Double) -> Double { h * tan(draft * .pi / 180) }
        var bottom: (width: Double, depth: Double) { (top.width - 2 * inset(height), top.depth - 2 * inset(height)) }
        /// The outside at a height `z` above the planter's foot.
        func outside(_ z: Double) -> (width: Double, depth: Double) {
            let grow = 2 * (wall + inset(z) - inset(floor + height))
            return (top.width + grow, top.depth + grow)
        }
        /// A rectangle's corners: rounded in proportion to its size, the same inside and out.
        var corner: Double { round ? 0 : min(8, min(top.width, top.depth) / 4) }
        /// Drain holes: one in the middle, the rest on a ring.
        var drainCenters: [Point2] {
            guard drains > 0 else { return [] }
            let ring = 0.4 * min(bottom.width, bottom.depth) / 2
            let outer = drains == 1 ? 0 : (drains >= 5 ? drains - 1 : drains)
            var points = (0..<outer).map { i -> Point2 in
                let a = Double(i) * 2 * .pi / Double(outer) + .pi / Double(max(outer, 1))
                return Point2(x: cos(a), y: sin(a)) * ring
            }
            if drains == 1 || drains >= 5 { points.append(.zero) }
            return points
        }
        /// The saucer's ribs run along x, between the drain ring and the planter's foot.
        var ribY: Double { 0.75 * min(bottom.width, bottom.depth) / 2 }
        /// The planter's widest within the saucer's rim, standing on the ribs, plus the clearance.
        var saucerInside: (width: Double, depth: Double) {
            let widest = outside(saucerRim - Self.rib)
            return (widest.width + 2 * saucerGap, widest.depth + 2 * saucerGap)
        }

        func profile(_ size: (width: Double, depth: Double), radius: Double, center: Point2, z: Double) -> SketchProfile {
            round ? TemplateGeometry.circle(size.width, at: center, on: TemplateGeometry.horizontal(z))
                : TemplateGeometry.roundedRectangle(center: center, width: size.width, depth: size.depth, radius: radius, on: TemplateGeometry.horizontal(z))
        }

        func parts() throws -> [TemplatePart] {
            guard min(bottom.width, bottom.depth) >= 20 - 1e-9 else {
                throw TemplateError.tooSmall("The flare narrows the bottom to \(TemplateFormat.number(min(bottom.width, bottom.depth), digits: 1)) mm across. Make it less tall, wider at the top, or flare it less.")
            }
            let half = min(bottom.width, bottom.depth) / 2, ring = 0.4 * half
            if drains > 0 {
                guard (drains > 1 ? ring : 0) + drain / 2 <= half - 2 + 1e-9 else {
                    throw TemplateError.tooSmall("The drain holes don't fit the planter's floor. Make them smaller or the planter bigger.")
                }
                guard ribY - Self.ribWidth / 2 >= (drains > 1 ? ring : 0) + drain / 2 + 1 - 1e-9 else {
                    throw TemplateError.tooSmall("The drain holes would sit over the saucer's ribs. Make them smaller or the planter bigger.")
                }
                if drains > 1, drains < 5 || drains > 5 {
                    let outer = drains >= 5 ? drains - 1 : drains
                    guard 2 * ring * sin(.pi / Double(outer)) - drain >= 2 - 1e-9 else {
                        throw TemplateError.tooSmall("The drain holes would run into each other. Use fewer or smaller ones.")
                    }
                }
            }
            // The planter, open side up: its outside flares from the foot, its inside is cut from the rim down to the floor.
            let center = Point2(x: 0, y: 0)
            let foot = outside(0)
            var planter = TemplateGeometry.block(profile(foot, radius: corner + wall, center: center, z: 0), height: floor + height, taper: -draft)
            planter.cuts.append(TemplateGeometry.step(profile(top, radius: corner, center: center, z: floor + height), depth: -height, taper: draft))
            let underside = TemplateGeometry.horizontal(0, facingDown: true)
            for point in drainCenters { planter.cuts.append(TemplateGeometry.hole(TemplateGeometry.plainHole(drain, label: "Drain"), at: point, on: underside, depth: nil)) }

            // The saucer beside it, with two low ribs for the planter to stand on.
            let inside = saucerInside
            let saucerCenter = Point2(x: outside(floor + height).width / 2 + 10 + inside.width / 2 + Self.saucerWall, y: 0)
            var saucer = TemplateGeometry.block(profile((inside.width + 2 * Self.saucerWall, inside.depth + 2 * Self.saucerWall), radius: corner + wall + saucerGap + Self.saucerWall,
                                                        center: saucerCenter, z: 0), height: Self.saucerFloor + saucerRim)
            saucer.cuts.append(TemplateGeometry.step(profile(inside, radius: corner + wall + saucerGap, center: saucerCenter, z: Self.saucerFloor + saucerRim), depth: -saucerRim))
            // Each rib stops 1 mm short of the saucer's wall and the planter's foot, round ones measured across at the rib.
            func across(_ size: Double) -> Double {
                round ? 2 * max(0, (size / 2) * (size / 2) - (ribY + Self.ribWidth / 2) * (ribY + Self.ribWidth / 2)).squareRoot() : size
            }
            let ribPlane = TemplateGeometry.horizontal(Self.saucerFloor), ribLength = min(across(foot.width), across(inside.width)) - 2
            for side in [-1.0, 1] {
                saucer.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: saucerCenter + Point2(x: 0, y: side * ribY), width: ribLength,
                                                                                           depth: Self.ribWidth, radius: 0, on: ribPlane), depth: Self.rib, join: true))
            }
            return [TemplatePart(name: "Planter", body: planter), TemplatePart(name: "Saucer", body: saucer)]
        }

        var notes: TemplateNotes {
            var measurements = [
                TemplateMeasurement(title: "Inside at the top", lengths: round ? [top.width] : [top.width, top.depth]),
                TemplateMeasurement(title: "Inside at the floor", lengths: round ? [bottom.width] : [bottom.width, bottom.depth]),
                TemplateMeasurement(title: "Planter height", lengths: [floor + height]),
                TemplateMeasurement(title: "Drain holes", lengths: drains > 0 ? [drain] : [], text: drains > 0 ? "\(drains)" : "none"),
                TemplateMeasurement(title: "Saucer", lengths: round ? [saucerInside.width + 2 * Self.saucerWall] : [saucerInside.width + 2 * Self.saucerWall, saucerInside.depth + 2 * Self.saucerWall],
                                    text: "across, \(TemplateFormat.number(saucerRim)) mm rim")
            ]
            if !round { measurements.append(TemplateMeasurement(title: "Corner radius", lengths: [corner], text: "inside at the top")) }
            return TemplateNotes(measurements: measurements,
                                 printing: "Print both open side up. Fill the saucer with water to check it holds before standing it on furniture.")
        }
    }
}
