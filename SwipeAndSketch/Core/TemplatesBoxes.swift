import Foundation
import simd

/// Boxes sized by their inside, with a lid that slips on or screws on. Each comes out as two
/// solids laid side by side, ready to print: the box open side up and the lid with its outer face
/// down.
enum BoxTemplates {
    static var templates: [ProjectTemplate] {
        [ProjectTemplate(
            id: "enclosures.slip-lid-box", category: .enclosures, title: "Box with Slip-On Lid",
            summary: "A box and a lid with a rim that presses inside its walls. The rim's gap starts from your Fit setting.",
            parameters: insideParameters(width: 80, depth: 60, height: 40) + [
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.2...6, step: 0.2), defaultValue: 2),
                TemplateParameter(id: "radius", title: "Corner radius", kind: .length(0...20, step: 0.5), defaultValue: 4, note: "Outside corners"),
                TemplateParameter(id: "fit", title: "Lid fit", kind: .length(0.05...0.6, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the lid's rim; starts from the Fit in the project menu"),
                TemplateParameter(id: "vents", title: "Vent slots", kind: .toggle, defaultValue: 0)
            ],
            name: { values in "Box \(size(values))" },
            make: { values in
                try SlipLidBox(inside: Inside(values), wall: values["wall"], floor: values["wall"], radius: values["radius"],
                               fit: values["fit"], vents: values.flag("vents"), notch: false).parts(caseName: "Box")
            }),
         ProjectTemplate(
            id: "enclosures.screw-lid-box", category: .enclosures, title: "Project Box with Screw Lid",
            summary: "A box with a screw post in each corner and a flat lid with countersunk holes, for electronics or anything that stays shut.",
            parameters: insideParameters(width: 90, depth: 60, height: 35, smallest: 30) + [
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.6...6, step: 0.2), defaultValue: 2.4),
                TemplateParameter(id: "radius", title: "Corner radius", kind: .length(0...20, step: 0.5), defaultValue: 5, note: "Outside corners"),
                TemplateParameter(id: "screw", title: "Screw", kind: .choice(screwChoices), defaultValue: 1),
                TemplateParameter(id: "fixing", title: "Screws hold by", kind: .choice([Screws.Fixing.selfTapping.title, Screws.Fixing.insert.title]),
                                  defaultValue: 1),
                TemplateParameter(id: "lid", title: "Lid thickness", kind: .length(2...8, step: 0.2), defaultValue: 3)
            ],
            name: { values in "Project Box \(size(values))" },
            make: { values in
                try screwLidBox(inside: Inside(values), wall: values["wall"], radius: values["radius"],
                                screw: screwChoices[min(max(values.choice("screw"), 0), screwChoices.count - 1)],
                                fixing: values.choice("fixing") == 1 ? .insert : .selfTapping, lid: values["lid"])
            }),
         ProjectTemplate(
            id: "enclosures.screw-lid-jar", category: .enclosures, title: "Jar with Screw Lid",
            summary: "A round jar and a lid that screws onto it in about a turn, with a printable thread that needs no supports.",
            parameters: [
                TemplateParameter(id: "diameter", title: "Inside diameter", kind: .length(20...200, step: 1), defaultValue: 60),
                TemplateParameter(id: "height", title: "Inside height", kind: .length(15...300, step: 1), defaultValue: 60),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.6...6, step: 0.2), defaultValue: 2),
                TemplateParameter(id: "pitch", title: "Thread pitch", kind: .length(2...5, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "fit", title: "Lid fit", kind: .length(0.1...0.6, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap on each side of the thread; starts from the Fit in the project menu"),
                TemplateParameter(id: "ribbed", title: "Ribbed grip", kind: .toggle, defaultValue: 1)
            ],
            name: { values in
                func text(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
                return "Jar Ø\(text(values["diameter"])) × \(text(values["height"])) mm"
            },
            make: { values in
                try screwLidJar(inside: values["diameter"], height: values["height"], wall: values["wall"], pitch: values["pitch"],
                                fit: values["fit"], ribbed: values.flag("ribbed"))
            }),
         slidingLidBox]
    }

    static let screwChoices = ["M2.5", "M3", "M4"]

    // MARK: Jar with screw lid

    /// A jar (open side up) and its lid (top down) side by side: the jar's outside is its neck, made
    /// by Screw Lid, so the lid's thread is the one Screw Lid would make.
    static func screwLidJar(inside: Double, height: Double, wall: Double, pitch: Double, fit: Double, ribbed: Bool) throws -> [TemplatePart] {
        let outer = inside + 2 * wall, floor = wall, total = floor + height
        // Room for the lid beside the jar: its wall and ribs outside the thread's crest.
        let lidOuter = outer + 2 * (ThreadProfile.printable.diameterLoss * pitch / 2 + 2 + 1)
        let (jarCenter, lidCenter) = layout(outerWidth: max(outer, lidOuter))
        guard let outside = PegJoint.circle(outer, at: jarCenter, on: .top),
              let bore = PegJoint.circle(inside, at: jarCenter, on: TemplateGeometry.horizontal(total)) else {
            throw ScrewLid.Failure(message: "The jar cannot be drawn at that size.")
        }
        var jar = SolidBody(profile: outside, depth: total)
        jar.cuts.append(ExtrusionCut(profile: bore, depth: -height))
        let solid = try SolidKernel.solid(for: jar)
        guard let neck = (0..<solid.faceCount).first(where: { face in
            solid.cylinderSide(face) == 1 && abs((solid.faceCylinder(face)?.radius ?? 0) - outer / 2) < 1e-4
        }) else { throw ScrewLid.Failure(message: "The jar's outside could not be found.") }
        var spec = ScrewLidSpec(clearance: fit)
        spec.pitch = pitch
        spec.ribbed = ribbed
        let made = try ScrewLid.make(on: jar, face: neck, spec)
        // The lid turned top down onto the plate, beside the jar.
        let lidTop = (try SolidKernel.solid(for: made.lid)).bounds.max.z
        let flip = RigidTransform(rotation: simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0)), pivot: SIMD3(jarCenter.x, jarCenter.y, lidTop),
                                  translation: SIMD3(lidCenter.x - jarCenter.x, lidCenter.y - jarCenter.y, -lidTop))
        guard let lid = made.lid.transformed(by: flip) else { throw ScrewLid.Failure(message: "The lid could not be laid out.") }
        return [TemplatePart(name: "Jar", body: made.jar), TemplatePart(name: "Lid", body: lid)]
    }

    static func insideParameters(width: Double, depth: Double, height: Double, smallest: Double = 10) -> [TemplateParameter] {
        [TemplateParameter(id: "width", title: "Inside width", kind: .length(smallest...400, step: 1), defaultValue: width),
         TemplateParameter(id: "depth", title: "Inside depth", kind: .length(smallest...400, step: 1), defaultValue: depth),
         TemplateParameter(id: "height", title: "Inside height", kind: .length(5...300, step: 1), defaultValue: height)]
    }

    /// "80 × 60 × 40 mm", for project names.
    static func size(_ values: TemplateValues) -> String {
        func text(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
        return "\(text(values["width"])) × \(text(values["depth"])) × \(text(values["height"])) mm"
    }

    struct Inside {
        var width: Double
        var depth: Double
        var height: Double
        init(width: Double, depth: Double, height: Double) { self.width = width; self.depth = depth; self.height = height }
        init(_ values: TemplateValues) { self.init(width: values["width"], depth: values["depth"], height: values["height"]) }
    }

    /// Where the box and its lid sit: side by side along x, the pair centered on the origin.
    static func layout(outerWidth: Double) -> (box: Point2, lid: Point2) {
        let step = (outerWidth + 10) / 2
        return (Point2(x: -step, y: 0), Point2(x: step, y: 0))
    }

    // MARK: Slip-on lid

    /// A box and a lid whose rim presses inside the box's walls with `fit` on each side.
    struct SlipLidBox {
        var inside: Inside
        var wall: Double
        var floor: Double
        var radius: Double
        var fit: Double
        var vents: Bool
        var notch: Bool
        var lidThickness = 2.0
        var rimHeight = 4.0
        var rimWidth = 1.6

        var outerWidth: Double { inside.width + 2 * wall }
        var outerDepth: Double { inside.depth + 2 * wall }
        var outerRadius: Double { min(max(radius, 0), min(outerWidth, outerDepth) / 2 - 1) }
        var innerRadius: Double { max(0.5, outerRadius - wall) }
        var boxCenter: Point2 { layout(outerWidth: outerWidth).box }
        var lidCenter: Point2 { layout(outerWidth: outerWidth).lid }

        func parts(caseName: String) throws -> [TemplatePart] {
            // The box: a block hollowed from the top down to the floor.
            var box = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: boxCenter, width: outerWidth, depth: outerDepth,
                                                                               radius: outerRadius, on: .top), height: floor + inside.height)
            let top = TemplateGeometry.horizontal(floor + inside.height)
            box.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: boxCenter, width: inside.width, depth: inside.depth,
                                                                                    radius: innerRadius, on: top), depth: -inside.height))
            if notch {
                // An opening for a cable in the right end wall, from the top down.
                let width = min(12, inside.depth - 4), drop = min(8, inside.height - 2)
                let opening = TemplateGeometry.roundedRectangle(center: boxCenter + Point2(x: outerWidth / 2, y: 0), width: wall * 4, depth: width,
                                                                radius: 0, on: top)
                box.cuts.append(TemplateGeometry.step(opening, depth: -drop))
            }

            // The lid, outer face down, with its rim standing up inside the walls' outline.
            var lid = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: lidCenter, width: outerWidth, depth: outerDepth,
                                                                               radius: outerRadius, on: .top), height: lidThickness)
            let rimOuter = (width: inside.width - 2 * fit, depth: inside.depth - 2 * fit)
            let width = min(rimWidth, min(rimOuter.width, rimOuter.depth) / 4)
            let rimPlane = TemplateGeometry.horizontal(lidThickness)
            let rim = TemplateGeometry.region(
                TemplateGeometry.roundedRectangle(center: lidCenter, width: rimOuter.width, depth: rimOuter.depth, radius: max(0.3, innerRadius - fit), on: rimPlane),
                holes: [TemplateGeometry.roundedRectangle(center: lidCenter, width: rimOuter.width - 2 * width, depth: rimOuter.depth - 2 * width,
                                                          radius: max(0.3, innerRadius - fit - width), on: rimPlane)])
            lid.cuts.append(TemplateGeometry.step(rim, depth: min(rimHeight, inside.height / 2), join: true))
            if vents {
                // Slots across the lid, inside the rim.
                let span = rimOuter.depth - 2 * width - 8, pitch = 6.0
                let count = max(1, min(15, Int((rimOuter.width - 2 * width - 8) / pitch)))
                if span >= 6 {
                    for i in 0..<count {
                        let x = lidCenter.x + (Double(i) - Double(count - 1) / 2) * pitch
                        let slot = TemplateGeometry.roundedRectangle(center: Point2(x: x, y: lidCenter.y), width: 2.4, depth: span, radius: 1.1, on: .top)
                        lid.cuts.append(TemplateGeometry.through(slot))
                    }
                }
            }
            return [TemplatePart(name: caseName, body: box), TemplatePart(name: "Lid", body: lid)]
        }
    }

    // MARK: Screw lid

    static func screwLidBox(inside: Inside, wall: Double, radius: Double, screw: String, fixing: Screws.Fixing, lid lidThickness: Double) throws -> [TemplatePart] {
        let floor = wall
        let outerWidth = inside.width + 2 * wall, outerDepth = inside.depth + 2 * wall
        let outerRadius = min(max(radius, 0), min(outerWidth, outerDepth) / 2 - 1)
        let place = layout(outerWidth: outerWidth)
        let height = floor + inside.height

        // Corner posts, each running into both walls of its corner.
        let (spec, depth) = Screws.hole(screw, fixing, available: min(inside.height, 14))
        let post = max(spec.diameter + 3.6, Screws.clearance(screw) * 2.2)
        let inset = post / 2 - 0.4
        guard 2 * post < min(inside.width, inside.depth) else { throw TemplateError.tooSmall("The box is too small for its screw posts. Make it bigger or use a smaller screw.") }
        let offsets = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map {
            Point2(x: $0.0 * (inside.width / 2 - inset), y: $0.1 * (inside.depth / 2 - inset))
        }

        var box = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: place.box, width: outerWidth, depth: outerDepth,
                                                                           radius: outerRadius, on: .top), height: height)
        let top = TemplateGeometry.horizontal(height)
        box.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: place.box, width: inside.width, depth: inside.depth,
                                                                                radius: max(0.5, outerRadius - wall), on: top), depth: -inside.height))
        let floorPlane = TemplateGeometry.horizontal(floor)
        for offset in offsets {
            box.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(post, at: place.box + offset, on: floorPlane), depth: inside.height, join: true))
        }
        for offset in offsets { box.cuts.append(TemplateGeometry.hole(spec, at: place.box + offset, on: top, depth: depth)) }

        // The lid, outer face down, with countersunk holes over the posts.
        var lid = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: place.lid, width: outerWidth, depth: outerDepth,
                                                                           radius: outerRadius, on: .top), height: lidThickness)
        let sink = HolePresets.sizes.contains(screw) ? HolePresets.spec(.countersink, size: screw) : HolePresets.spec(.countersink, size: "M3")
        let underside = TemplateGeometry.horizontal(0, facingDown: true)
        for offset in offsets { lid.cuts.append(TemplateGeometry.hole(sink, at: place.lid + offset, on: underside, depth: nil)) }
        return [TemplatePart(name: "Box", body: box), TemplatePart(name: "Lid", body: lid)]
    }

    // MARK: Sliding lid (October 28, 2026, second expansion)

    static var slidingLidBox: ProjectTemplate {
        ProjectTemplate(
            id: "enclosures.sliding-lid-box", category: .enclosures, title: "Sliding-Lid Box",
            summary: "A box whose lid slides in along grooves in its walls, from one open end to a stop at the other.",
            parameters: [
                TemplateParameter(id: "length", title: "Inside length", kind: .length(30...250, step: 1), defaultValue: 90, note: "The way the lid slides"),
                TemplateParameter(id: "width", title: "Inside width", kind: .length(20...180, step: 1), defaultValue: 60),
                TemplateParameter(id: "height", title: "Inside height", kind: .length(10...150, step: 1), defaultValue: 35, note: "Floor to the lid's underside"),
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(2...6, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(1.6...6, step: 0.1), defaultValue: 2.4),
                TemplateParameter(id: "lid", title: "Lid thickness", kind: .length(1.6...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "engagement", title: "Groove depth", kind: .length(0.8...2, step: 0.1), defaultValue: 1,
                                  note: "How far the lid's edges reach into each wall"),
                TemplateParameter(id: "above", title: "Material above the grooves", kind: .length(1.2...3, step: 0.1), defaultValue: 1.6),
                TemplateParameter(id: "fit", title: "Lid fit", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                                  note: "Gap round the lid in its grooves; starts from the Fit in the project menu")
            ],
            name: { values in "Sliding-Lid Box \(TemplateFormat.size(values["length"], values["width"], values["height"]))" },
            make: { values in try SlidingLidBox(values).parts() },
            notes: { values in SlidingLidBox(values).notes })
    }

    struct SlidingLidBox {
        var length, width, height, wall, floor, lid, engagement, above, fit: Double
        init(_ values: TemplateValues) {
            length = values["length"]; width = values["width"]; height = values["height"]; wall = values["wall"]; floor = values["floor"]
            lid = values["lid"]; engagement = values["engagement"]; above = values["above"]; fit = values["fit"]
        }
        var outside: (length: Double, width: Double) { (length + 2 * wall, width + 2 * wall) }
        /// The lid's underside when it is closed, the groove's faces a clearance either side of the
        /// lid, and the box's top over them.
        var lidUnderside: Double { floor + height }
        var grooveBottom: Double { lidUnderside - fit }
        var grooveTop: Double { lidUnderside + lid + fit }
        var top: Double { grooveTop + above }
        var grooveWidth: Double { width + 2 * engagement }
        /// The lid runs from the entry end's outside to a clearance short of the far wall.
        var lidSize: (length: Double, width: Double) { (length + wall - fit, width + 2 * engagement - 2 * fit) }

        func parts() throws -> [TemplatePart] {
            guard wall - engagement >= 1.2 - 1e-9 else {
                throw TemplateError.tooSmall("The grooves would leave less than 1.2 mm of wall behind them. Make the walls \(TemplateFormat.number(engagement + 1.2, digits: 1)) mm thick or more, or the grooves shallower.")
            }
            guard engagement - fit >= 0.4 - 1e-9 else {
                throw TemplateError.tooSmall("The lid would barely reach into its grooves. Make them deeper than \(TemplateFormat.number(fit + 0.4, digits: 2)) mm, or use less clearance.")
            }
            let place = layout(outerWidth: max(outside.length, lidSize.length))
            // The box, open at its top; the entry end (−x) is cut down to the groove so the lid slides in.
            var box = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: place.box, width: outside.length, depth: outside.width, radius: 0, on: .top),
                                             height: top)
            box.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: place.box, width: length, depth: width, radius: 0,
                                                                                    on: TemplateGeometry.horizontal(top)), depth: -(top - floor)))
            let entry = place.box.x - length / 2
            let groove = TemplateGeometry.roundedRectangle(center: Point2(x: (entry - wall - 1 + place.box.x + length / 2) / 2, y: place.box.y),
                                                           width: length + wall + 1, depth: grooveWidth, radius: 0, on: TemplateGeometry.horizontal(grooveBottom))
            box.cuts.append(TemplateGeometry.step(groove, depth: grooveTop - grooveBottom))
            let opening = TemplateGeometry.roundedRectangle(center: Point2(x: entry - wall / 2, y: place.box.y), width: wall + 2, depth: grooveWidth, radius: 0,
                                                            on: TemplateGeometry.horizontal(grooveBottom))
            box.cuts.append(TemplateGeometry.step(opening, depth: top - grooveBottom + 1))
            // The lid lies flat beside it.
            let lidPlate = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: place.lid, width: lidSize.length, depth: lidSize.width, radius: 0, on: .top),
                                                  height: lid)
            return [TemplatePart(name: "Box", body: box), TemplatePart(name: "Lid", body: lidPlate)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Inside", lengths: [length, width, height], text: "to the lid"),
                TemplateMeasurement(title: "Outside", lengths: [outside.length, outside.width, top]),
                TemplateMeasurement(title: "Lid", lengths: [lidSize.length, lidSize.width, lid]),
                TemplateMeasurement(title: "In each groove", lengths: [engagement - fit], text: "of lid, \(TemplateFormat.number(fit)) mm clearance round it")
            ], printing: "Print the box open side up and the lid flat. Slide the lid in from the open end.")
        }
    }
}
