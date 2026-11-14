import Foundation
import simd

/// A model-selected interpretation of an explicit requirement, never a complete design oracle.
/// Kept only for a request, outside the document and its undo history.
struct AssistantRequirement: Codable, Equatable, Sendable {
    var quote: String
    var kind: String
    var target: String?
    var expected: [Double]
}

struct AssistantRequirementResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case passed, unmet, notChecked }
    var quote: String
    var target: String?
    var status: Status
    var detail: String
}

struct AssistantRequirementReport: Codable, Equatable, Sendable {
    var results: [AssistantRequirementResult] = []
    var summary: String {
        guard !results.isEmpty else { return "Requirements not checked" }
        let passed = results.filter { $0.status == .passed }.count
        let unmet = results.filter { $0.status == .unmet }.count
        let unchecked = results.filter { $0.status == .notChecked }.count
        return "\(passed) passed · \(unmet) unmet · \(unchecked) not checked"
    }
    var needsReview: Bool { results.contains { $0.status != .passed } }
    /// Only an unmet check is a failure; "not checked" asks for a look, not an alarm.
    var hasUnmet: Bool { results.contains { $0.status == .unmet } }
    static let scope = "Checks cover only the listed requirements, as interpreted by the assistant. Review the preview too."
}

struct AssistantRequirementPlan {
    struct Entry {
        var requirement: AssistantRequirement
        var bodyID: UUID?
        var original: SolidBody?
        var issue: String?
    }
    private var entries: [Entry]
    private static let tolerance = 0.001 // mm, fixed by the app rather than chosen by the model

    init(_ requirements: [AssistantRequirement], request: String, workspace: Workspace, selection: AssistantSelection?) throws {
        guard !requirements.isEmpty, requirements.count <= 24 else {
            throw AssistantWorkbench.Failure("Record between 1 and 24 requirements in one call.")
        }
        let bench = AssistantWorkbench(workspace: workspace, selection: selection)
        entries = requirements.map { requirement in
            let body = requirement.target.flatMap { try? bench.body(named: $0) }
            return Entry(requirement: requirement, bodyID: body?.id, original: body,
                         issue: Self.issue(requirement, request: request))
        }
    }

    /// Bind a newly created target once, before ordinal names can shift after deletion.
    mutating func bindTargets(in workspace: Workspace, selection: AssistantSelection?) {
        let bench = AssistantWorkbench(workspace: workspace, selection: selection)
        for index in entries.indices where entries[index].bodyID == nil {
            guard entries[index].requirement.kind != "unchangedBody",
                  let target = entries[index].requirement.target,
                  let body = try? bench.body(named: target) else { continue }
            entries[index].bodyID = body.id
        }
    }

    func evaluate(in workspace: Workspace) -> AssistantRequirementReport {
        .init(results: entries.map { entry in
            let r = entry.requirement
            func result(_ status: AssistantRequirementResult.Status, _ detail: String) -> AssistantRequirementResult {
                .init(quote: r.quote, target: r.target, status: status, detail: detail)
            }
            if let issue = entry.issue { return result(.notChecked, issue) }
            if r.kind == "notChecked" { return result(.notChecked, "This requirement needs manual review.") }
            if r.kind == "bodyCount" {
                let count = workspace.bodies.count
                return result(Double(count) == r.expected[0] ? .passed : .unmet,
                              "Expected \(Int(r.expected[0])) \(r.expected[0] == 1 ? "body" : "bodies"); found \(count).")
            }
            guard let id = entry.bodyID else {
                if r.kind == "unchangedBody" { return result(.notChecked, "No original body was available to compare.") }
                // A planned name nothing ever took: a feature joined to an existing body becomes
                // part of it and never gets its own name. Nothing can be measured, and making the
                // feature again cannot change that (November 7, 2026: a knob was added twelve times).
                return result(.notChecked, "No body named \(r.target.map { "\"\($0)\"" } ?? "for this check") was made, so nothing was measured. A feature joined to another body becomes part of that body; review the preview.")
            }
            guard let body = workspace.bodies.first(where: { $0.id == id }) else {
                return result(.unmet, "The required body is missing; a replacement does not preserve its identity.")
            }
            if r.kind == "unchangedBody" {
                guard let original = entry.original else { return result(.notChecked, "No original body was available to compare.") }
                return result(body == original ? .passed : .unmet, body == original ? "Original body and identity preserved." : "The original body changed.")
            }
            do {
                let solid = try SolidKernel.solid(for: body)
                guard solid.isValidSolid else { return result(.unmet, "The body is not a valid closed solid.") }
                switch r.kind {
                case "bodySize":
                    let size = solid.bounds.max - solid.bounds.min
                    let actual = [size.x, size.y, size.z]
                    return result(Self.equal(actual, r.expected) ? .passed : .unmet,
                                  "Expected X/Y/Z \(Self.values(r.expected)) mm; measured \(Self.values(actual)) mm.")
                case "hole":
                    // Check the finished B-rep, not a feature-history entry that may have
                    // been superseded, filled, moved, or deepened by a later operation.
                    let entry = SIMD3(r.expected[0], r.expected[1], r.expected[2])
                    let normal = SIMD3(r.expected[3], r.expected[4], r.expected[5])
                    let hasWall = (0..<solid.faceCount).contains { face in
                        guard let cylinder = solid.faceCylinder(face) else { return false }
                        return abs(cylinder.radius * 2 - r.expected[6]) <= Self.tolerance
                            && abs(simd_dot(cylinder.direction, normal)) > 0.999999
                            && simd_length(simd_cross(cylinder.point - entry, normal)) <= Self.tolerance
                    }
                    guard hasWall else { return result(.unmet, "The finished solid has no cylindrical wall at the required diameter and axis.") }
                    if r.expected[7] != -1,
                       solid.face(containing: entry - normal * r.expected[7], normal: normal) == nil {
                        return result(.unmet, "The blind hole does not retain a flat bottom at the required depth.")
                    }
                    let hasEntryRim = (0..<solid.edgeCount).contains { edge in
                        guard let circle = solid.edgeCircle(edge), let length = solid.edgeLength(edge) else { return false }
                        return simd_length(circle.center - entry) <= Self.tolerance
                            && abs(circle.radius * 2 - r.expected[6]) <= Self.tolerance
                            && abs(length - .pi * r.expected[6]) <= Self.tolerance
                    }
                    guard hasEntryRim else { return result(.notChecked, "The required circular entry rim could not be resolved; finished or intersected entries need manual review.") }
                    guard let plane = SketchPlane.through(entry, normal: normal) else {
                        return result(.notChecked, "The hole's reference plane could not be constructed.")
                    }
                    let profile = SketchProfile(id: "requirement-probe", plane: plane, sourceIDs: [], outline: [],
                                                circle: CircleProfile(center: plane.coordinates(of: entry), radius: r.expected[6] / 2))
                    let probe = ExtrusionCut(profile: profile, depth: -abs(r.expected[7]), throughAll: r.expected[7] == -1)
                    let cutter = try SolidKernel.tool(for: probe, through: solid)
                    let remaining = try SolidKernel.boolean(solid, cutter, .intersect).volume
                    return result(remaining <= 0.001 ? .passed : .unmet,
                                  "Hole entry \(Self.point(entry)) mm, outward axis \(Self.point(normal)), Ø\(Self.number(r.expected[6])) mm, \(r.expected[7] == -1 ? "through all" : "depth \(Self.number(r.expected[7])) mm"); \(Self.number(remaining)) mm³ of material remains in its cutter.")
                default: return result(.notChecked, "This requirement is not supported by automatic checks.")
                }
            } catch {
                // A missing measurement is never a success, and never triggers document edits.
                return result(.notChecked, "Geometry could not be measured: \(error.localizedDescription)")
            }
        })
    }

    private static func equal(_ actual: [Double], _ expected: [Double]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private static func number(_ value: Double) -> String {
        (abs(value) < 0.0000005 ? 0 : value).formatted(.number.precision(.fractionLength(0...6)).grouping(.never))
    }
    private static func values(_ values: [Double]) -> String { values.map(number).joined(separator: " × ") }
    private static func point(_ p: SIMD3<Double>) -> String { "(" + [p.x, p.y, p.z].map(number).joined(separator: ", ") + ")" }

    private static func issue(_ r: AssistantRequirement, request: String) -> String? {
        guard !r.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, r.quote.count <= 1000,
              request.range(of: r.quote, options: [.caseInsensitive]) != nil else {
            return "The quoted requirement could not be found in this request."
        }
        guard r.expected.allSatisfy(\.isFinite) else { return "Expected values must be finite." }
        let dimensions: [Double]
        switch r.kind {
        case "notChecked": return nil
        case "bodyCount":
            guard r.expected.count == 1, r.expected[0] >= 0, r.expected[0] <= 1000,
                  r.expected[0].rounded() == r.expected[0] else { return "A whole body count is required." }
            dimensions = r.expected
        case "bodySize":
            guard r.expected.count == 3, r.expected.allSatisfy({ $0 > 0 && $0 <= 10000 }), r.target != nil else {
                return "A body and three positive world X/Y/Z sizes are required."
            }
            dimensions = r.expected
        case "hole":
            guard r.expected.count == 8, r.target != nil, r.expected[6] > 0, r.expected[6] <= 10000,
                  r.expected.prefix(3).allSatisfy({ abs($0) <= 100000 }),
                  r.expected[7] == -1 || (r.expected[7] > 0 && r.expected[7] <= 10000),
                  abs(simd_length(SIMD3(r.expected[3], r.expected[4], r.expected[5])) - 1) < tolerance else {
                return "A body, entry XYZ, unit outward normal XYZ, diameter, and depth (-1 for through all) are required."
            }
            dimensions = r.expected[7] == -1 ? [r.expected[6]] : Array(r.expected[6...7])
        case "unchangedBody": return r.target == nil ? "An original body is required." : nil
        default: return "This kind of requirement is not supported by automatic checks."
        }
        // Do not silently certify a substituted/default size. Derived placements remain a model
        // interpretation, exposed with the source quote. Unit conversion is outside this first trial.
        if r.quote.range(of: #"(?i)\b(inches?|inch|cm|centimeters?|metres?|meters?)\b|[\"″]"#, options: .regularExpression) != nil {
            return "Converted units need manual review; automatic checks currently use explicit millimeters."
        }
        let expression = try! NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#)
        let numbers = expression.matches(in: r.quote, range: NSRange(r.quote.startIndex..., in: r.quote)).compactMap {
            Range($0.range, in: r.quote).flatMap { Double(r.quote[$0]) }
        }
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let wordNumbers = words.enumerated().compactMap { i, word -> Double? in
            r.quote.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) == nil ? nil : Double(i)
        }
        guard dimensions.allSatisfy({ value in (numbers + wordNumbers).contains { abs($0 - value) < 1e-9 } }) else {
            return "An expected dimension or count is not explicit in the quoted requirement; review it manually."
        }
        return nil
    }
}
