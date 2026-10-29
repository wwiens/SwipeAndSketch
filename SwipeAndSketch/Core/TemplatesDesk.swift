import Foundation
import simd

/// Desk & Device Stands (October 28, 2026, second expansion): stands, rests, and holders for the desk.
enum DeskTemplates {
    static var templates: [ProjectTemplate] { [deviceStand, stylusRest, headphoneStand, cardHolder] }

    static var fitParameter: TemplateParameter {
        TemplateParameter(id: "fit", title: "Clearance", kind: .length(Fit.clearanceRange, step: 0.05), defaultValue: Fit.preferredClearance,
                          note: "Gap on each side; starts from the Fit in the project menu")
    }

    // MARK: Device stand

    static var deviceStand: ProjectTemplate {
        ProjectTemplate(
            id: "desk.device-stand", category: .desk, title: "Device Stand",
            summary: "Hold a phone or tablet at a comfortable angle, with a notch for its charging cable.",
            parameters: [
                TemplateParameter(id: "preset", title: "Device", kind: .choice(DeviceStand.presetTitles), defaultValue: 0,
                                  note: "Fills in the sizes below; changing one makes it Custom"),
                TemplateParameter(id: "width", title: "Support width", kind: .length(45...200, step: 1), defaultValue: 80),
                TemplateParameter(id: "baseDepth", title: "Base depth", kind: .length(60...180, step: 1), defaultValue: 100),
                TemplateParameter(id: "supportHeight", title: "Back support height", kind: .length(50...220, step: 1), defaultValue: 100),
                TemplateParameter(id: "lean", title: "Lean (degrees)", kind: .length(5...35, step: 1), defaultValue: 15,
                                  note: "How far the back leans from upright, in degrees"),
                TemplateParameter(id: "device", title: "Device thickness", kind: .length(4...25, step: 0.1), defaultValue: 12,
                                  note: "Measured with its case"),
                fitParameter,
                TemplateParameter(id: "thickness", title: "Structural thickness", kind: .length(4...12, step: 0.5), defaultValue: 6),
                TemplateParameter(id: "lip", title: "Lip height", kind: .length(6...25, step: 1), defaultValue: 12, note: "Above the seat"),
                TemplateParameter(id: "notch", title: "Charging notch", kind: .length(0...30, step: 1), defaultValue: 14, note: "0 for none")
            ],
            name: { values in "Device Stand \(TemplateFormat.number(values["width"])) mm" },
            make: { values in [TemplatePart(name: "Device Stand", body: try DeviceStand(values).body())] },
            notes: { values in DeviceStand(values).notes },
            adjust: { values, id in DeviceStand.adjust(values, changed: id) })
    }

    struct DeviceStand {
        static let presetTitles = ["Phone", "Tablet", "Custom"]
        /// What each preset fills in (the clearance stays as it is).
        static let presets: [[String: Double]] = [
            ["width": 80, "baseDepth": 100, "supportHeight": 100, "lean": 15, "device": 12, "thickness": 6, "lip": 12, "notch": 14],
            ["width": 140, "baseDepth": 140, "supportHeight": 150, "lean": 15, "device": 14, "thickness": 8, "lip": 14, "notch": 18]
        ]

        static func adjust(_ values: TemplateValues, changed id: String) -> TemplateValues {
            var values = values
            if id == "preset" {
                let preset = values.choice("preset")
                if presets.indices.contains(preset) { for (key, value) in presets[preset] { values[key] = value } }
            } else if presets.indices.contains(values.choice("preset")), let value = presets[values.choice("preset")][id], value != values[id] {
                values["preset"] = Double(presetTitles.count - 1)
            }
            return values
        }

        var width, baseDepth, supportHeight, lean, device, fit, thickness, lip, notch: Double
        init(_ values: TemplateValues) {
            width = values["width"]; baseDepth = values["baseDepth"]; supportHeight = values["supportHeight"]; lean = values["lean"]
            device = values["device"]; fit = values["fit"]; thickness = values["thickness"]; lip = values["lip"]; notch = values["notch"]
        }
        var angle: Double { lean * .pi / 180 }
        /// The clear seat, square to the back support, and how far it runs along the base.
        var seat: Double { device + 2 * fit }
        var seatRun: Double { seat / cos(angle) }
        /// Where the back support's front face meets the seat, and the corner of its top behind.
        var seatEnd: Double { thickness + seatRun }
        var topBack: Point2 {
            let up = Point2(x: sin(angle), y: cos(angle)), out = Point2(x: cos(angle), y: -sin(angle))
            return Point2(x: seatEnd, y: thickness) + up * ((supportHeight - thickness) / cos(angle)) + out * thickness
        }

        func body() throws -> SolidBody {
            guard baseDepth >= topBack.x + 2 - 1e-9 else {
                throw TemplateError.tooSmall("The back support leans past the base. Make the base \(TemplateFormat.number((topBack.x + 2).rounded(.up))) mm deep or more, or lean it less.")
            }
            if notch > 0 {
                guard (width - notch) / 2 >= 10 - 1e-9 else {
                    throw TemplateError.tooSmall("The charging notch leaves less than 10 mm of stand beside it. Make it narrower or the stand wider.")
                }
            }
            // On its side: the profile in x (front to back) and y (up), extruded across the width.
            let t = thickness
            let up = Point2(x: sin(angle), y: cos(angle))
            let front = Point2(x: seatEnd, y: t), top = front + up * ((supportHeight - t) / cos(angle))
            let back = topBack, foot = back - up * (back.y / cos(angle))
            var stand = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: baseDepth / 2, y: t / 2), width: baseDepth, depth: t,
                                                                                 radius: 0, on: .top), height: width)
            stand.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: Point2(x: t / 2, y: (t + lip) / 2), width: t, depth: t + lip,
                                                                                      radius: 0, on: .top), depth: width, join: true))
            stand.cuts.append(TemplateGeometry.step(TemplateGeometry.polygon([Point2(x: seatEnd, y: 0), foot, back, top, front], on: .top),
                                                    depth: width, join: true))
            if notch > 0 {
                // Through the lip and the base in front of the support, in the middle of the width.
                let gap = TemplateGeometry.roundedRectangle(center: Point2(x: (seatEnd - 1) / 2, y: (t + lip) / 2), width: seatEnd + 1, depth: t + lip + 2,
                                                            radius: 0, on: TemplateGeometry.horizontal((width - notch) / 2))
                stand.cuts.append(TemplateGeometry.step(gap, depth: notch))
            }
            return stand
        }

        var notes: TemplateNotes {
            var measurements = [
                TemplateMeasurement(title: "Footprint", lengths: [width, baseDepth]),
                TemplateMeasurement(title: "Back support", lengths: [supportHeight], text: "tall, leaning \(TemplateFormat.number(lean))° from upright"),
                TemplateMeasurement(title: "Seat", lengths: [seat], text: "clear, square to the back"),
                TemplateMeasurement(title: "Lip", lengths: [lip], text: "above the seat")
            ]
            if notch > 0 { measurements.append(TemplateMeasurement(title: "Charging notch", lengths: [notch], text: "wide")) }
            return TemplateNotes(measurements: measurements, hardware: "Non-slip pads under the base, if you like.",
                                 printing: "Print it on its side, the profile flat on the plate. Check it doesn't tip with your device before relying on it.")
        }
    }

    // MARK: Stylus rest

    static var stylusRest: ProjectTemplate {
        ProjectTemplate(
            id: "desk.stylus-rest", category: .desk, title: "Stylus Rest",
            summary: "Keep a stylus or pen from rolling across your desk, in a shallow trough you lift it straight out of.",
            parameters: [
                TemplateParameter(id: "stylus", title: "Stylus diameter", kind: .length(6...16, step: 0.1), defaultValue: 9, note: "As measured"),
                fitParameter,
                TemplateParameter(id: "length", title: "Length", kind: .length(60...180, step: 1), defaultValue: 100),
                TemplateParameter(id: "width", title: "Width", kind: .length(16...50, step: 1), defaultValue: 24),
                TemplateParameter(id: "under", title: "Material under the trough", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "troughDepth", title: "Trough depth", kind: .length(1...8, step: 0.5), defaultValue: 3)
            ],
            name: { values in "Stylus Rest \(TemplateFormat.number(values["length"])) mm" },
            make: { values in [TemplatePart(name: "Stylus Rest", body: try StylusRest(values).body())] },
            // Free (user decision, October 28, 2026).
            needsPro: false,
            notes: { values in StylusRest(values).notes })
    }

    struct StylusRest {
        var radius, length, width, under, depth: Double
        init(_ values: TemplateValues) {
            radius = values["stylus"] / 2 + values["fit"]
            length = values["length"]; width = values["width"]; under = values["under"]; depth = values["troughDepth"]
        }
        var height: Double { under + depth }
        /// Half the trough's width at the top face.
        var halfOpening: Double { (radius * radius - (radius - min(depth, radius)) * (radius - min(depth, radius))).squareRoot() }

        func body() throws -> SolidBody {
            guard depth <= radius + 1e-9 else {
                throw TemplateError.tooSmall("A trough deeper than half the stylus would hold it in. Make it \(TemplateFormat.number(radius, digits: 1)) mm deep or less.")
            }
            guard width / 2 - halfOpening >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The trough leaves less than 2 mm at the sides. Make the rest \(TemplateFormat.number((2 * (halfOpening + 2)).rounded(.up))) mm wide or more.")
            }
            var rest = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: length, depth: width, radius: 3, on: .top), height: height)
            // A round trough along the length, stopping 4 mm short of each end.
            let start = SIMD3(-length / 2 + 4, 0, height + radius - depth)
            rest.cuts.append(TemplateGeometry.step(TemplateGeometry.circle(2 * radius, around: start, facing: SIMD3(1, 0, 0)), depth: length - 8))
            return rest
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Rest", lengths: [length, width, height]),
                TemplateMeasurement(title: "Trough", lengths: [2 * radius], text: "round, \(TemplateFormat.number(depth)) mm deep"),
                TemplateMeasurement(title: "Usable length", lengths: [length - 8])
            ], printing: "Print it flat side down.")
        }
    }

    // MARK: Business card holder

    static var cardHolder: ProjectTemplate {
        ProjectTemplate(
            id: "desk.card-holder", category: .desk, title: "Business Card Holder",
            summary: "Display a stack of cards in a holder sized to them, with a tall back and a low front.",
            parameters: [
                TemplateParameter(id: "cardWidth", title: "Card width", kind: .length(40...160, step: 0.5), defaultValue: 90),
                TemplateParameter(id: "cardHeight", title: "Card height", kind: .length(25...100, step: 0.5), defaultValue: 50),
                TemplateParameter(id: "stack", title: "Stack thickness", kind: .length(2...30, step: 0.5), defaultValue: 12),
                fitParameter,
                TemplateParameter(id: "wall", title: "Wall thickness", kind: .length(1.2...4, step: 0.1), defaultValue: 2),
                TemplateParameter(id: "floor", title: "Floor thickness", kind: .length(2...6, step: 0.5), defaultValue: 3),
                TemplateParameter(id: "back", title: "Back height", kind: .length(15...70, step: 1), defaultValue: 30, note: "Above the floor"),
                TemplateParameter(id: "front", title: "Front height", kind: .length(5...25, step: 1), defaultValue: 10, note: "Above the floor")
            ],
            name: { values in "Card Holder \(TemplateFormat.number(values["cardWidth"])) mm" },
            make: { values in [TemplatePart(name: "Card Holder", body: try CardHolder(values).body())] },
            notes: { values in CardHolder(values).notes })
    }

    struct CardHolder {
        var inside: (width: Double, depth: Double)
        var cardHeight, wall, floor, back, front: Double
        init(_ values: TemplateValues) {
            inside = (values["cardWidth"] + 2 * values["fit"], values["stack"] + 2 * values["fit"])
            cardHeight = values["cardHeight"]; wall = values["wall"]; floor = values["floor"]; back = values["back"]; front = values["front"]
        }
        var outside: (width: Double, depth: Double) { (inside.width + 2 * wall, inside.depth + 2 * wall) }

        func body() throws -> SolidBody {
            guard back > front + 1e-9 else { throw TemplateError.tooSmall("The back must be taller than the front.") }
            guard back < cardHeight - 1e-9 else {
                throw TemplateError.tooSmall("The back would hide the cards. Make it lower than the cards are tall (\(TemplateFormat.number(cardHeight)) mm).")
            }
            // Low walls all round with the cards' room cut from them, then the tall back added.
            var holder = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: outside.width, depth: outside.depth, radius: 0, on: .top),
                                                height: floor + front)
            let rim = TemplateGeometry.horizontal(floor + front)
            holder.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: inside.width, depth: inside.depth, radius: 0, on: rim), depth: -front))
            holder.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: (outside.depth - wall) / 2), width: outside.width,
                                                                                       depth: wall, radius: 0, on: rim), depth: back - front, join: true))
            return holder
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Inside", lengths: [inside.width, inside.depth], text: "for the stack"),
                TemplateMeasurement(title: "Back and front", lengths: [back, front], separator: " and ", text: "above the floor"),
                TemplateMeasurement(title: "Outside", lengths: [outside.width, outside.depth, floor + back])
            ], printing: "Print it floor down.")
        }
    }

    // MARK: Headphone stand

    static var headphoneStand: ProjectTemplate {
        ProjectTemplate(
            id: "desk.headphone-stand", category: .desk, title: "Headphone Stand",
            summary: "Make a three-part stand with a broad curved cradle for a headband. The post plugs into the base and the cradle.",
            parameters: [
                TemplateParameter(id: "height", title: "Height", kind: .length(120...300, step: 1), defaultValue: 220, note: "Assembled, to the top of the cradle"),
                TemplateParameter(id: "baseWidth", title: "Base width", kind: .length(100...220, step: 1), defaultValue: 160),
                TemplateParameter(id: "baseDepth", title: "Base depth", kind: .length(70...160, step: 1), defaultValue: 100),
                TemplateParameter(id: "baseThickness", title: "Base thickness", kind: .length(8...18, step: 0.5), defaultValue: 10),
                TemplateParameter(id: "postWidth", title: "Post width", kind: .length(12...30, step: 0.5), defaultValue: 18),
                TemplateParameter(id: "postDepth", title: "Post depth", kind: .length(12...30, step: 0.5), defaultValue: 18),
                TemplateParameter(id: "cradleWidth", title: "Cradle width", kind: .length(40...100, step: 1), defaultValue: 70),
                TemplateParameter(id: "cradleDepth", title: "Cradle depth", kind: .length(20...60, step: 1), defaultValue: 35),
                TemplateParameter(id: "cradleThickness", title: "Cradle thickness", kind: .length(8...18, step: 0.5), defaultValue: 10,
                                  note: "At its thinnest, the ends"),
                TemplateParameter(id: "crown", title: "Crown radius", kind: .length(40...160, step: 1), defaultValue: 80, note: "The curve the headband rests on"),
                TemplateParameter(id: "engagement", title: "Joint depth", kind: .length(3...8, step: 0.5), defaultValue: 5, note: "How far the post plugs in"),
                fitParameter
            ],
            name: { values in "Headphone Stand \(TemplateFormat.number(values["height"])) mm" },
            make: { values in try HeadphoneStand(values).parts() },
            notes: { values in HeadphoneStand(values).notes })
    }

    struct HeadphoneStand {
        var height, baseWidth, baseDepth, baseThickness, postWidth, postDepth, cradleWidth, cradleDepth, cradleThickness, crown, engagement, fit: Double
        init(_ values: TemplateValues) {
            height = values["height"]; baseWidth = values["baseWidth"]; baseDepth = values["baseDepth"]; baseThickness = values["baseThickness"]
            postWidth = values["postWidth"]; postDepth = values["postDepth"]; cradleWidth = values["cradleWidth"]; cradleDepth = values["cradleDepth"]
            cradleThickness = values["cradleThickness"]; crown = values["crown"]; engagement = values["engagement"]; fit = values["fit"]
        }
        /// The tenons are the post's section less 2 mm each side; the sockets are the tenon plus the clearance.
        var tenon: (width: Double, depth: Double) { (postWidth - 4, postDepth - 4) }
        var socket: (width: Double, depth: Double) { (tenon.width + 2 * fit, tenon.depth + 2 * fit) }
        /// How far the crown rises in the middle over its ends, and the cradle's height there.
        var sag: Double { crown - (crown * crown - cradleWidth * cradleWidth / 4).squareRoot() }
        var cradleHeight: Double { cradleThickness + sag }
        /// The post between its shoulders.
        var postLength: Double { height - baseThickness - cradleHeight }

        func parts() throws -> [TemplatePart] {
            guard crown >= cradleWidth / 2 + 1 - 1e-9 else {
                throw TemplateError.tooSmall("The crown radius must be more than half the cradle's width. Make it \(TemplateFormat.number((cradleWidth / 2 + 1).rounded(.up))) mm or more.")
            }
            guard postLength >= 2 * engagement + 20 - 1e-9 else {
                throw TemplateError.tooSmall("The stand is too short for its base and cradle. Make it \(TemplateFormat.number((baseThickness + cradleHeight + 2 * engagement + 20).rounded(.up))) mm tall or more.")
            }
            guard baseThickness - engagement >= 2 - 1e-9, cradleThickness - engagement >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The sockets need 2 mm of floor. Make the base and cradle at least \(TemplateFormat.number(engagement + 2)) mm thick, or the joint shallower.")
            }
            guard (cradleDepth - socket.depth) / 2 >= 2 - 1e-9, (cradleWidth - socket.width) / 2 >= 2 - 1e-9 else {
                throw TemplateError.tooSmall("The cradle needs 2 mm round its socket. Make it bigger or the post thinner.")
            }
            guard postWidth <= baseWidth - 20 + 1e-9, postDepth <= baseDepth - 20 + 1e-9 else {
                throw TemplateError.tooSmall("The post is too big for the base. Make the base bigger or the post thinner.")
            }
            // The base, its socket in the middle of its top.
            var base = TemplateGeometry.block(TemplateGeometry.roundedRectangle(width: baseWidth, depth: baseDepth, radius: 8, on: .top), height: baseThickness)
            base.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(width: socket.width, depth: socket.depth, radius: 0,
                                                                                     on: TemplateGeometry.horizontal(baseThickness)), depth: -engagement))
            // The post lying on its side behind the base, a tenon at each end.
            let postY = -(baseDepth / 2 + 10 + postWidth / 2)
            var post = TemplateGeometry.block(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: postY), width: postLength, depth: postWidth, radius: 0, on: .top),
                                              height: postDepth)
            for side in [-1.0, 1] {
                let plane = TemplateGeometry.horizontal(2)
                post.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: Point2(x: side * (postLength / 2 + engagement / 2 - 0.25), y: postY),
                                                                                         width: engagement + 0.5, depth: tenon.width, radius: 0, on: plane),
                                                       depth: tenon.depth, join: true))
            }
            // The cradle in front, flat side down: its profile across the width, crowned on top, extruded along its depth.
            let cradleY = baseDepth / 2 + 10, x0 = -cradleWidth / 2
            let side = SketchPlane.through(SIMD3(0, cradleY, 0), normal: SIMD3(0, 1, 0)) ?? .front
            let steps = 24
            var outline = [SIMD3(x0, cradleY, 0), SIMD3(-x0, cradleY, 0)]
            let middle = cradleHeight - crown
            for index in 0...steps {
                let x = -x0 - Double(index) * cradleWidth / Double(steps)
                outline.append(SIMD3(x, cradleY, middle + (crown * crown - x * x).squareRoot()))
            }
            var profile = TemplateGeometry.polygon(outline, on: side)
            // The crown is an exact arc: its points run from one end to the other, whichever way
            // round the outline turned out.
            let ends = [outline[2], outline[2 + steps]].map { side.coordinates(of: $0) }
            let reversed = profile.outline[0].distance(to: side.coordinates(of: outline[0])) > 1e-9
            if let start = profile.outline.firstIndex(where: { $0.distance(to: ends[reversed ? 1 : 0]) < 1e-9 }) {
                profile.arcs = [ProfileArc(start: start, segments: steps, center: side.coordinates(of: SIMD3(0, cradleY, middle)), radius: crown)]
            }
            var cradle = TemplateGeometry.block(profile, height: cradleDepth)
            cradle.cuts.append(TemplateGeometry.step(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: cradleY + cradleDepth / 2), width: socket.width,
                                                                                       depth: socket.depth, radius: 0, on: .top), depth: engagement))
            return [TemplatePart(name: "Base", body: base), TemplatePart(name: "Post", body: post), TemplatePart(name: "Cradle", body: cradle)]
        }

        var notes: TemplateNotes {
            TemplateNotes(measurements: [
                TemplateMeasurement(title: "Assembled height", lengths: [height]),
                TemplateMeasurement(title: "Cradle", lengths: [cradleWidth, cradleDepth], text: "crowned at \(TemplateFormat.number(crown)) mm radius"),
                TemplateMeasurement(title: "Base", lengths: [baseWidth, baseDepth, baseThickness]),
                TemplateMeasurement(title: "Post", lengths: [postWidth, postDepth, postLength], text: "between shoulders"),
                TemplateMeasurement(title: "Joints", lengths: [engagement], text: "deep, \(TemplateFormat.number(fit)) mm clearance a side")
            ], hardware: "Glue for the joints, if they're loose once printed.",
               printing: "Print the base and cradle flat side down and the post on its side. Check it doesn't tip with your headphones on it.")
        }
    }
}
