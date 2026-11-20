import Foundation
import simd

// The assistant's design document: the solids of the workspace as an ordered list of features a
// language model can read and edit in one structured proposal. It is a view of the native feature
// tree (each solid's base profile and its ordered steps), made fresh for every request with short
// aliases ("B1", "B1.F3") for the solids' and steps' UUIDs; nothing here is saved in the project.
// See DesignExport.swift (native → document), DesignApply.swift (proposal → native), and
// DesignHarness.swift (one proposal, measured, with at most one correction).

/// One feature of a solid, in world millimeters with Z up. Unused fields are nil (null in JSON).
struct DesignFeature: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A rectangle with optionally rounded corners, centered on (x, y, z), extruded `height` along `axis`.
        case block
        /// A circle of `radius` centered on (x, y, z), extruded `height` along `axis`.
        case cylinder
        /// A closed polygon of `points`, extruded `height` along `axis` from (x, y, z).
        case polygon
        /// A drilled hole entering a face at (x, y, z); `axis` points out of the solid.
        case hole
        /// Rounded or beveled edges.
        case fillet, chamfer
        /// The solid hollowed to walls `size` thick, open at `faces`.
        case shell
        /// A feature the document cannot describe exactly: kept or removed, never changed.
        case locked
    }
    enum Operation: String, Codable, CaseIterable, Sendable { case add, cut }
    enum Axis: String, Codable, CaseIterable, Sendable {
        case px = "+x", nx = "-x", py = "+y", ny = "-y", pz = "+z", nz = "-z"
        /// The world axis index (0 = X, 1 = Y, 2 = Z) and its sign.
        var index: Int { switch self { case .px, .nx: 0; case .py, .ny: 1; case .pz, .nz: 2 } }
        var sign: Double { switch self { case .px, .py, .pz: 1; default: -1 } }
        var vector: SIMD3<Double> { var v = SIMD3<Double>(repeating: 0); v[index] = sign; return v }
        /// The two world axes across this one, as the document's (u, v) or (width, depth):
        /// Z → (X, Y), Y → (X, Z), X → (Y, Z).
        var across: (Int, Int) { switch index { case 0: (1, 2); case 1: (0, 2); default: (0, 1) } }
        init?(index: Int, sign: Double) {
            guard let axis = Self.allCases.first(where: { $0.index == index && $0.sign == (sign < 0 ? -1 : 1) }) else { return nil }
            self = axis
        }
    }
    struct Point: Codable, Equatable, Sendable { var u: Double; var v: Double }
    struct Hole: Codable, Equatable, Sendable {
        var type: HoleSpec.Kind
        /// A metric preset ("M3"), or nil for a plain hole of `diameter`.
        var size: String?
        var diameter: Double?
        var counterboreDiameter: Double?
        var counterboreDepth: Double?
        var countersinkDiameter: Double?
        var countersinkAngle: Double?
    }

    var id: String
    /// The owning solid: an existing alias ("B1"), or a short name for a new solid.
    var body: String
    var kind: Kind
    var operation: Operation?
    var axis: Axis?
    var x: Double?
    var y: Double?
    var z: Double?
    var width: Double?
    var depth: Double?
    var height: Double?
    var radius: Double?
    var points: [Point]?
    var throughAll: Bool?
    var hole: Hole?
    /// Fillet and chamfer: which edges, as a rule ("top", "outside vertical", "circular").
    var edges: String?
    /// Shell: faces left open ("top").
    var faces: [String]?
    /// Fillet radius, chamfer distance, or shell wall thickness.
    var size: Double?
    /// What a feature is, in words (locked features, and edges a fillet already has).
    var note: String?

    init(id: String, body: String, kind: Kind, operation: Operation? = nil, axis: Axis? = nil,
         x: Double? = nil, y: Double? = nil, z: Double? = nil, width: Double? = nil, depth: Double? = nil,
         height: Double? = nil, radius: Double? = nil, points: [Point]? = nil, throughAll: Bool? = nil,
         hole: Hole? = nil, edges: String? = nil, faces: [String]? = nil, size: Double? = nil, note: String? = nil) {
        self.id = id; self.body = body; self.kind = kind; self.operation = operation; self.axis = axis
        self.x = x; self.y = y; self.z = z; self.width = width; self.depth = depth; self.height = height
        self.radius = radius; self.points = points; self.throughAll = throughAll; self.hole = hole
        self.edges = edges; self.faces = faces; self.size = size; self.note = note
    }

    /// The feature as the app reads it: values its kind does not use are nil, and so are the
    /// zeros, empty texts, empty lists, and false a strict structured reply fills them with.
    func normalized() -> DesignFeature {
        var f = self
        f.note = nil
        if f.throughAll == false { f.throughAll = nil }
        if f.edges?.trimmingCharacters(in: .whitespaces).isEmpty == true { f.edges = nil }
        if f.faces?.isEmpty == true { f.faces = nil }
        if f.points?.isEmpty == true { f.points = nil }
        func placeOnly() { f.width = nil; f.depth = nil; f.radius = nil; f.points = nil; f.edges = nil; f.faces = nil; f.size = nil }
        func nothingPlaced() { f.operation = nil; f.axis = nil; f.x = nil; f.y = nil; f.z = nil; f.height = nil; f.throughAll = nil; f.hole = nil }
        switch kind {
        case .block, .cylinder, .polygon:
            f.hole = nil; f.edges = nil; f.faces = nil; f.size = nil
            if kind != .block { f.width = nil; f.depth = nil }
            if kind == .polygon { f.radius = nil } else { f.points = nil }
            if f.radius == 0, kind == .block { f.radius = nil }
            if f.throughAll == true { f.height = nil }
        case .hole:
            f.operation = nil
            placeOnly()
            if f.throughAll == true || f.height == 0 { f.height = nil }
            if var hole = f.hole {
                func zero(_ v: Double?) -> Double? { v == 0 ? nil : v }
                if hole.size?.trimmingCharacters(in: .whitespaces).isEmpty == true { hole.size = nil }
                hole.diameter = zero(hole.diameter)
                hole.counterboreDiameter = zero(hole.counterboreDiameter); hole.counterboreDepth = zero(hole.counterboreDepth)
                hole.countersinkDiameter = zero(hole.countersinkDiameter); hole.countersinkAngle = zero(hole.countersinkAngle)
                f.hole = hole
            }
        case .fillet, .chamfer:
            nothingPlaced()
            f.width = nil; f.depth = nil; f.radius = nil; f.points = nil; f.faces = nil
        case .shell:
            nothingPlaced()
            f.width = nil; f.depth = nil; f.radius = nil; f.points = nil; f.edges = nil
        case .locked:
            nothingPlaced()
            placeOnly()
        }
        return f
    }

    /// The same feature apart from the words and rounding a model may add when it repeats one:
    /// numbers agree to 0.0001 mm, a through-all cut ignores its height, and notes are ignored.
    func matches(_ other: DesignFeature) -> Bool {
        func same(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): abs(a - b) <= 1e-4
            default: false
            }
        }
        let through = (throughAll ?? false)
        guard id == other.id, body == other.body, kind == other.kind, operation == other.operation, axis == other.axis,
              through == (other.throughAll ?? false), same(x, other.x), same(y, other.y), same(z, other.z),
              same(width, other.width), same(depth, other.depth), same(radius, other.radius), same(size, other.size),
              through || same(height, other.height),
              edges?.trimmingCharacters(in: .whitespaces).nilIfEmpty == other.edges?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
              (faces ?? []) == (other.faces ?? []) else { return false }
        let a = points ?? [], b = other.points ?? []
        guard a.count == b.count, zip(a, b).allSatisfy({ same($0.u, $1.u) && same($0.v, $1.v) }) else { return false }
        switch (hole, other.hole) {
        case (nil, nil): return true
        case let (h?, g?):
            return h.type == g.type && h.size == g.size && same(h.diameter, g.diameter) &&
                same(h.counterboreDiameter, g.counterboreDiameter) && same(h.counterboreDepth, g.counterboreDepth) &&
                same(h.countersinkDiameter, g.countersinkDiameter) && same(h.countersinkAngle, g.countersinkAngle)
        default: return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The solids of a workspace as the model reads them.
struct DesignDocument: Codable, Equatable, Sendable {
    struct Body: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var hidden: Bool?
        /// World bounds, [minX, minY, minZ, maxX, maxY, maxZ], mm.
        var bounds: [Double]?
        var volume: Double?
    }
    var bodies: [Body]
    var features: [DesignFeature]

    var isEmpty: Bool { bodies.isEmpty }

    /// Compact JSON with keys in a stable order, for the model's input.
    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// What each alias in a document stands for in the workspace it was made from.
struct DesignAliases: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// The solid's base profile and depth.
        case base
        /// A fillet or chamfer on the original extrusion's edges (`SolidBody.finishes`).
        case finish(UUID)
        /// A step in the solid's ordered `cuts`.
        case step(UUID)
    }
    struct Reference: Equatable, Sendable {
        var body: UUID
        var role: Role
    }
    var bodies: [String: UUID] = [:]
    var features: [String: Reference] = [:]
    /// Each feature as exported, to tell a changed feature from a repeated one.
    var exported: [String: DesignFeature] = [:]
    /// Feature order per solid alias, as exported.
    var order: [String: [String]] = [:]

    func alias(of body: UUID) -> String? { bodies.first { $0.value == body }?.key }
}

/// The one proposal a model returns for a request.
struct DesignProposal: Codable, Equatable, Sendable {
    enum Intent: String, Codable, CaseIterable, Sendable {
        /// Change the design with `features`, `removeIDs`, and `transforms`.
        case change
        /// Answer a question (or ask one) in `message`, changing nothing.
        case answer
        /// The request needs an operation the document cannot express; the app's other tools do it.
        case handOff
    }
    struct Requirement: Codable, Equatable, Sendable {
        var quote: String
        var kind: String
        var target: String?
        var expected: [Double]
    }
    /// An operation on whole solids, after the features: move (and turn), mirror, a linear or
    /// circular pattern, or union, subtract, or intersect (the first of `bodies` is the target, the
    /// rest the tools). One shape for all keeps the schema within Claude's grammar limit.
    struct SolidOp: Codable, Equatable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable { case move, mirror, linear, circular, union, subtract, intersect }
        var op: Kind
        var bodies: [String]
        /// move: the axis to turn about; mirror: the plane's normal; linear: the direction; circular: the axis.
        var axis: String
        /// move: [dx, dy, dz] mm.
        var vector: [Double]
        /// move: the turning pivot; mirror: a point on the plane; circular: the center. [] is the
        /// solid's center for a move and the origin otherwise.
        var point: [Double]
        /// move: degrees to turn; circular: the degrees the pattern spans (0 or 360: a whole turn).
        var angle: Double
        /// linear and circular: instances, the original included.
        var count: Int
        /// linear: mm between neighbors, negative toward the axis's negative side; subtract: the
        /// clearance in mm the tools are grown by (0: none).
        var spacing: Double
        /// mirror: add the image beside the original instead of replacing it; union, subtract,
        /// intersect: keep the tool solids.
        var keepInput: Bool
        /// circular: turn each copy with the pattern.
        var rotateCopies: Bool

        init(op: Kind, bodies: [String], axis: String = "z", vector: [Double] = [], point: [Double] = [], angle: Double = 0,
             count: Int = 0, spacing: Double = 0, keepInput: Bool = false, rotateCopies: Bool = false) {
            self.op = op; self.bodies = bodies; self.axis = axis; self.vector = vector; self.point = point; self.angle = angle
            self.count = count; self.spacing = spacing; self.keepInput = keepInput; self.rotateCopies = rotateCopies
        }
    }
    var intent: Intent
    var message: String
    var requirements: [Requirement]
    /// Changed and new features: an existing ID is replaced in place, a new ID is appended to its solid.
    var features: [DesignFeature]
    /// Features to remove; a solid's alias removes the whole solid.
    var removeIDs: [String]
    /// After the features, in order.
    var solidOps: [SolidOp]

    init(intent: Intent = .change, message: String = "", requirements: [Requirement] = [], features: [DesignFeature] = [],
         removeIDs: [String] = [], solidOps: [SolidOp] = []) {
        self.intent = intent; self.message = message; self.requirements = requirements
        self.features = features; self.removeIDs = removeIDs; self.solidOps = solidOps
    }

    init(from decoder: any Decoder) throws {
        // Strict structured output sends every key; a model without it may leave empty lists out.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decode(Intent.self, forKey: .intent)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        requirements = try c.decodeIfPresent([Requirement].self, forKey: .requirements) ?? []
        features = try c.decodeIfPresent([DesignFeature].self, forKey: .features) ?? []
        removeIDs = try c.decodeIfPresent([String].self, forKey: .removeIDs) ?? []
        solidOps = try c.decodeIfPresent([SolidOp].self, forKey: .solidOps) ?? []
    }

    /// Reads a model's reply: the JSON object, also when wrapped in a code fence or prose.
    static func decode(_ text: String) throws -> DesignProposal {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.hasPrefix("{"), let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
            body = String(body[start...end])
        }
        do { return try JSONDecoder().decode(DesignProposal.self, from: Data(body.utf8)) }
        catch { throw AssistantWorkbench.Failure("The model's design proposal could not be read: \(DesignProposal.reason(error))") }
    }

    private static func reason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?: return "missing \(path(context.codingPath + [key]))."
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?: return "wrong value at \(path(context.codingPath))."
        case .dataCorrupted(let context)?: return context.codingPath.isEmpty ? "not JSON." : "bad value at \(path(context.codingPath))."
        default: return error.localizedDescription
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

// MARK: Schema

/// The proposal's JSON schema in the strict form structured outputs require: every object lists
/// all its properties as required and allows no others; optional values are nullable.
enum DesignSchema {
    static let name = "design_proposal"

    /// The schema as JSON data (providers read it into their own JSON values).
    static var data: Data {
        (try? JSONSerialization.data(withJSONObject: proposal, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static var proposal: [String: Any] {
        object([
            "intent": ["type": "string", "enum": DesignProposal.Intent.allCases.map(\.rawValue)],
            "message": ["type": "string"],
            "requirements": ["type": "array", "items": requirement],
            "features": ["type": "array", "items": feature],
            "removeIDs": ["type": "array", "items": ["type": "string"]],
            "solidOps": ["type": "array", "items": solidOp]
        ])
    }

    /// Claude's structured output allows at most 16 nullable fields in a schema, so only the hole
    /// settings are nullable; other unused values are 0, "", [], or false, which `normalized()` reads
    /// as unused, as the exported document leaves them out.
    static var feature: [String: Any] {
        let number: [String: Any] = ["type": "number"], text: [String: Any] = ["type": "string"]
        return object([
            "id": text,
            "body": text,
            "kind": ["type": "string", "enum": DesignFeature.Kind.allCases.map(\.rawValue)],
            "operation": ["type": "string", "enum": DesignFeature.Operation.allCases.map(\.rawValue)],
            "axis": ["type": "string", "enum": DesignFeature.Axis.allCases.map(\.rawValue)],
            "x": number, "y": number, "z": number, "width": number, "depth": number, "height": number, "radius": number,
            "points": ["type": "array", "items": object(["u": number, "v": number])],
            "throughAll": ["type": "boolean"],
            "hole": nullableObject([
                "type": ["type": "string", "enum": HoleSpec.Kind.allCases.map(\.rawValue)],
                "size": text,
                "diameter": number, "counterboreDiameter": number, "counterboreDepth": number,
                "countersinkDiameter": number, "countersinkAngle": number
            ]),
            "edges": text,
            "faces": ["type": "array", "items": text],
            "size": number,
            "note": text
        ])
    }

    /// How many properties are nullable or a choice of types (Claude's limit is 16).
    static func unionCount(_ schema: Any = proposal) -> Int {
        guard let object = schema as? [String: Any] else { return 0 }
        var count = 0
        for (_, value) in object["properties"] as? [String: Any] ?? [:] {
            if let value = value as? [String: Any], value["anyOf"] != nil || value["type"] is [Any] { count += 1 }
        }
        let nested = (object["properties"] as? [String: Any] ?? [:]).values.map { $0 } + [object["items"] as Any] + (object["anyOf"] as? [Any] ?? [])
        return count + nested.reduce(0) { $0 + unionCount($1) }
    }

    static var requirement: [String: Any] {
        object([
            "quote": ["type": "string"],
            "kind": ["type": "string", "enum": ["bodySize", "bodyCount", "hole", "unchangedBody", "notChecked"]],
            "target": ["type": "string"],
            "expected": ["type": "array", "items": ["type": "number"]]
        ])
    }

    static var solidOp: [String: Any] {
        let number: [String: Any] = ["type": "number"], numbers: [String: Any] = ["type": "array", "items": number]
        return object([
            "op": ["type": "string", "enum": DesignProposal.SolidOp.Kind.allCases.map(\.rawValue)],
            "bodies": ["type": "array", "items": ["type": "string"]],
            "axis": ["type": "string", "enum": ["x", "y", "z"]],
            "vector": numbers, "point": numbers, "angle": number,
            "count": ["type": "integer"], "spacing": number,
            "keepInput": ["type": "boolean"], "rotateCopies": ["type": "boolean"]
        ])
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
    // Optional values are a choice of the value or null (`anyOf`), which both Claude's and
    // OpenAI's structured outputs accept; Claude refuses an `enum` under a ["string", "null"] type.
    private static func orNull(_ schema: [String: Any]) -> [String: Any] { ["anyOf": [schema, ["type": "null"]]] }
    private static func nullableObject(_ properties: [String: Any]) -> [String: Any] { orNull(object(properties)) }
    private static func nullable(_ type: String) -> [String: Any] { orNull(["type": type]) }
    private static func nullableEnum(_ values: [String]) -> [String: Any] { orNull(["type": "string", "enum": values]) }
}
