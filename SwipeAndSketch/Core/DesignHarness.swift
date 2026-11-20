import Foundation
import simd

// The assistant's design harness: the model returns one structured proposal (DesignDocument.swift)
// against the workspace as it stands; the app applies it to a copy of that unchanged start, builds
// and measures the result, and, when a build fails or a recorded requirement is unmet, asks once
// more with only the failures. A second failure changes nothing. Nothing here talks to a model:
// the caller passes a planner that sends one request and returns the model's text.

/// One request to the planner.
struct DesignPlannerRequest: Sendable {
    var instructions: String
    var input: String
    /// The strict JSON schema of `DesignProposal` (DesignSchema.data).
    var schema: Data
    var schemaName: String
    /// A correction of a rejected first attempt.
    var isCorrection: Bool
}

/// The planner's reply: the model's text (the JSON proposal) and the model that wrote it.
struct DesignPlannerReply: Sendable {
    var text: String
    var model: String?
    init(text: String, model: String? = nil) { self.text = text; self.model = model }
}

enum DesignHarness {
    typealias Failure = AssistantWorkbench.Failure

    struct Attempt: Sendable {
        var proposal: DesignProposal?
        var model: String?
        var error: String?
        var failedChecks: [String] = []
        var passed: Bool { error == nil && failedChecks.isEmpty }
    }

    struct Result: Sendable {
        /// The draft: the changed design, or the start unchanged.
        var bench: AssistantWorkbench
        var reply: String
        var requirements: AssistantRequirementReport
        /// The request needs the app's other tools.
        var handOff: Bool
        var attempts: [Attempt]
        /// Passed after one correction.
        var corrected: Bool { attempts.count > 1 && (attempts.last?.passed ?? false) }
    }

    /// Runs one request. `planner` errors (transport, refusal, truncation) are thrown unchanged;
    /// a reply that is not a readable proposal ends the run too, since there is nothing to correct.
    @MainActor static func perform(request: String, workspace: Workspace, selection: AssistantSelection?, recall: String = "",
                                   onActivity: (String) -> Void = { _ in },
                                   planner: (DesignPlannerRequest) async throws -> DesignPlannerReply) async throws -> Result {
        let start = AssistantWorkbench(workspace: workspace, selection: selection)
        var detail: Set<UUID>?
        if DesignExport.featureCount(of: workspace) > DesignExport.featureLimit {
            let selected = selectedBodies(selection)
            guard !selected.isEmpty else {
                return Result(bench: start, reply: "", requirements: .init(), handOff: true, attempts: [])
            }
            detail = selected
        }
        let exported = await Task.detached { DesignExport.document(of: workspace, detail: detail) }.value
        let base = input(request: request, recall: recall, selection: selection, workspace: workspace, aliases: exported.aliases, document: exported.document)
        var attempts: [Attempt] = [], feedback: String?
        var last: (bench: AssistantWorkbench, report: AssistantRequirementReport)?
        for round in 0..<2 {
            try Task.checkCancellation()
            onActivity(round == 0 ? "Planning the design" : "Correcting the design")
            let reply = try await planner(DesignPlannerRequest(instructions: instructions, input: base + (feedback ?? ""), schema: DesignSchema.data,
                                                               schemaName: DesignSchema.name, isCorrection: round > 0))
            try Task.checkCancellation()
            let proposal = try DesignProposal.decode(reply.text)
            var attempt = Attempt(proposal: proposal, model: reply.model)
            switch proposal.intent {
            case .answer:
                let message = proposal.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(bench: start, reply: message.isEmpty ? "Nothing to change." : message, requirements: .init(), handOff: false, attempts: attempts + [attempt])
            case .handOff:
                return Result(bench: start, reply: "", requirements: .init(), handOff: true, attempts: attempts + [attempt])
            case .change: break
            }
            onActivity("Building and checking")
            let outcome = await Task.detached { check(proposal, start: start, aliases: exported.aliases, request: request) }.value
            try Task.checkCancellation()
            attempt.error = outcome.error
            attempt.failedChecks = outcome.failed
            attempts.append(attempt)
            if attempt.passed {
                let bench = outcome.bench ?? start
                let done = bench.changes.joined(separator: ". ")
                let note = proposal.message.trimmingCharacters(in: .whitespacesAndNewlines)
                var reply = done.isEmpty ? (note.isEmpty ? "Nothing needed to change." : note) : done + "."
                if !done.isEmpty, !note.isEmpty, note.count <= 300 { reply += " " + note }
                return Result(bench: bench, reply: reply, requirements: outcome.report, handOff: false, attempts: attempts)
            }
            if let bench = outcome.bench { last = (bench, outcome.report) }
            feedback = correction(proposal, outcome: outcome)
        }
        // Two failed proposals: the design stays as it was.
        let final = attempts.last
        let reasons = ([final?.error].compactMap { $0 } + (final?.failedChecks ?? [])).prefix(4).joined(separator: " ")
        return Result(bench: start, reply: "That change did not work out, so the design is unchanged. " + reasons,
                      requirements: last?.report ?? .init(), handOff: false, attempts: attempts)
    }

    // MARK: Checking a proposal

    struct Outcome: Sendable {
        var bench: AssistantWorkbench?
        var report: AssistantRequirementReport = .init()
        var error: String?
        var failed: [String] = []
        var passedCount = 0
    }

    /// The proposal applied to `start` and measured: each changed solid is one valid closed solid,
    /// and each recorded requirement is met.
    static func check(_ proposal: DesignProposal, start: AssistantWorkbench, aliases: DesignAliases, request: String) -> Outcome {
        var bench = start, outcome = Outcome()
        let newBodies: [String: UUID]
        do { newBodies = try bench.applyDesign(proposal, aliases: aliases) }
        catch {
            outcome.error = (error as? Failure)?.message ?? error.localizedDescription
            return outcome
        }
        outcome.bench = bench
        let before = Dictionary(uniqueKeysWithValues: start.workspace.bodies.map { ($0.id, $0) })
        for body in bench.workspace.bodies where before[body.id] != body {
            let name = aliases.alias(of: body.id) ?? newBodies.first { $0.value == body.id }?.key ?? bench.bodyName(body.id)
            guard let solid = try? SolidKernel.solid(for: body), solid.isValidSolid else {
                outcome.failed.append("\(name) is not one valid closed solid.")
                continue
            }
            outcome.passedCount += 1
        }
        if !proposal.requirements.isEmpty {
            // Requirement targets name solids by alias or by a new solid's name; the checks use names.
            let requirements = proposal.requirements.prefix(24).map { r in
                AssistantRequirement(quote: r.quote, kind: r.kind, target: r.target.flatMap { $0.isEmpty ? nil : $0 }.map { target in
                    aliases.bodies[target].map(start.bodyName) ?? newBodies[target].map(bench.bodyName) ?? target
                }, expected: r.expected)
            }
            if var plan = try? AssistantRequirementPlan(Array(requirements), request: request, workspace: start.workspace, selection: start.selection) {
                plan.bindTargets(in: bench.workspace, selection: start.selection)
                let report = plan.evaluate(in: bench.workspace)
                outcome.report = report
                for (requirement, result) in zip(requirements, report.results) {
                    if result.status == .unmet { outcome.failed.append("Unmet \"\(requirement.quote)\": \(result.detail)") }
                    else if result.status == .passed { outcome.passedCount += 1 }
                }
            }
        }
        return outcome
    }

    private static func correction(_ proposal: DesignProposal, outcome: Outcome) -> String {
        struct Correction: Encodable {
            let previousProposal: DesignProposal
            let failedChecks: [String]
            let passedCheckCount: Int
            let error: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let details = (try? encoder.encode(Correction(previousProposal: proposal, failedChecks: outcome.failed,
                                                      passedCheckCount: outcome.passedCount, error: outcome.error)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """

        Your previous attempt is below. Correct the failed checks or build error while preserving the working geometry.
        Submit a replacement proposal relative to the original starting document. Include all still-needed edits from the previous proposal.
        \(details)
        """
    }

    // MARK: The request

    private static func selectedBodies(_ selection: AssistantSelection?) -> Set<UUID> {
        switch selection {
        case .body(let id)?, .face(let id, _)?, .edge(let id, _)?: return [id]
        case .several(let items)?: return items.reduce(into: Set<UUID>()) { $0.formUnion(selectedBodies($1)) }
        default: return []
        }
    }

    static func input(request: String, recall: String, selection: AssistantSelection?, workspace: Workspace,
                      aliases: DesignAliases, document: DesignDocument) -> String {
        var lines = ["Request:", request.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !recall.isEmpty { lines += ["Earlier in this conversation:", recall] }
        lines.append("Selected: " + describe(selection, workspace: workspace, aliases: aliases))
        let others = [workspace.sketches.isEmpty ? nil : "\(workspace.sketches.count) sketch\(workspace.sketches.count == 1 ? "" : "es")",
                      workspace.constructionPlanes.isEmpty ? nil : "\(workspace.constructionPlanes.count) construction plane\(workspace.constructionPlanes.count == 1 ? "" : "s")"]
            .compactMap { $0 }
        if !others.isEmpty { lines.append("Also in the project, not in the document: " + others.joined(separator: ", ") + ".") }
        lines += ["Design document:", document.isEmpty ? "Blank: no solids yet." : document.json()]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ selection: AssistantSelection?, workspace: Workspace, aliases: DesignAliases) -> String {
        func body(_ id: UUID) -> String { aliases.alias(of: id).map { "\($0) (\(workspace.bodyNames[id] ?? $0))" } ?? "a solid" }
        func point(_ p: SIMD3<Double>) -> String { AssistantWorkbench.point(p) }
        switch selection {
        case nil: return "nothing"
        case .body(let id)?: return "solid " + body(id)
        case .face(let id, let face)?:
            guard let solid = workspace.bodies.first(where: { $0.id == id }).flatMap({ try? SolidKernel.solid(for: $0) }) else { return "a face of " + body(id) }
            var words = "a face of \(body(id))"
            if let center = solid.faceCenter(face) { words += " centered at \(point(center))" }
            if let plane = solid.facePlane(face) { words += ", flat, facing \(point(simd_normalize(plane.normal)))" }
            else if let cylinder = solid.faceCylinder(face) { words += ", round, Ø\(AssistantWorkbench.mm(cylinder.radius * 2)) along \(point(cylinder.direction))" }
            return words
        case .edge(let id, let edge)?:
            guard let solid = workspace.bodies.first(where: { $0.id == id }).flatMap({ try? SolidKernel.solid(for: $0) }),
                  let middle = solid.edgeSamples(edge, count: 3).dropFirst().first else { return "an edge of " + body(id) }
            return "an edge of \(body(id)) through \(point(middle)) (edge rule \"selected\")"
        case .several(let items)?:
            return items.map { describe($0, workspace: workspace, aliases: aliases) }.joined(separator: "; ")
        case .sketch?, .shape?, .profile?: return "sketch geometry (not in the document)"
        case .plane?: return "a construction plane (not in the document)"
        }
    }

    // MARK: Instructions

    static let instructions = """
    You change a 3D-printable CAD model in Swipe & Sketch by returning one JSON design proposal. Millimeters, right-handed world, Z up; the print bed is z = 0.

    The design document lists solids (bodies: id such as B1, name, bounds [minX,minY,minZ,maxX,maxY,maxZ], volume) and their features in build order (id such as B1.F2; body is the solid's id). A solid's first feature makes its base; each later feature adds to it or cuts from it, in order. Solids stay separate even where they touch.

    Feature kinds (fields a kind does not use: 0, "", [], or false; hole null except on holes):
    - block: a rectangle centered on (x,y,z) on its start face, extruded height along axis (+x,-x,+y,-y,+z,-z). Width and depth run across the axis: for ±z width is X and depth Y; for ±y width X and depth Z; for ±x width Y and depth Z. radius rounds the four corners running along the axis (0 for sharp).
    - cylinder: a circle of radius (half the diameter) centered on (x,y,z), extruded height along axis.
    - polygon: 3–64 points (u,v), not repeating the first, extruded height along axis from (x,y,z); u and v are offsets across the axis in the same order as width and depth.
    - operation: add (material joined to the solid; it must touch it) or cut (removes material); add for features that are not extrusions. A cut may set throughAll true (height 0) to go right through both ways.
    - hole: a drilled hole entering a flat face at (x,y,z) on that face; axis is the face's outward normal (the hole goes the other way). hole.type simple, counterbore, countersink, or insert; hole.size M2, M2.5, M3, M4, or M5 for screw presets, or "" with hole.diameter; height is the depth, or throughAll true.
    - fillet or chamfer: size mm on the edges a rule picks on the solid as it stands at that point: all, top, bottom, front (-y), back (+y), left (-x), right (+x), vertical, horizontal, circular, straight, face N, edge N, selected; optionally outside or inside ("outside vertical"); several rules separated by commas. An existing fillet with edges "" keeps its edges and changes only its size.
    - shell: hollows the solid to walls size mm thick, open at faces (top, bottom, front, back, left, right, selected).
    - locked: a feature the document cannot describe (its note says what). Keep it or remove it; never change it, never add one.

    Proposal:
    - intent "change": features lists only new or changed features, each complete. An existing id replaces that feature in place; a new id (short and unique, such as "lid-slot") is added after the last feature of its solid. removeIDs removes features, or a whole solid by its id. A new solid: give its features a new body name (short and descriptive, such as "Lid"); its first feature adds a block, cylinder, or polygon. solidOps then work on whole solids, in order (fields an op does not use: [], 0, or false): move shifts bodies by vector [dx,dy,dz] and turns them angle degrees about axis through point ([]: the solid's center); mirror reflects them across the plane whose normal is axis through point ([]: the origin; axis x through the origin is the Right plane, y Front, z Top), keepInput true (as the app's Mirror does by default) to add the image as a new solid and keep the original, false only when the request asks to replace or flip the original; linear copies them in a row along axis, count instances including the original, spacing mm apart (negative toward -axis), and two or three linear ops in a row on the same bodies make one grid; circular copies them round axis through point ([]: the origin), count including the original, across angle degrees (0 or 360: evenly round a whole turn), rotateCopies true to turn each copy with the pattern. Copies are ordinary, independent solids. union, subtract, and intersect list the target solid first in bodies, then the tool solids: union joins tools that touch the target into it, subtract cuts them out of it (spacing: a clearance in mm each side, 0 for none), intersect keeps only where they overlap it; keepInput true keeps the tool solids, false (the usual choice) removes them. The target keeps its id and name and afterwards carries the result as a locked feature. bodies may name a new solid made by this proposal's features, so a new cutter can be made and subtracted in one proposal.
    - intent "answer": a question about the design, or a question you must ask the user; message holds it; nothing changes.
    - intent "handOff": the request needs something outside this document: sketches, construction planes, threads, text, pegs, mirroring or patterning sketches or single features (only whole solids are mirrored or patterned here), split, revolve, loft, sweep, scale, colors, names, groups, hiding, or a locked feature's settings. Leave the lists empty.
    - requirements (with "change"): explicit, checkable requirements from the request, quoting the user's exact words, the expected numbers appearing in the quote. kind bodySize: target the solid's id or new name, expected [X size, Y size, Z size]; bodyCount: expected [count of all solids]; hole: expected [entry x, y, z, outward normal x, y, z, diameter, depth or -1 for through]; unchangedBody: target, expected []; notChecked for anything else. Never invent requirements or numbers.
    - message: one short sentence for the user, such as sizes you chose when the request gave none.

    Change only what the request asks; keep every other feature and id. New solids go beside existing ones, resting on z = 0, unless placed otherwise. Make solid, printable parts with as few features as do the job.
    """
}
