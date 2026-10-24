import Foundation
import FoundationModels
import simd

// The on-device model's way of working. A ~3B model drifts in tool-calling loops and mixes up
// fields in large schemas, so each request takes two kinds of small guided generations: one that
// splits the request into parts and names each part's action, then one per part that fills a
// schema made for that action alone. This code carries the parts out on the workbench and writes
// the reply from what was actually done.

/// First pass: a question to answer, or the separate changes the request asks for.
@Generable struct AssistantRequestParts {
    @Guide(description: "True when the user only asks about the model and wants nothing changed")
    var isQuestion: Bool
    @Guide(description: "For a question: the answer from the model summary, in one or two sentences with numbers in mm. Otherwise empty.")
    var answer: String
    @Guide(description: "Each separate change, in order. Keep every number that belongs to a change with it.", .maximumCount(8))
    var parts: [AssistantRequestPart]
}

@Generable struct AssistantRequestPart {
    @Guide(description: """
    new box: a new rectangular solid or plate. new cylinder: a new round solid. \
    boss / round boss: raise a rectangle / circle on a body's face. pocket / round pocket: cut a rectangle / circle into a face. \
    slot: cut a slot with rounded ends into a face. \
    hole: a round hole of a given diameter. screw hole: one metric (M2–M5) screw hole. corner screw holes: screw holes near each corner. \
    fillet: round edges. chamfer: bevel edges. shell: hollow out. set height: make a body taller or shorter. \
    move: shift a body. copy: a moved copy of a body. rotate: turn a body. delete, hide, show: a body.     extrude sketch: turn an existing sketch's shape into a solid. \
    peg: a press-fit or alignment peg (pin) with a socket in the part over it. fit test: the clearance test print. \
    thread: a screw thread in a hole or on a round boss. matching part: the nut, cap, bolt, or plug that screws onto a body's thread. \
    text: raised or sunk lettering on a face. scale: make a body bigger or smaller by a percentage or factor. \
    color: give a body a color. rename: give a body a name. \
    group: put bodies into a named group in the Model Tree (hide and show also take a group's name). \
    delete hole: remove a hole from a body. \
    change feature: change a hole, thread, text, or peg already made (its size, depth, height, or words).
    """, .anyOf(["scale", "color", "rename", "group", "delete hole", "change feature", "new box", "new cylinder", "boss", "round boss", "pocket", "round pocket", "slot", "hole", "screw hole", "corner screw holes",
                 "fillet", "chamfer", "shell", "set height", "move", "copy", "rotate", "delete", "hide", "show", "extrude sketch", "peg", "fit test", "thread", "matching part", "text"]))
    var action: String
    @Guide(description: "The user's own words for this change, copied exactly (not rephrased), with all of its numbers and sizes")
    var text: String
}

// Second pass: one small schema per action.

@Generable struct ExtrudeSketchValues {
    @Guide(description: "The sketch's exact name from the model summary, e.g. Sketch 02") var sketch: String
    @Guide(description: "How far to extrude, in mm") var distance: Double
}
@Generable struct NewBoxValues {
    @Guide(description: "Size along X in mm: the first number of \"A by B\" (all three sides are equal for a cube)") var width: Double
    @Guide(description: "Size along Y in mm: the second number of \"A by B\"") var length: Double
    @Guide(description: "Thickness or height in mm") var height: Double
}
@Generable struct NewCylinderValues {
    @Guide(description: "Diameter (size across) in mm") var diameter: Double
    @Guide(description: "Height in mm") var height: Double
}
@Generable struct BossValues {
    @Guide(description: "Size along X in mm") var width: Double
    @Guide(description: "Size along Y in mm (same as width for a square)") var length: Double
    @Guide(description: "How far it rises, in mm") var height: Double
    @Guide(description: "Face: top, bottom, front, back, left, or right", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct RoundBossValues {
    @Guide(description: "Diameter (size across) in mm") var diameter: Double
    @Guide(description: "How far it rises, in mm") var height: Double
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct PocketValues {
    @Guide(description: "Size along X in mm") var width: Double
    @Guide(description: "Size along Y in mm") var length: Double
    @Guide(description: "How deep it cuts, in mm") var depth: Double
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct RoundPocketValues {
    @Guide(description: "Diameter (size across) in mm") var diameter: Double
    @Guide(description: "How deep it cuts, in mm") var depth: Double
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct SlotValues {
    @Guide(description: "Overall length in mm, end to end") var length: Double
    @Guide(description: "Width in mm (the round ends' diameter)") var width: Double
    @Guide(description: "How deep it cuts, in mm") var depth: Double
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct HoleValues {
    @Guide(description: "Hole diameter in mm") var diameter: Double
    @Guide(description: "True when the hole goes all the way through (the usual)") var through: Bool
    @Guide(description: "Depth in mm when it does not go through") var depth: Double?
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct ScrewHoleValues {
    @Guide(description: "Screw size", .anyOf(["M2", "M2.5", "M3", "M4", "M5"])) var screw: String
    @Guide(description: "simple clearance unless the user asks otherwise", .anyOf(["simple", "counterbore", "countersink", "insert"])) var type: String
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct CornerHolesValues {
    @Guide(description: "Screw size", .anyOf(["M2", "M2.5", "M3", "M4", "M5"])) var screw: String
    @Guide(description: "simple clearance unless the user asks otherwise", .anyOf(["simple", "counterbore", "countersink", "insert"])) var type: String
    @Guide(description: "How far each hole sits in from both edges at its corner, in mm") var inset: Double
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct PegValues {
    @Guide(description: "Peg diameter in mm; 5 if not mentioned") var diameter: Double
    @Guide(description: "How far the peg stands out, in mm; 5 if not mentioned") var height: Double
    @Guide(description: "The face it stands on", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct TextValues {
    @Guide(description: "The exact words or characters to write, without quotes") var text: String
    @Guide(description: "Letter height in mm; 5 if not mentioned") var height: Double
    @Guide(description: "True for sunk (engraved, debossed) letters, false for raised (embossed)") var sunk: Bool
    @Guide(description: "Face", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var face: String
}
@Generable struct ThreadValues {
    @Guide(description: "hole for a thread inside a hole (nut), boss for one on a round post (bolt)", .anyOf(["hole", "boss"])) var face: String
    @Guide(description: "Size such as M8, M8x1 for a fine pitch, or 1/4 for inch; empty to fit the face") var size: String
}
@Generable struct FeatureEditValues {
    @Guide(description: "What is being changed", .anyOf(["hole", "thread", "text", "peg"])) var feature: String
    @Guide(description: "New size: M2 to M5 for a screw hole, M8 or M8x1 for a thread; empty to keep it") var size: String
    @Guide(description: "New diameter in mm; 0 to keep it") var diameter: Double
    @Guide(description: "New depth of a hole, or height of text or a peg, in mm; 0 to keep it") var height: Double
    @Guide(description: "New words for text, without quotes; empty to keep them") var text: String
}
@Generable struct EdgeValues {
    @Guide(description: "Which edges", .anyOf(["all", "top", "bottom", "vertical", "front", "back", "left", "right"])) var edges: String
    @Guide(description: "Fillet radius or chamfer distance in mm") var size: Double
}
@Generable struct ShellValues {
    @Guide(description: "Wall thickness in mm") var thickness: Double
    @Guide(description: "The face left open", .anyOf(["top", "bottom", "front", "back", "left", "right"])) var openFace: String
}
@Generable struct HeightValues {
    @Guide(description: "The new height in mm") var height: Double
}
@Generable struct MoveValues {
    @Guide(description: "mm to the right (+X); negative for left; 0 if not mentioned") var dx: Double
    @Guide(description: "mm to the back (+Y); negative for forward; 0 if not mentioned") var dy: Double
    @Guide(description: "mm up (+Z); negative for down; 0 if not mentioned") var dz: Double
}
@Generable struct RotateValues {
    @Guide(description: "Degrees, counterclockwise seen from above") var degrees: Double
}

@Generable struct ScaleValues {
    @Guide(description: "The new size as a percentage of the old: 200 for twice as big, 50 for half, 101 for 1% bigger") var percent: Double
}
@Generable struct ColorValues {
    @Guide(description: "The color", .anyOf(["gray", "white", "black", "red", "orange", "yellow", "green", "blue", "purple", "pink"])) var color: String
}
@Generable struct NameValues {
    @Guide(description: "The new name, exactly as the user gives it, without quotes") var name: String
}

/// Which body a part refers to, when the model has several.
@Generable struct BodyChoice {
    @Guide(description: "The body's exact name from the model summary") var body: String
}

enum AssistantPlanner {
    static let splitInstructions = """
    You read requests for Swipe & Sketch, an iPad CAD app (units mm, Z up). If the user only asks a question about the model, answer it from the model summary. Otherwise list each separate change, in order, with its action and its own words and numbers. One feature with several sizes is one part.
    Examples:
    "plate 80 by 50, 5 thick, with M3 holes 6 in from the corners" → new box "plate 80 by 50, 5 thick"; corner screw holes "M3 holes 6 in from the corners"
    "a cylinder 30 across and 40 tall" → new cylinder "cylinder 30 across and 40 tall"
    "move it up 10 and make a copy 70 to the right" → move "move it up 10"; copy "make a copy 70 to the right"
    "hollow it with 2 mm walls, open at the top" → shell "hollow it with 2 mm walls, open at the top"
    "four M4 counterbored holes near the corners, 8 in" → corner screw holes "four M4 counterbored holes near the corners, 8 in"
    "add a 4 mm alignment pin on top so the lid lines up" → peg "a 4 mm alignment pin on top so the lid lines up"
    "how tall is it?" → question, answered from the summary
    """

    static let valueInstructions = """
    You fill in the values of one change for Swipe & Sketch, an iPad CAD app, from the words given. Units are mm; Z is up. Use only numbers from the words; do not copy sizes from the model summary unless the words refer to them.
    """

    /// The hole type the words name. The model also fills in a type, but mixes them up, so the words decide.
    static func holeKind(_ words: String) -> HoleSpec.Kind {
        let words = words.lowercased()
        if words.contains("counterbor") { return .counterbore }
        if words.contains("countersink") || words.contains("countersunk") || words.contains("flat head") { return .countersink }
        if words.contains("insert") || words.contains("heat-set") || words.contains("heat set") { return .insert }
        return .simple
    }

    static let answerInstructions = """
    You answer questions about the user's model in Swipe & Sketch, an iPad CAD app, using only the model summary. Units are mm; Z is up, so a body's height is its size along Z ("tall"). Work out comparisons step by step from the numbers, then reply in one or two plain sentences.
    """

    static func split(_ prompt: String, request: String, recall: String) async throws -> AssistantRequestParts {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: splitInstructions + recall)
        var parts = try await session.respond(to: prompt, generating: AssistantRequestParts.self, options: GenerationOptions(samplingMode: .greedy)).content
        parts.parts = parts.parts.map { corrected($0, request: parts.parts.count == 1 ? request : nil) }
        return parts
    }

    static func answer(_ prompt: String, recall: String) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: answerInstructions + recall)
        return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
    }

    /// Fixes action mix-ups the words settle: round versus rectangular features, and screw holes.
    static func corrected(_ part: AssistantRequestPart, request: String? = nil) -> AssistantRequestPart {
        var part = part
        // A single-part request is all one change: its own words are the most faithful.
        if let request { part.text = request }
        let words = part.text.lowercased()
        let boxy = ["cube", "box", "block", "plate", "square", "slab", " by "].contains { words.contains($0) }
        let round = ["round", "circular", "cylind", "across", "diameter", "Ø", "disc", "disk"].contains { words.contains($0.lowercased()) }
        let screw = words.range(of: #"\bm\s?(2|2\.5|3|4|5)\b"#, options: .regularExpression) != nil || words.contains("screw")
        switch part.action {
        case "pocket" where words.contains("slot"), "round pocket" where words.contains("slot"), "hole" where words.contains("slot"): part.action = "slot"
        case "boss" where round: part.action = "round boss"
        case "round boss" where !round && (words.contains(" by ") || words.contains("square") || words.contains("rectang")): part.action = "boss"
        case "pocket" where round: part.action = "round pocket"
        case "round pocket" where !round && (words.contains(" by ") || words.contains("square") || words.contains("rectang")): part.action = "pocket"
        case "new box" where round && !boxy: part.action = "new cylinder"
        case "new cylinder" where boxy && !round: part.action = "new box"
        case "hole", "screw hole", "corner screw holes":
            if words.contains("corner") && screw { part.action = "corner screw holes" }
            else if screw { part.action = "screw hole" }
            else if part.action != "hole" && !screw { part.action = "hole" }
        default: break
        }
        return part
    }

    private static func values<T: Generable>(_ type: T.Type, for part: AssistantRequestPart, bench: AssistantWorkbench) async throws -> T {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: valueInstructions)
        let prompt = "Model now:\n\(bench.summary(maximumLines: 20))\n\nChange (\(part.action)): \(part.text)"
        return try await session.respond(to: prompt, generating: type, options: GenerationOptions(samplingMode: .greedy)).content
    }

    /// The body a part works on: the one named in its words, the one made or changed last, the
    /// selected one, the only one, or (with several) the model's pick.
    private static func body(for part: AssistantRequestPart, in bench: AssistantWorkbench) async throws -> String {
        let words = part.text.lowercased()
        for body in bench.workspace.bodies {
            let name = bench.bodyName(body.id)
            if words.contains(name.lowercased()) { return name }
        }
        if case .body(let id)? = bench.focus { return bench.bodyName(id) }
        if let selected = try? bench.item(named: "selected"), case .body(let id) = selected { return bench.bodyName(id) }
        if bench.workspace.bodies.count == 1 { return bench.bodyName(bench.workspace.bodies[0].id) }
        guard !bench.workspace.bodies.isEmpty else { throw AssistantWorkbench.Failure("there is no body yet; make one first.") }
        let choice = try await values(BodyChoice.self, for: part, bench: bench)
        guard (try? bench.body(named: choice.body)) != nil else { throw AssistantWorkbench.Failure("say which body.") }
        return choice.body
    }

    private static func positive(_ value: Double, _ what: String) throws -> Double {
        guard value.isFinite, value > 0 else { throw AssistantWorkbench.Failure("it needs a \(what) in mm.") }
        return value
    }

    /// The center of a body's face, where bosses, pockets, and holes go unless placed elsewhere.
    private static func faceCenter(_ face: String, of name: String, in bench: AssistantWorkbench) throws -> (index: Int, center: SIMD3<Double>, id: UUID) {
        let body = try bench.body(named: name), index = try bench.face(face, of: body)
        guard let center = try SolidKernel.solid(for: body).faceCenter(index) else { throw AssistantWorkbench.Failure("that face has no center.") }
        return (index, center, body.id)
    }

    /// Makes one part's change on `bench`.
    static func perform(_ part: AssistantRequestPart, on bench: inout AssistantWorkbench) async throws {
        // The sketch the part just drew in (the last shape's), which need not be the newest sketch.
        let sketchName: (AssistantWorkbench) throws -> String = { bench in
            guard let sketch = bench.workspace.sketch(bench.workspace.shapes.last?.sketch) else { throw AssistantWorkbench.Failure("the sketch was not made.") }
            return bench.name(of: .sketch(sketch.id))
        }
        switch part.action {
        case "new box":
            let v = try await values(NewBoxValues.self, for: part, bench: bench)
            try bench.addShapes([.init(kind: .rectangle, point: .zero, width: try positive(v.width, "width"), height: try positive(v.length, "length"))], on: .world(.top))
            try bench.extrude(sketch: sketchName(bench), regions: [], distance: try positive(v.height, "height"), mode: .newBody, throughAll: false)
        case "new cylinder":
            let v = try await values(NewCylinderValues.self, for: part, bench: bench)
            try bench.addShapes([.init(kind: .circle, point: .zero, diameter: try positive(v.diameter, "diameter"))], on: .world(.top))
            try bench.extrude(sketch: sketchName(bench), regions: [], distance: try positive(v.height, "height"), mode: .newBody, throughAll: false)
        case "boss", "round boss", "pocket", "round pocket":
            let name = try await body(for: part, in: bench)
            let shape: AssistantWorkbench.ShapeInput.Kind, face: String, a: Double, b: Double, distance: Double
            switch part.action {
            case "boss":
                let v = try await values(BossValues.self, for: part, bench: bench)
                (shape, face, a, b, distance) = (.rectangle, v.face, try positive(v.width, "width"), try positive(v.length > 0 ? v.length : v.width, "length"), try positive(v.height, "height"))
            case "round boss":
                let v = try await values(RoundBossValues.self, for: part, bench: bench)
                (shape, face, a, b, distance) = (.circle, v.face, try positive(v.diameter, "diameter"), 0, try positive(v.height, "height"))
            case "pocket":
                let v = try await values(PocketValues.self, for: part, bench: bench)
                (shape, face, a, b, distance) = (.rectangle, v.face, try positive(v.width, "width"), try positive(v.length > 0 ? v.length : v.width, "length"), -(try positive(v.depth, "depth")))
            default:
                let v = try await values(RoundPocketValues.self, for: part, bench: bench)
                (shape, face, a, b, distance) = (.circle, v.face, try positive(v.diameter, "diameter"), 0, -(try positive(v.depth, "depth")))
            }
            let target = try faceCenter(face, of: name, in: bench)
            let input: AssistantWorkbench.ShapeInput = shape == .circle
                ? .init(kind: .circle, point: target.center, diameter: a)
                : .init(kind: .rectangle, point: target.center, width: a, height: b)
            try bench.addShapes([input], on: .face(body: target.id, face: String(target.index)))
            try bench.extrude(sketch: sketchName(bench), regions: [], distance: distance, mode: distance > 0 ? .join : .cut, throughAll: false)
        case "slot":
            let name = try await body(for: part, in: bench)
            let v = try await values(SlotValues.self, for: part, bench: bench)
            let length = try positive(v.length, "length"), width = try positive(v.width, "width")
            guard length > width else { throw AssistantWorkbench.Failure("a slot must be longer than it is wide.") }
            let target = try faceCenter(v.face, of: name, in: bench)
            try bench.addShapes([.init(kind: .slot, point: target.center, width: length, height: width)], on: .face(body: target.id, face: String(target.index)))
            try bench.extrude(sketch: sketchName(bench), regions: [], distance: -(try positive(v.depth, "depth")), mode: .cut, throughAll: false)
        case "hole":
            let name = try await body(for: part, in: bench)
            let v = try await values(HoleValues.self, for: part, bench: bench)
            let depth = v.through ? nil : v.depth.flatMap { $0 > 0 ? $0 : nil }
            try bench.hole(body: name, face: v.face, kind: .simple, size: "", diameter: try positive(v.diameter, "diameter"), depth: depth)
        case "screw hole":
            let name = try await body(for: part, in: bench)
            let v = try await values(ScrewHoleValues.self, for: part, bench: bench)
            try bench.hole(body: name, face: v.face, kind: holeKind(part.text), size: v.screw, depth: nil)
        case "corner screw holes":
            let name = try await body(for: part, in: bench)
            let v = try await values(CornerHolesValues.self, for: part, bench: bench)
            try bench.hole(body: name, face: v.face, cornerInset: try positive(v.inset, "distance in from the corners"),
                           kind: holeKind(part.text), size: v.screw, depth: nil)
        case "fillet", "chamfer":
            let name = try await body(for: part, in: bench)
            let v = try await values(EdgeValues.self, for: part, bench: bench)
            try bench.finish(part.action == "chamfer" ? .chamfer : .fillet, body: name, edges: v.edges, size: try positive(v.size, "size"))
        case "shell":
            let name = try await body(for: part, in: bench)
            let v = try await values(ShellValues.self, for: part, bench: bench)
            try bench.shell(body: name, openFaces: [v.openFace], thickness: try positive(v.thickness, "wall thickness"))
        case "set height":
            let name = try await body(for: part, in: bench)
            let v = try await values(HeightValues.self, for: part, bench: bench)
            try bench.setDimension(item: name, dimension: "depth", value: try positive(v.height, "height"))
        case "move", "copy":
            let name = try await body(for: part, in: bench)
            let v = try await values(MoveValues.self, for: part, bench: bench)
            try bench.transform(items: [name], move: [v.dx, v.dy, v.dz], rotate: 0, axis: "z", pivot: nil, copy: part.action == "copy")
        case "rotate":
            let name = try await body(for: part, in: bench)
            let v = try await values(RotateValues.self, for: part, bench: bench)
            try bench.transform(items: [name], move: .zero, rotate: v.degrees, axis: "z", pivot: nil, copy: false)
        case "extrude sketch":
            let v = try await values(ExtrudeSketchValues.self, for: part, bench: bench)
            // The named sketch, else the selected regions and sketches, else the newest sketch that has a closed region.
            let named = try? bench.sketch(named: v.sketch)
            let name: String, chosen: [Int]
            if named == nil, !bench.selectedRegions().isEmpty {
                name = "selected"; chosen = []
            } else {
                guard let sketch = named ?? bench.workspace.sketches.last(where: { !bench.regions(of: $0).isEmpty }) else {
                    throw AssistantWorkbench.Failure("there is no sketch with a closed shape to extrude.")
                }
                name = bench.name(of: .sketch(sketch.id)); chosen = bench.regions(of: sketch).count > 1 ? [1] : []
            }
            let distance = try positive(abs(v.distance), "distance")
            // Extruding adds material unless the words say to remove it.
            let words = part.text.lowercased()
            if ["cut", "remove", "subtract", "hole", "pocket"].contains(where: words.contains) {
                try bench.extrude(sketch: name, regions: chosen, distance: distance, mode: .cut, throughAll: false)
            } else if (try? bench.extrude(sketch: name, regions: chosen, distance: distance, mode: .join, throughAll: false)) == nil {
                try bench.extrude(sketch: name, regions: chosen, distance: distance, mode: .newBody, throughAll: false)
            }
        case "peg":
            let name = try await body(for: part, in: bench)
            let v = try await values(PegValues.self, for: part, bench: bench)
            let words = part.text.lowercased()
            let separate = ["separate", "dowel", "loose", "own body", "printed apart"].contains(where: words.contains)
            try bench.peg(body: name, face: v.face, diameter: v.diameter > 0 ? v.diameter : 5, height: v.height > 0 ? v.height : 5,
                          clearance: Fit.preferredClearance, separate: separate)
        case "fit test":
            try bench.fitTest()
        case "text":
            let name = try await body(for: part, in: bench)
            let v = try await values(TextValues.self, for: part, bench: bench)
            let words = part.text.lowercased()
            let sunk = v.sunk || ["engrav", "deboss", "sunk", "cut into", "recess"].contains(where: words.contains)
            try bench.text(body: name, face: v.face, text: v.text, height: v.height > 0 ? v.height : 5, depth: sunk ? -0.8 : 0.8)
        case "thread":
            let name = try await body(for: part, in: bench)
            let v = try await values(ThreadValues.self, for: part, bench: bench)
            let words = part.text.lowercased()
            try bench.thread(body: name, face: v.face, size: v.size.isEmpty ? nil : v.size, diameter: nil, pitch: nil,
                             clearance: Fit.preferredClearance, leftHanded: words.contains("left"),
                             raised: ["raised", "raise", "add the ridges", "thin wall"].contains(where: words.contains))
        case "matching part":
            let name = try await body(for: part, in: bench)
            let words = part.text.lowercased()
            let kind = [("cap", "cap"), ("lid", ""), ("plug", "plug"), ("nut", "nut"), ("bolt", "bolt"), ("screw", "bolt")].first { words.contains($0.0) }?.1
            try bench.matingPart(body: name, kind: kind)
        case "scale":
            let name = try await body(for: part, in: bench)
            let v = try await values(ScaleValues.self, for: part, bench: bench)
            // Scaled about its base, so a part on the plate stays there.
            try bench.scale(items: [name], percent: try positive(v.percent, "percentage"), percents: nil, about: "base", copy: false)
        case "color":
            let name = try await body(for: part, in: bench)
            let v = try await values(ColorValues.self, for: part, bench: bench)
            try bench.setColor(body: name, color: v.color)
        case "rename":
            let name = try await body(for: part, in: bench)
            let v = try await values(NameValues.self, for: part, bench: bench)
            try bench.rename(item: name, to: v.name)
        case "delete":
            try bench.delete(items: [try await body(for: part, in: bench)])
        case "change feature":
            // The body's newest one of the kind its words name.
            let name = try await body(for: part, in: bench)
            let v = try await values(FeatureEditValues.self, for: part, bench: bench)
            let words = part.text.lowercased()
            let named = [("thread", "thread"), ("peg", "peg"), ("pin", "peg"), ("text", "text"), ("label", "text"), ("letter", "text"),
                         ("word", "text"), ("hole", "hole")].first { words.contains($0.0) }?.1
            let feature = named ?? v.feature
            let size = v.size.trimmingCharacters(in: .whitespaces)
            switch feature {
            case "hole":
                try bench.editFeature(body: name, feature: feature, which: "last", kind: holeKind(words) == .simple ? nil : holeKind(words).rawValue,
                                      size: size.isEmpty ? nil : size, diameter: v.diameter > 0 ? v.diameter : nil,
                                      depth: v.height > 0 ? v.height : nil, through: words.contains("through") ? true : nil)
            case "thread":
                try bench.editFeature(body: name, feature: feature, which: "last", size: size.isEmpty ? nil : size)
            case "text":
                try bench.editFeature(body: name, feature: feature, which: "last", height: v.height > 0 ? v.height : nil,
                                      text: v.text.isEmpty ? nil : v.text)
            default:
                try bench.editFeature(body: name, feature: "peg", which: "last", diameter: v.diameter > 0 ? v.diameter : nil,
                                      height: v.height > 0 ? v.height : nil)
            }
        case "delete hole":
            // The selected hole, or else the body's first.
            let name = try await body(for: part, in: bench)
            do { try bench.deleteHole(body: name, face: "selected") } catch { try bench.deleteHole(body: name, face: "hole") }
        case "hide", "show":
            // A group named in the request goes with everything in it.
            let words = part.text.lowercased()
            let group = bench.workspace.groupNames.values.sorted { $0.count > $1.count }.first { words.contains($0.lowercased()) }
            let item: String
            if let group { item = group } else { item = try await body(for: part, in: bench) }
            try bench.setHidden(items: [item], hidden: part.action == "hide")
        case "group":
            let words = part.text.lowercased()
            var names = bench.workspace.bodies.map { bench.bodyName($0.id) }.filter { words.contains($0.lowercased()) }
            if names.isEmpty { names = [try await body(for: part, in: bench)] }
            let v = try await values(NameValues.self, for: part, bench: bench)
            try bench.group(items: names, into: nil, newName: v.name.isEmpty ? nil : v.name)
        default:
            throw AssistantWorkbench.Failure("that is not something I can do yet.")
        }
    }
}
