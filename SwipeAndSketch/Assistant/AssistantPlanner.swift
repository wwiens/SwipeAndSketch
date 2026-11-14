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
    slip lid box: a new enclosure with a slip-on lid made from the native template, preserving all sizes in one action. \
    new box: a new rectangular solid or plate. new cylinder: a new round solid. new sphere: a ball. new torus: a ring or donut. \
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
    """, .anyOf(["slip lid box", "scale", "color", "rename", "group", "delete hole", "change feature", "new sphere", "new torus", "new box", "new cylinder", "boss", "round boss", "pocket", "round pocket", "slot", "hole", "screw hole", "corner screw holes",
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
@Generable struct SlipLidBoxValues {
    @Guide(description: "inside=cavity; outside=box without lid; closed=assembled box including lid; unspecified if the user does not say", .anyOf(["inside", "outside", "closed", "unspecified"])) var reference: String
    var width: Double
    var depth: Double
    var height: Double
    @Guide(description: "Same wall/floor thickness; omit if unspecified") var wall: Double?
    @Guide(description: "Outside corner radius; omit if unspecified") var radius: Double?
    @Guide(description: "Lid gap per side, or half an explicitly total gap; omit if unspecified") var clearance: Double?
    var vents: Bool?
    @Guide(description: "Lid plate (top) thickness in mm, only if the words give one") var lidPlate: Double?
    @Guide(description: "Height of the lid's rim in mm, only if the words give one") var rimHeight: Double?
    @Guide(description: "Floor thickness in mm, only if the words give one apart from the walls") var floor: Double?
    @Guide(description: "Exact number of vent slots, only if the words give a number") var ventCount: Int?
}
@Generable struct NewSphereValues {
    @Guide(description: "Diameter (size across) in mm") var diameter: Double
}
@Generable struct NewTorusValues {
    @Guide(description: "Diameter of the ring, through the middle of the tube, in mm") var diameter: Double
    @Guide(description: "Thickness of the tube in mm") var tube: Double
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
    "make a box with a slip-on lid, inside 80 by 60 by 40" → slip lid box "make a box with a slip-on lid, inside 80 by 60 by 40"
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
        // Routing by words replaces whatever the splitter returns, so a routed request need not ask it.
        if AssistantEngine.plannerSkipRoutedSplit, let part = route(request) {
            return AssistantRequestParts(isQuestion: false, answer: "", parts: [part])
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: splitInstructions + recall)
        var parts = try await session.respond(to: prompt, generating: AssistantRequestParts.self, options: GenerationOptions(samplingMode: .greedy)).content
        parts.parts = parts.parts.map { corrected($0, request: parts.parts.count == 1 ? request : nil) }
        if let part = route(request) { parts.isQuestion = false; parts.parts = [part] }
        return parts
    }

    /// The one part the words route a request to, if any: a single feature edit or removal before
    /// the lid-box recipe, as each routing is switched on.
    static func route(_ request: String) -> AssistantRequestPart? {
        if AssistantEngine.plannerFeatureRouting, let edit = featureEdit(request) { return edit }
        if AssistantEngine.plannerRecipeRouting, let recipe = routed(request) { return recipe }
        return nil
    }

    /// A box with a lid is one native recipe, or none: the words decide, since the model tends to
    /// call it a plain new box and to split its sizes into separate changes. The whole request
    /// becomes one part, so every size stays with it and nothing is built piecemeal.
    static func routed(_ request: String) -> AssistantRequestPart? {
        let words = request.lowercased()
        let slip = words.range(of: #"slip[- ]?on lid|slip[- ]?lid|lid (that )?slips"#, options: .regularExpression) != nil
        // Another kind of lid, named as such; a lid named only as a part ("leave Lid unchanged") is not one.
        let other = words.range(of: #"\b(hinged?|slid(es|ing|e)|screw(s|ed)?[- ]?(on|top)?|snap(s|[- ]fit)?|magnetic|twist)\b[^.]*\blids?\b|\blids?\b[^.]*\b(hinged?|slid(es|ing|e)|screws? on|snaps? on|twists? on)\b"#,
                                options: .regularExpression) != nil
        if slip { return AssistantRequestPart(action: "slip lid box", text: request) }
        if other { return AssistantRequestPart(action: "other lid", text: request) }
        return nil
    }

    /// One existing feature edited, by its words: a single sentence whose object (after a verb
    /// that does not make or finish features) or subject is a definite hole, peg, thread, or text
    /// ("Extend the blind hole …", "Give the peg …", "The peg needs to be …"). It becomes one
    /// feature change with the whole request, or one hole removal when the words remove the hole,
    /// so the splitter cannot rewrite it, add steps, or name it a new feature.
    static func featureEdit(_ request: String) -> AssistantRequestPart? {
        let text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.replacingOccurrences(of: #"[.!?\s]+$"#, with: "", options: .regularExpression)
        guard body.range(of: #"[.;?!](\s|$)"#, options: .regularExpression) == nil,
              body.range(of: #"^(what|how|why|which|where|is|are|does|do|can you tell)\b"#, options: .regularExpression) == nil else { return nil }
        let feature = #"(?:the|that|this|its|my)\s+(?:[\w'-]+\s+){0,2}?(?:holes?|through-holes?|pegs?|pins?|threads?|text|lettering|labels?)\b"#
        let finishing = #"(?:thread|tap|chamfer|fillet|round|countersink|counterbore|bevel|mirror|copy|move|pattern|rotate|hide|show|colou?r|rename|duplicate|add|group)\b"#
        let object = #"^(?:please\s+)?(?!"# + finishing + #")(?:[a-z']+\s+){1,3}?"# + feature
        guard body.range(of: object, options: .regularExpression) != nil || body.range(of: "^" + feature, options: .regularExpression) != nil else { return nil }
        return AssistantRequestPart(action: removesHole(text) ? "delete hole" : "change feature", text: request)
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
        // The splitter names "drill a hole" requests "delete hole"; only removal words mean that.
        if AssistantEngine.plannerHoleCorrection, part.action == "delete hole", !removesHole(words) { part.action = "hole" }
        // And sizes for a feature "set height", which would resize the whole body.
        if AssistantEngine.plannerFeatureSizeCorrection, part.action == "set height", sizesFeature(words) { part.action = "change feature" }
        // It also names requests for new holes "change feature".
        if AssistantEngine.plannerNewHoleCorrection, part.action == "change feature", makesHole(words), !changesHole(words) { part.action = "hole" }
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

    /// Whether a delete step is the splitter's own: the user's request does not ask to remove a
    /// hole (for "delete hole") or anything (for "delete"), and does not replace or swap it.
    static func inventsRemoval(_ part: AssistantRequestPart, request: String) -> Bool {
        let words = request.lowercased()
        let replaces = words.range(of: #"\b(replace|swap)\w*\b"#, options: .regularExpression) != nil
        switch part.action {
        case "delete hole": return !removesHole(words) && !replaces
        case "delete": return !replaces && words.range(of: #"\b(delete|remove|get rid of|erase|discard|throw away|take away)\b"#, options: .regularExpression) == nil
        default: return false
        }
    }

    /// Whether the words ask to take a hole away rather than make one: a removal word acting on
    /// the hole itself ("fill in the 10 mm hole", "the hole removed"), not on something else
    /// in the same request ("delete Base, and drill a hole").
    static func removesHole(_ words: String) -> Bool {
        let text = words.lowercased()
        return text.range(of: #"\b(delete|remove|fill|plug|erase|get rid of|take out|take away|close up)\b(\s+(in|up|out))?\s+([^\s,.;]+\s+){0,4}?[^\s,.;]*holes?\b"#, options: .regularExpression) != nil
            || text.range(of: #"\bholes?\b[^,.;]{0,30}\b(removed|deleted|filled)\b"#, options: .regularExpression) != nil
    }

    /// Whether the thing the words size is a feature: a sizing verb whose object is a peg, pin,
    /// hole, thread, or text ("make the pin 9 mm high", "lengthen the plate's peg"), not a body
    /// that merely has one ("make the plate 8 mm thick, keeping the hole").
    static func sizesFeature(_ words: String) -> Bool {
        words.lowercased().range(of: #"\b(make|set|change|raise|lengthen|extend|increase|grow|deepen|shorten|lower|reduce)\s+(the|that|this|its|my|each|every|all)\s+([\w']+\s+){0,2}?(pegs?|pins?|holes?|threads?|text|lettering|labels?)\b"#, options: .regularExpression) != nil
    }

    /// Whether the words make a new hole: a making verb with a count or an indefinite article
    /// ("drill four M3 holes", "add a second through-hole"), or a hole that is "drilled".
    static func makesHole(_ words: String) -> Bool {
        let text = words.lowercased()
        return text.range(of: #"\b(drill|bore|punch|add|put|make|cut|create)\s+(in\s+)?(a|an|one|two|three|four|five|six|\d+|another|new)\b[^.;]{0,60}?holes?\b"#, options: .regularExpression) != nil
            || text.range(of: #"\bholes?\s+(drilled|bored|punched)\b"#, options: .regularExpression) != nil
    }

    /// Whether the words change a hole that is already there ("change only the hole at X=25",
    /// "make the hole smaller").
    static func changesHole(_ words: String) -> Bool {
        words.lowercased().range(of: #"\b(change|resize|enlarge|widen|shrink|increase|decrease|reduce|make|set|adjust)\s+(only\s+)?(the|that|this|its|existing|both|each|every|all)\b[^.;]{0,40}?holes?\b"#, options: .regularExpression) != nil
    }

    /// The feature edit's values the words state: a depth or height only when its number sits
    /// with a depth, height, or (switched on) length word ("3 mm deep", "deepen … to 9 mm",
    /// "10 mm tall", "lengthen the peg to 12 mm"), a diameter only
    /// when its number is in the words and is not that depth (unless a diameter word goes with it),
    /// and a size or text only when the words contain it. Others go back to "keep", unless that
    /// would leave nothing to change.
    static func mentioned(_ values: FeatureEditValues, in words: String) -> FeatureEditValues {
        var v = values
        let text = words.lowercased()
        func near(_ value: Double, _ keywords: [String]) -> Bool { keywords.contains { mentions(value, near: $0, in: text) } }
        var deep = ["deep", "depth", "tall", "height", "high", "long"]
        if AssistantEngine.plannerLengthWords { deep += ["length", "extend", "shorten", "shorter"] }
        let wide = ["diameter", "across", "wide", "width", "ø", "dia"]
        if v.height > 0, !near(v.height, deep) { v.height = 0 }
        func appears(_ value: Double) -> Bool { matches(number, in: text).contains { $0.groups[1].flatMap { Double($0) }.map { abs($0 - value) < 1e-9 } ?? false } }
        if v.diameter > 0, !(near(v.diameter, wide) || (appears(v.diameter) && !near(v.diameter, deep))) { v.diameter = 0 }
        let compact = text.replacingOccurrences(of: " ", with: "")
        if !v.size.isEmpty, !compact.contains(v.size.lowercased().replacingOccurrences(of: " ", with: "")) { v.size = "" }
        if !v.text.isEmpty, !text.contains(v.text.lowercased()) { v.text = "" }
        // Never drop every value: an edit the reading leaves empty keeps the model's values.
        var kept = v.diameter > 0 || v.height > 0 || !v.size.isEmpty || !v.text.isEmpty ? v : values
        // A size that is not a hole or thread size ("12 mm") is never one, whatever else is kept.
        if AssistantEngine.plannerSizeForm, !kept.size.isEmpty, !isSizeForm(kept.size) { kept.size = "" }
        return kept
    }

    /// A feature edit's new sizes as the words state them: a depth or height ("12 mm deep",
    /// "11 mm tall", "depth to 4 mm", "deepen … to 9 mm") and a diameter ("7 mm in diameter",
    /// "14 mm wide", "a 5 mm diameter", "narrow … to 6 mm", "bring the 10 mm hole … down to 7 mm").
    /// "Ø10" is not read: it usually names the feature as it is.
    static func editSizes(_ words: String) -> (diameter: Double?, height: Double?) {
        let text = words.lowercased()
        func first(_ patterns: [String]) -> Double? {
            for pattern in patterns {
                if let value = matches(pattern, in: text).first?.groups[1].flatMap({ Double($0) }), value > 0 { return value }
            }
            return nil
        }
        let height = first([number + #"\s*mm\s+(?:deep|deeper|in depth|tall|taller|high|higher|long|longer)\b"#,
                            #"\b(?:depth|height|length)\s+(?:of\s+|to\s+|is\s+|=\s*)?"# + number + #"\s*mm"#,
                            #"\b(?:deepen|extend|lengthen|shorten|raise|lower)\w*\b[^.;]{0,40}?\bto\s+"# + number + #"\s*mm"#])
        let diameter = first([number + #"\s*mm\s+(?:across|wide|in diameter|diameter)\b"#,
                              #"\b(?:diameter|width)\s+(?:of\s+|to\s+|is\s+|=\s*)?"# + number + #"\s*mm"#,
                              #"\b(?:widen|enlarge|shrink|resize|open|bring|reduce|narrow)\w*\b[^.;]{0,40}?\bto\s+"# + number + #"\s*mm"#])
        return (diameter, height)
    }

    /// Whether `size` is written as a hole or thread size: M3, M2.5, M8x1, 1/4, 1/4-20, #6.
    static func isSizeForm(_ size: String) -> Bool {
        let compact = size.lowercased().replacingOccurrences(of: " ", with: "")
        return compact.range(of: #"^(m\d+(\.\d+)?([x×]\d+(\.\d+)?)?|\d+/\d+(-\d+)?|#\d+(-\d+)?)$"#, options: .regularExpression) != nil
    }

    /// Whether a hole edit's words ask for a through-hole: with the switch on, as `holeDepth` reads
    /// them ("instead of going through" is not); before, any "through".
    static func throughWords(_ words: String) -> Bool {
        AssistantEngine.plannerFeatureEditWords ? holeDepth(words) == HoleDepth(depth: nil) : words.lowercased().contains("through")
    }

    private static func values<T: Generable>(_ type: T.Type, for part: AssistantRequestPart, bench: AssistantWorkbench, extra: String = "") async throws -> T {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: valueInstructions + extra)
        let prompt = "Model now:\n\(bench.summary(maximumLines: 20))\n\nChange (\(part.action)): \(part.text)"
        return try await session.respond(to: prompt, generating: type, options: GenerationOptions(samplingMode: .greedy)).content
    }

    /// Whether `words` (lowercased) say `name` on its own, not inside a longer word.
    static func mentions(_ words: String, _ name: String) -> Bool {
        let name = name.lowercased()
        guard !name.isEmpty else { return false }
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var from = words.startIndex
        while let range = words.range(of: name, range: from..<words.endIndex) {
            let clearBefore = range.lowerBound == words.startIndex || !isWordCharacter(words[words.index(before: range.lowerBound)])
            let clearAfter = range.upperBound == words.endIndex || !isWordCharacter(words[range.upperBound])
            if clearBefore && clearAfter { return true }
            from = words.index(after: range.lowerBound)
        }
        return false
    }

    /// The body a part works on: the one named in its words, the one made or changed last, the
    /// selected one, the only one, or (with several) the model's pick.
    private static func body(for part: AssistantRequestPart, in bench: AssistantWorkbench) async throws -> String {
        let words = part.text.lowercased()
        // The longest name said on its own: "bracket (2)" before "bracket", and "lid" not in "lidded".
        let names = bench.workspace.bodies.map { bench.bodyName($0.id) }.sorted { $0.count > $1.count }
        if let named = names.first(where: { mentions(words, $0) }) { return named }
        if case .body(let id)? = bench.focus { return bench.bodyName(id) }
        if let selected = try? bench.item(named: "selected"), case .body(let id) = selected { return bench.bodyName(id) }
        if bench.workspace.bodies.count == 1 { return bench.bodyName(bench.workspace.bodies[0].id) }
        guard !bench.workspace.bodies.isEmpty else { throw AssistantWorkbench.Failure("there is no body yet; make one first.") }
        let choice = try await values(BodyChoice.self, for: part, bench: bench)
        guard (try? bench.body(named: choice.body)) != nil else { throw AssistantWorkbench.Failure("say which body.") }
        return choice.body
    }

    @discardableResult
    static func applySlipLidBox(_ values: SlipLidBoxValues, to bench: inout AssistantWorkbench, words: String? = nil) throws -> String {
        var v = values
        if AssistantEngine.plannerValueWords, let words { v = try worded(v, words) }
        guard let reference = AssistantSlipLidBox.Reference(rawValue: v.reference) else {
            throw AssistantWorkbench.Failure("Say whether the box dimensions are inside, outside without the lid, or closed including the lid.")
        }
        let spec = AssistantSlipLidBox(reference: reference, width: v.width, depth: v.depth, height: v.height,
                                       wall: v.wall, radius: v.radius, clearance: v.clearance, vents: v.vents)
        if AssistantEngine.plannerRecipeRouting, let words {
            // Fixed recipe sizes the words ask to change. A value counts only when the words put its
            // number in the same phrase as what it sizes: the model fills these from the recipe
            // description, or from another number in the request, too.
            let resolved = try spec.resolved()
            func asked(_ value: Double?, _ keyword: String) -> Double? {
                value.flatMap { Self.mentions($0, near: keyword, in: words) ? $0 : nil }
            }
            var conflicts: [String] = []
            if let plate = asked(v.lidPlate, "plate"), abs(plate - 2) > 1e-9 { conflicts.append("a \(AssistantWorkbench.mm(plate)) mm lid plate (fixed at 2 mm)") }
            if let rim = asked(v.rimHeight, "rim"), abs(rim - resolved.rimHeight) > 1e-9 {
                conflicts.append("a \(AssistantWorkbench.mm(rim)) mm rim (fixed at \(AssistantWorkbench.mm(resolved.rimHeight)) mm here)")
            }
            if let floor = asked(v.floor, "floor"), abs(floor - resolved.wall) > 1e-9 { conflicts.append("a \(AssistantWorkbench.mm(floor)) mm floor (the same as the walls here)") }
            if let count = asked(v.ventCount.map(Double.init), "vent") ?? asked(v.ventCount.map(Double.init), "slot") {
                conflicts.append("exactly \(Int(count)) vents (vents are on or off)")
            }
            if !conflicts.isEmpty {
                throw AssistantWorkbench.Failure("The slip-on lid recipe cannot make \(conflicts.joined(separator: ", ")); that is not supported, so nothing was made.")
            }
        }
        return try bench.addSlipLidBox(spec)
    }

    /// Whether the words write `value` in the same phrase as `keyword` ("an 8 mm tall rim", "rim
    /// must be 8 mm", "5 vent slots"): within a few words, with no comma or full stop between.
    static func mentions(_ value: Double, near keyword: String, in words: String) -> Bool {
        let text = words.lowercased()
        guard let numbers = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return false }
        for match in numbers.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let number = Double(text[range]), abs(number - value) < 1e-9 else { continue }
            let before = text[text.index(range.lowerBound, offsetBy: -min(40, text.distance(from: text.startIndex, to: range.lowerBound)))..<range.lowerBound]
            let after = text[range.upperBound..<text.index(range.upperBound, offsetBy: min(40, text.distance(from: range.upperBound, to: text.endIndex)))]
            let phrase = (before.split(whereSeparator: { ",.;".contains($0) }).last.map(String.init) ?? "")
                + (after.split(whereSeparator: { ",.;".contains($0) }).first.map(String.init) ?? "")
            if phrase.contains(keyword) { return true }
        }
        return false
    }

    /// What a lid-box request's own words say about the recipe's sizes: each size triple with the
    /// reference its sentence gives it, and the lid clearance per side.
    struct SlipLidWords: Equatable {
        struct Size: Equatable {
            var reference: AssistantSlipLidBox.Reference?
            var size: SIMD3<Double>
        }
        var sizes: [Size] = []
        /// Per side; a total is halved. Nil when no clearance number was read.
        var clearance: Double?
        /// The words speak of a clearance or gap, read or not.
        var mentionsClearance = false
    }

    private static let referenceWords: [(AssistantSlipLidBox.Reference, String)] = [
        (.closed, #"\b(closed|overall|assembled|envelope)\b|\blid on\b|\bincluding (the )?lid\b"#),
        (.outside, #"\b(outside|outer|exterior|external)\b(?! corner)|\bbody\b|\b(without|excluding) (the )?lid\b"#),
        (.inside, #"\b(inside|interior|internal|inner)\b(?! corner)|\bcavity\b"#)]
    private static let number = #"(\d+(?:\.\d+)?)"#

    /// Ranges and captured groups of every match of `pattern` in `text`.
    private static func matches(_ pattern: String, in text: String) -> [(range: Range<String.Index>, groups: [Substring?])] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { text[$0] } }
            return (range, groups)
        }
    }

    /// Reads sizes, references, and clearance from the words. A size's reference is the reference
    /// word nearest to it in its own sentence (before it, or after it up to the next size); an
    /// outside word yields to a closed one in the same sentence ("closed outside envelope").
    static func slipLidWords(_ request: String) -> SlipLidWords {
        let text = request.lowercased()
        var result = SlipLidWords()
        let triples = matches(number + #"\s*(?:mm\s*)?(?:x|×|by|\*)\s*"# + number + #"\s*(?:mm\s*)?(?:x|×|by|\*)\s*"# + number, in: text)
        let boundaries = matches(#"[.;?!:](?=\s|$)|\n"#, in: text).map(\.range)
        let words = referenceWords.map { ($0.0, matches($0.1, in: text).map(\.range)) }
        for (i, triple) in triples.enumerated() {
            let start = max(boundaries.last { $0.upperBound <= triple.range.lowerBound }?.upperBound ?? text.startIndex,
                            i > 0 ? triples[i - 1].range.upperBound : text.startIndex)
            let end = min(boundaries.first { $0.lowerBound >= triple.range.upperBound }?.lowerBound ?? text.endIndex,
                          i + 1 < triples.count ? triples[i + 1].range.lowerBound : text.endIndex)
            var nearest: (distance: Int, reference: AssistantSlipLidBox.Reference)?, closed = false
            for (reference, ranges) in words {
                for range in ranges {
                    let distance: Int
                    if range.lowerBound >= start && range.upperBound <= triple.range.lowerBound {
                        distance = 2 * text.distance(from: range.upperBound, to: triple.range.lowerBound)
                    } else if range.lowerBound >= triple.range.upperBound && range.upperBound <= end {
                        distance = 2 * text.distance(from: triple.range.upperBound, to: range.lowerBound) + 1
                    } else { continue }
                    if reference == .closed { closed = true }
                    if distance < nearest?.distance ?? .max { nearest = (distance, reference) }
                }
            }
            let values = triple.groups[1...3].compactMap { $0.flatMap { Double($0) } }
            guard values.count == 3 else { continue }
            let reference = nearest?.reference == .outside && closed ? .closed : nearest?.reference
            result.sizes.append(.init(reference: reference, size: SIMD3(values[0], values[1], values[2])))
        }

        // Per side, then a total (halved), then a plain clearance or gap, which the recipe takes per side.
        let between = #"((?:\s+[a-z]+){0,4}?)"#, sized = #"\b(wall|walls|floor|corner|corners|radius|radii|plate|thick)\b"#
        func first(_ patterns: [String], group: Int = 1) -> Double? {
            for pattern in patterns {
                for match in matches(pattern, in: text) {
                    // A number that is one of the sizes ("90 × 60 × 45 mm overall") is not a clearance.
                    if let value = match.groups[group], triples.contains(where: { $0.range.contains(value.startIndex) }) { continue }
                    if match.groups.count > 2, let gap = match.groups[2], gap.range(of: sized, options: .regularExpression) != nil { continue }
                    if let value = match.groups[group].flatMap({ Double($0) }) { return value }
                }
            }
            return nil
        }
        if let side = first([number + #"\s*mm\b"# + between + #"\s+(?:on\s+)?(?:per[- ]side|each\s+side|a\s+side)\b"#,
                             #"\b(?:per[- ]side|each[- ]side)\s+(?:lid\s+|rim\s+)?(?:clearance|gap)\s+(?:of\s+|is\s+)?"# + number + #"\s*mm"#,
                             #"\b(?:clearance|gap)\s+(?:per[- ]side|on each side|each side)\s*:?\s+(?:of\s+|is\s+)?"# + number + #"\s*mm"#]) {
            result.clearance = side
        } else if let total = first([number + #"\s*mm\b([^.,;\d]{0,40}?)\b(?:in total|total|both sides|across the rim|overall)\b"#,
                                     #"\b(?:total|overall)\s+(?:lid\s+|rim\s+)?(?:clearance|gap)\b(?:\s+[a-z]+){0,8}?\s+(?:is\s+|of\s+)?"# + number + #"\s*mm"#]) {
            result.clearance = total / 2
        } else {
            result.clearance = first([number + #"\s*mm\s+(?:of\s+)?(?:lid\s+|rim\s+)?(?:clearance|gap)\b"#,
                                      #"\b(?:clearance|gap)\s+(?:of\s+|is\s+)?"# + number + #"\s*mm"#])
        }
        result.mentionsClearance = text.range(of: #"\b(clearance|gap|narrower|looser|tighter|per[- ]side|each side|a side)\b"#, options: .regularExpression) != nil
        return result
    }

    /// The recipe values the words settle replace the model's: the first size with a reference and
    /// its reference, and the clearance (none when the words name none, so the project Fit
    /// applies). Sizes without any reference ask which; sizes whose cavities disagree ask which.
    static func worded(_ values: SlipLidBoxValues, _ words: String) throws -> SlipLidBoxValues {
        var v = values
        let read = slipLidWords(words)
        let referenced = read.sizes.compactMap { size in size.reference.map { ($0, size.size) } }
        if !read.sizes.isEmpty && referenced.isEmpty { v.reference = "unspecified" }
        if let first = referenced.first {
            let (reference, size) = first
            (v.reference, v.width, v.depth, v.height) = (reference.rawValue, size.x, size.y, size.z)
            let wall = v.wall ?? AssistantSlipLidBox.defaultWall
            let inside = AssistantSlipLidBox.inside(size, reference, wall: wall)
            func described(_ reference: AssistantSlipLidBox.Reference, _ size: SIMD3<Double>) -> String {
                let name = switch reference { case .inside: "inside"; case .outside: "outside box"; case .closed: "closed" }
                return "\(name) \([size.x, size.y, size.z].map(AssistantWorkbench.mm).joined(separator: " × ")) mm"
            }
            if let mismatch = referenced.dropFirst().first(where: {
                simd_length(AssistantSlipLidBox.inside($0.1, $0.0, wall: wall) - inside) > 1e-6
            }) {
                let (other, otherSize) = mismatch
                let otherInside = AssistantSlipLidBox.inside(otherSize, other, wall: wall)
                throw AssistantWorkbench.Failure("The sizes do not match: with \(AssistantWorkbench.mm(wall)) mm walls, \(described(reference, size)) is \(described(.inside, inside)), but \(described(other, otherSize)) is \(described(.inside, otherInside)). Say which to use; nothing was made.")
            }
        }
        if let clearance = read.clearance { v.clearance = clearance } else if !read.mentionsClearance { v.clearance = nil }
        return v
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

    /// The sentences of `words` that mention a hole, bore, or drilling (all of them if none do),
    /// lowercased, so sizes given for other things in the same request are not read.
    static func holeSentences(_ words: String) -> String {
        let text = words.lowercased().replacingOccurrences(of: "−", with: "-")
        let sentences = text.replacingOccurrences(of: #"[.;?!](\s|$)"#, with: "\n", options: .regularExpression).split(separator: "\n").map(String.init)
        let about = sentences.filter { $0.range(of: #"\b(holes?|through-holes?|bores?|drill\w*)\b"#, options: .regularExpression) != nil }
        return about.isEmpty ? text : about.joined(separator: ". ")
    }

    /// A plain hole's depth as the sentences about holes give it: a number "deep" or "a depth of"
    /// a number (blind), else "through", "through-hole", or "all the way" (through, unless the
    /// words say not to go through). Nil when the words give neither.
    struct HoleDepth: Equatable { var depth: Double? }
    static func holeDepth(_ words: String) -> HoleDepth? {
        let scope = holeSentences(words)
        for pattern in [number + #"\s*mm\s+(?:deep|in depth)\b"#, #"\bdepth\s+(?:of\s+|is\s+|=\s*)?"# + number + #"\s*mm"#] {
            if let value = matches(pattern, in: scope).first?.groups[1].flatMap({ Double($0) }), value > 0 { return HoleDepth(depth: value) }
        }
        let not = scope.range(of: #"\b(not|n't|never|without)\b[^.,;]{0,20}\bthrough\b"#, options: .regularExpression) != nil
        if !not, scope.range(of: #"\bthrough\b|\ball the way\b"#, options: .regularExpression) != nil { return HoleDepth(depth: nil) }
        return nil
    }

    /// Where the words put a hole, read from the sentences about holes: the axis it runs along
    /// ("along X", "in the Y direction") picks a face across that axis, and coordinates on the
    /// face's two axes ("at X=25, Y=10", "X=±30, Y=±15") give the centers, every combination of
    /// them; a coordinate left out stays at the face center. No coordinates: the face center.
    static func holePlacement(_ words: String) -> (axis: Int?, values: [Int: [Double]]) {
        let scope = holeSentences(words)
        let axes = ["x": 0, "y": 1, "z": 2]
        var axis: Int?
        for pattern in [#"\balong (?:the )?([xyz])\b"#, #"\b([xyz])[- ]direction\b"#, #"\bparallel to (?:the )?([xyz])\b"#] {
            if let match = matches(pattern, in: scope).first, let letter = match.groups[1] { axis = axes[String(letter)]; break }
        }
        var values: [Int: [Double]] = [:]
        for match in matches(#"\b([xyz])\s*=\s*(±|\+/-|\+-)?\s*(-?\d+(?:\.\d+)?)"#, in: scope) {
            guard let letter = match.groups[1], let index = axes[String(letter)], let number = match.groups[3].flatMap({ Double($0) }) else { continue }
            let both = match.groups[2] != nil
            for value in both ? [-abs(number), abs(number)] : [number] where !(values[index] ?? []).contains(value) {
                values[index, default: []].append(value)
            }
        }
        return (axis, values)
    }

    /// The face and centers `holePlacement` reads, on `name`'s faces; the model's face otherwise.
    static func placed(_ face: String, of name: String, words: String, in bench: AssistantWorkbench) throws -> (String, [SIMD3<Double>]) {
        guard AssistantEngine.plannerHolePlacement else { return (face, []) }
        let (axis, values) = holePlacement(words)
        let faceAxes = ["left": 0, "right": 0, "front": 1, "back": 1, "top": 2, "bottom": 2]
        var face = face
        if let axis, faceAxes[face] != axis { face = ["right", "back", "top"][axis] }
        guard let across = faceAxes[face], values.keys.contains(where: { $0 != across }) else { return (face, []) }
        let center = try faceCenter(face, of: name, in: bench).center
        var points: [SIMD3<Double>] = [center]
        for index in 0..<3 where index != across {
            guard let given = values[index] else { continue }
            points = points.flatMap { point in given.map { value in var moved = point; moved[index] = value; return moved } }
        }
        return (face, points)
    }

    /// Makes one part's change on `bench`.
    static func perform(_ part: AssistantRequestPart, on bench: inout AssistantWorkbench, request: String? = nil) async throws {
        // The sketch the part just drew in (the last shape's), which need not be the newest sketch.
        let sketchName: (AssistantWorkbench) throws -> String = { bench in
            guard let sketch = bench.workspace.sketch(bench.workspace.shapes.last?.sketch) else { throw AssistantWorkbench.Failure("the sketch was not made.") }
            return bench.name(of: .sketch(sketch.id))
        }
        switch part.action {
        case "slip lid box":
            guard AssistantEngine.nativeTemplatesEnabled else { throw AssistantWorkbench.Failure("Native assistant templates are disabled in this evaluation.") }
            let v = try await values(SlipLidBoxValues.self, for: part, bench: bench, extra: "\n" + AssistantSlipLidBox.catalog)
            try applySlipLidBox(v, to: &bench, words: part.text)
        case "other lid":
            throw AssistantWorkbench.Failure("The on-device assistant can only make a box with a slip-on lid; that kind of lid is not supported, so nothing was made.")
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
            var depth = v.through ? nil : v.depth.flatMap { $0 > 0 ? $0 : nil }
            if AssistantEngine.plannerHoleDepth, let worded = holeDepth(part.text) { depth = worded.depth }
            let (face, points) = try placed(v.face, of: name, words: part.text, in: bench)
            try bench.hole(body: name, face: face, at: points, kind: .simple, size: "", diameter: try positive(v.diameter, "diameter"), depth: depth)
        case "screw hole":
            let name = try await body(for: part, in: bench)
            let v = try await values(ScrewHoleValues.self, for: part, bench: bench)
            let (face, points) = try placed(v.face, of: name, words: part.text, in: bench)
            try bench.hole(body: name, face: face, at: points, kind: holeKind(part.text), size: v.screw, depth: nil)
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
        case "new sphere":
            let v = try await values(NewSphereValues.self, for: part, bench: bench)
            try bench.primitive(kind: "sphere", sizes: [try positive(v.diameter, "diameter")], at: nil)
        case "new torus":
            let v = try await values(NewTorusValues.self, for: part, bench: bench)
            try bench.primitive(kind: "torus", sizes: [try positive(v.diameter, "diameter"), try positive(v.tube, "tube thickness")], at: nil)
        case "change feature":
            // The body's newest one of the kind its words name.
            let name = try await body(for: part, in: bench)
            var v = try await values(FeatureEditValues.self, for: part, bench: bench)
            // The user's own words state the values; a step the splitter rewrote may add its own.
            let stated = AssistantEngine.plannerRequestWords ? (request ?? part.text) : part.text
            if AssistantEngine.plannerFeatureEditWords { v = mentioned(v, in: stated) }
            if AssistantEngine.plannerEditSizes {
                let sizes = editSizes(stated)
                if let diameter = sizes.diameter { v.diameter = diameter }
                if let height = sizes.height { v.height = height }
            }
            let words = part.text.lowercased()
            let named = [("thread", "thread"), ("peg", "peg"), ("pin", "peg"), ("text", "text"), ("label", "text"), ("letter", "text"),
                         ("word", "text"), ("hole", "hole")].first { words.contains($0.0) }?.1
            let feature = named ?? v.feature
            let size = v.size.trimmingCharacters(in: .whitespaces)
            switch feature {
            case "hole":
                try bench.editFeature(body: name, feature: feature, which: "last", kind: holeKind(words) == .simple ? nil : holeKind(words).rawValue,
                                      size: size.isEmpty ? nil : size, diameter: v.diameter > 0 ? v.diameter : nil,
                                      depth: v.height > 0 && !(AssistantEngine.plannerFeatureRouting && throughWords(stated.lowercased())) ? v.height : nil,
                                      through: throughWords(stated.lowercased()) ? true : nil)
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
            // The selected hole, or else the body's only one: with several, which goes is the user's call.
            let name = try await body(for: part, in: bench)
            if (try? bench.deleteHole(body: name, face: "selected")) == nil {
                guard try bench.roundHoleCount(body: name) <= 1 else {
                    throw AssistantWorkbench.Failure("\(name) has more than one hole; select the one to delete and ask again.")
                }
                try bench.deleteHole(body: name, face: "hole")
            }
        case "hide", "show":
            // A group named in the request goes with everything in it.
            let words = part.text.lowercased()
            let group = bench.workspace.groupNames.values.sorted { $0.count > $1.count }.first { mentions(words, $0) }
            let item: String
            if let group { item = group } else { item = try await body(for: part, in: bench) }
            try bench.setHidden(items: [item], hidden: part.action == "hide")
        case "group":
            let words = part.text.lowercased()
            var names = bench.workspace.bodies.map { bench.bodyName($0.id) }.filter { mentions(words, $0) }
            if names.isEmpty { names = [try await body(for: part, in: bench)] }
            let v = try await values(NameValues.self, for: part, bench: bench)
            try bench.group(items: names, into: nil, newName: v.name.isEmpty ? nil : v.name)
        default:
            throw AssistantWorkbench.Failure("that is not something I can do yet.")
        }
    }
}
