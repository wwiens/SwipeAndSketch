import Foundation
import CryptoKit

// Runs assistant requests on the model the user chose, through their own API key: Claude, OpenAI,
// or Gemini. Each request first asks for one structured design proposal (DesignHarness) and uses
// the CAD tools only for what that cannot express. UI-free so it can be evaluated on a Mac.
// (Apple's on-device and Private Cloud Compute models were removed on November 19, 2026, by the
// user's decision: they did not do the work well enough.)

enum AssistantBackend: String, Codable, Sendable {
    case claude, openAI = "openai", gemini
    /// The API provider behind it.
    var provider: AIProvider {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini }
    }
    var title: String { AssistantModelChoice.providerTitle(provider) }
    /// The panel's badge: "Claude · High".
    var shortTitle: String { "\(provider.title) · \(ProviderSettings.effort(for: provider).title)" }
}

/// The user's model preference.
enum AssistantModelChoice: String, CaseIterable, Identifiable, Sendable {
    case claude, openAI = "openai", gemini
    var id: String { rawValue }
    var provider: AIProvider {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini }
    }
    var backend: AssistantBackend { provider.backend }
    var title: String { Self.providerTitle(provider) }
    /// Whether Settings and the assistant's menu offer this choice (OpenAI and Gemini can be hidden).
    var isOffered: Bool { provider.isOffered }
    static var offered: [AssistantModelChoice] { allCases.filter(\.isOffered) }
    /// A stored preference, or Claude when it is missing, no longer offered, or one of the removed
    /// Apple choices ("automatic", "cloud", "onDevice").
    static func stored(_ rawValue: String?) -> AssistantModelChoice {
        rawValue.flatMap(AssistantModelChoice.init).flatMap { $0.isOffered ? $0 : nil } ?? .claude
    }
    /// "Claude Opus 5.5 · High": the chosen model and effort.
    static func providerTitle(_ provider: AIProvider) -> String {
        "\(ProviderSettings.model(for: provider).name) · \(ProviderSettings.effort(for: provider).title)"
    }
}

struct AssistantFailure: Error, LocalizedError, Equatable {
    enum Kind: String, Codable { case guardrailViolation, refusal, service, execution }
    var message: String
    var kind: Kind = .execution
    /// What the service said, for the panel's Details.
    var details: [String] = []
    var errorDescription: String? { message }
}

/// Evaluation data about a failed request.
struct AssistantDiagnostic: Codable, Equatable {
    var kind: AssistantFailure.Kind
    var backend: AssistantBackend
    var toolCalls: Int
    var hasChanges: Bool
    var outcome: String
    var detail: String
    var feedbackFile: String?
}

@MainActor final class AssistantEngine {
    let context = AssistantContext()
    var onDiagnostic: ((AssistantDiagnostic) -> Void)?
    /// Claude, OpenAI, and Gemini change the design with one structured proposal, measured and
    /// corrected once (DesignHarness), and use the tools only for what the proposal cannot express.
    /// On since November 19, 2026; `SS_DESIGN_HARNESS=0` in the environment switches it off for comparisons.
    nonisolated(unsafe) static var designHarnessEnabled = ProcessInfo.processInfo.environment["SS_DESIGN_HARNESS"] != "0"
    /// Evaluation only: compare the same build with and without runtime requirement checks.
    nonisolated(unsafe) static var requirementChecksEnabled = true
    /// Evaluation only: the same prompts can be compared with ordinary tools and a native recipe.
    nonisolated(unsafe) static var nativeTemplatesEnabled = true
    /// After a step retires, renumbers, or adds references, say so in its result. On since the
    /// October 30, 2026 comparison; evaluations can switch it off.
    nonisolated(unsafe) static var structuralContextEnabled = true
    /// Refuse a name an earlier call in the same round retired or renumbered. On since the
    /// October 30, 2026 comparison; evaluations can switch it off.
    nonisolated(unsafe) static var nameGuardEnabled = true
    /// A whole request: the most thoughtful models (Gemini 4 Carbon, November 2026) can take
    /// minutes for each round of tool calls.
    nonisolated(unsafe) static var providerTimeout: Double = 1800
    private let claude: ClaudeAssistant
    private let openAI: OpenAIAssistant
    private let gemini: GeminiAssistant
    private let claudeKey: () throws -> String?
    private let providerKey: (AIProvider) throws -> String?
    private var previousBackend: AssistantBackend?
    /// The key and model a provider's conversation was held with; a change starts it over (signed
    /// thinking and encrypted reasoning belong to one model).
    private var previousProviderHash: SHA256.Digest?

    init(claude: ClaudeAssistant = ClaudeAssistant(), claudeKey: @escaping () throws -> String? = { try ClaudeCredentials.shared.read() },
         openAI: OpenAIAssistant = OpenAIAssistant(), gemini: GeminiAssistant = GeminiAssistant(),
         providerKey: @escaping (AIProvider) throws -> String? = { try $0.credentials.read() }) {
        self.claude = claude
        self.claudeKey = claudeKey
        self.openAI = openAI
        self.gemini = gemini
        self.providerKey = providerKey
    }
    /// Earlier requests and replies, recalled to the design proposal (its requests are stateless).
    private var history: [(request: String, reply: String)] = []

    struct Turn {
        var reply: String
        var bench: AssistantWorkbench
        var backend: AssistantBackend
        var requirements = AssistantRequirementReport()
    }

    /// Why a backend cannot be used right now (no API key saved), or nil when it can.
    static func unavailableReason(_ backend: AssistantBackend) -> String? {
        do { return try backend.provider.credentials.read() == nil ? Self.missingKey(backend.provider) : nil }
        catch { return error.localizedDescription }
    }

    static func missingKey(_ provider: AIProvider) -> String { "Add your \(provider.title) API key in Settings to use \(provider.title)." }

    /// Forgets the conversation.
    func reset() {
        claude.reset()
        openAI.reset()
        gemini.reset()
        previousBackend = nil
        previousProviderHash = nil
        history = []
    }

    func respond(to request: String, workspace: Workspace, selection: AssistantSelection?, choice: AssistantModelChoice,
                 onActivity: @escaping (String) -> Void, onText: @escaping (String) -> Void) async throws -> Turn {
        let backend = choice.backend
        context.onActivity = onActivity
        if previousBackend != backend {
            claude.reset()
            openAI.reset()
            gemini.reset()
            previousProviderHash = nil
            previousBackend = backend
        }
        do {
            // A request that never answers (no network, a stalled service) gives up instead of hanging.
            // The limit covers the whole request; each of its HTTP requests also has its own.
            let reply = try await Self.limit(seconds: Self.providerTimeout, backend: backend) {
                try await self.run(request, workspace: workspace, selection: selection, on: backend, onText: onText)
            }
            history.append((request, reply))
            if history.count > 12 { history.removeFirst(history.count - 12) }
            return Turn(reply: reply, bench: context.bench, backend: backend, requirements: context.requirementReport)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onDiagnostic?(AssistantDiagnostic(kind: Self.failureKind(error), backend: backend, toolCalls: context.toolCalls,
                                              hasChanges: context.bench.hasChanges, outcome: "thrown", detail: String(reflecting: error)))
            throw Self.friendly(error, backend: backend)
        }
    }

    private func run(_ request: String, workspace: Workspace, selection: AssistantSelection?, on backend: AssistantBackend,
                     onText: @escaping (String) -> Void) async throws -> String {
        context.reset(workspace: workspace, selection: selection, request: request)
        let prompt = AssistantPrompt.request(request, summary: context.bench.summary(maximumLines: 250))
        let provider = backend.provider
        guard let key = try provider == .claude ? claudeKey() : providerKey(provider), !key.isEmpty else {
            throw AssistantFailure(message: Self.missingKey(provider))
        }
        let model = ProviderSettings.model(for: provider).id, effort = ProviderSettings.effortValue(for: provider)
        let hash = SHA256.hash(data: Data((key + "\n" + model).utf8))
        if hash != previousProviderHash { claude.reset(); openAI.reset(); gemini.reset(); previousProviderHash = hash }
        // Each provider first makes one structured design proposal (DesignHarness); a request it
        // cannot express goes on to the tools below, from the same unchanged start.
        if Self.designHarnessEnabled {
            let claude = self.claude, openAI = self.openAI, gemini = self.gemini, context = self.context
            let result = try await DesignHarness.perform(request: request, workspace: workspace, selection: selection,
                                                         recall: AssistantPrompt.recall(history.suffix(2), limit: 400),
                                                         onActivity: { context.onActivity?($0) }) { design in
                switch provider {
                case .claude: try await claude.propose(design, key: key, model: model, effort: effort)
                case .openAI: try await openAI.propose(design, key: key, model: model, effort: effort)
                case .gemini: try await gemini.propose(design, key: key, model: model, effort: effort)
                }
            }
            context.onResult?("design harness: \(result.handOff ? "hand off" : "\(result.attempts.count) attempt(s), \(result.attempts.last?.passed == true ? "passed" : "failed")")")
            if !result.handOff {
                context.adopt(result.bench, report: result.requirements)
                onText(result.reply)
                return result.reply
            }
            context.onActivity?("Using the CAD tools")
        }
        switch provider {
        case .claude: return try await claude.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
        case .openAI: return try await openAI.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
        case .gemini: return try await gemini.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
        }
    }

    /// Runs `work`, giving up after `seconds`.
    static func limit<T: Sendable>(seconds: Double, backend: AssistantBackend, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let fired = TimerFlag()
        let task = Task { @MainActor in try await work() }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            fired.value = true
            task.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if fired.value { throw TimedOut(backend: backend) }
            throw error
        }
    }

    struct TimedOut: Error { var backend: AssistantBackend }
    /// Set once a request's time is up (read after the request task ends).
    private final class TimerFlag: @unchecked Sendable { var value = false }

    static func isRefusal(_ error: Error) -> Bool {
        switch failureKind(error) { case .guardrailViolation, .refusal: true; default: false }
    }

    static func failureKind(_ error: Error) -> AssistantFailure.Kind {
        if let failure = error as? AssistantFailure { return failure.kind }
        return error is TimedOut ? .service : .execution
    }

    static func friendly(_ error: Error, backend: AssistantBackend) -> AssistantFailure {
        if let failure = error as? AssistantFailure { return failure }
        if let timeout = error as? TimedOut {
            return AssistantFailure(message: "\(timeout.backend.provider.title) did not finish in time. Try a smaller request.", kind: .service)
        }
        return AssistantFailure(message: error.localizedDescription)
    }
}

/// What the model is told.
enum AssistantPrompt {
    static var instructions: String {
        baseInstructions + (AssistantEngine.requirementChecksEnabled ? "\n" + requirementInstructions : "")
            + (AssistantEngine.nativeTemplatesEnabled ? "\n" + templateInstructions : "")
    }
    static let templateInstructions = """
    Native recipe available: Box with Slip-On Lid (enclosures.slip-lid-box). Use this recipe only when a slip-on lid is wanted; plain boxes, plates, cylinders, and other lid types use their existing tools. For a new enclosure that matches this recipe, prefer make_slip_lid_box to composing it from primitives. get_cad_recipe supplies its constraints and fixed dimensions when needed. Specify reference inside for cavity dimensions, outside for the box body without its lid, or closed for the assembled enclosure including its lid. If the user gives dimensions but does not say which reference they mean, ask before creating any geometry. Do not interpret inside or closed dimensions as bodySize checks: those checks measure each solid's outside world bounds only.
    Keep every explicit size, clearance, and corner radius. Wall and floor must share one thickness; lid plate is fixed at 2 mm, rim wall 1.6 mm and rim height min(4,inside height/2). Default wall/floor 2 mm, outside radius 4 mm, clearance from project Fit per side, vents off; the tool records all defaulted values. Clearance is per side: convert an explicitly total gap by dividing it by two. Unsupported template sizes or fixed-feature requests must be explained, never clamped, dropped, or replaced. If the user requires the native recipe, stop and ask rather than bypass its limits with primitives. Nominal cavity dimensions do not prove corner clearance for a rectangular insert.
    The parts are ordinary editable solids, laid out side by side on Z=0 with a 10 mm gap, without a live link to template settings. Use returned names for later holes or moves. A later request must preserve finished features; do not regenerate the whole enclosure to edit one part. Template creation still needs draft preview and Keep/Discard.
    """
    static let requirementInstructions = """
    Before making changes, call record_requirements once with a small checklist of explicit requirements from this request, quoting the user's exact words. Check body counts, world X/Y/Z sizes, simple round holes (entry, outward normal, diameter, depth), and bodies to leave unchanged where specified. Use notChecked for walls, pockets, relationships, inferred dimensions, or other unsupported requirements. A bodySize target is a whole separate body: a boss, knob, rib, or other feature joined to an existing body becomes part of that body and is never a body of its own, so use notChecked for its size. Do not omit unsupported requirements just to obtain passing checks. Questions or conflicting requirements needing clarification require no edits or checklist. The app checks the actual draft after edits and at completion; use unmet checks to correct the smallest failed step within the existing call budget, without changing requested values. Passing listed checks does not verify the whole design.
    """
    private static let baseInstructions = """
    You are the design assistant in Swipe & Sketch, an iPad CAD app for 3D-printable parts. You answer questions about the user's model and change it with tools.

    How the model works:
    - Millimeters. Z is up: up = +Z, right = +X, back = +Y, front = -Y. Top plane = XY (sketch u = +X, v = +Y, extrudes toward +Z). Front = XZ (u = +X, v = +Z, extrudes toward -Y). Right = YZ (u = +Y, v = +Z, extrudes toward +X).
    - Solids come from sketches. For one rectangle or circle, sketch_and_extrude does both steps at once (boxes, cylinders, bosses, pockets). For anything else, add_sketch draws rectangles (center, width, height), circles (center, diameter), slots (center, overall width and height), arcs (start, end, and a point between), and lines on a plane or a body's flat face, and extrude turns a closed region into a solid. Shapes that cross divide each other into separate regions, and an outline inside another is a hole in it. A positive distance goes along the plane's normal.
    - extrude with operation auto cuts solids the extrusion overlaps, joins a solid it touches, and otherwise makes a new body. To cut a pocket into a body, sketch on its face and extrude a negative distance (or use operation cut, or throughAll for through-holes). To add a boss, sketch on the face and extrude a positive distance.
    - Positions are world x, y, z in mm and are projected onto the sketch plane. For a sketch on a face, use points on that face (for the top face, z = the body's top).
    - Rectangles are centered on their point: a 40 × 20 rectangle at (0, 0, 0) on Top spans x -20…20, y -10…10. "80 by 50" means width 80 along X and height 50 along Y on Top.
    - To place a new solid next to another, use sketch_and_extrude with nextTo (and side, gap) instead of computing coordinates; it keeps them apart. Otherwise check the spans in the result for overlaps.
    - Parts that fit together need clearance, because printed pegs come out fat and holes small: add_peg puts pegs on a face and sockets them into the part sitting over it; combine subtract with clearance cuts room for a part shaped like the tools (keepTools to keep that part). The user's Fit is the default.
    - Holes need no sketch: add_hole drills a round hole of any diameter or a metric screw hole into a face, straight through unless a depth is asked for. For mounting holes near the corners of a face, call add_hole once with cornerInset instead of four positions.
    - Also available: extrude_face, fillet_edges and chamfer_edges (any edge, including edges of holes, cuts, and joins), make_container (shell), add_hole (M2–M5 simple, counterbore, countersink, or heat-set insert), add_peg (press-fit pegs with matching sockets), add_thread (real screw threads in holes or on round bosses), add_matching_part (the nut, cap, bolt, or plug that screws onto a thread), add_screw_lid (a container's neck threaded and a lid screwed onto it, in one step; testPrint makes a thread fit test for that neck instead), add_text (raised or sunk lettering), add_fit_test, move_items, set_dimension, delete_items, set_visibility, combine (union, subtract, or intersect), mirror, pattern (rows, grids, or around an axis), add_plane, revolve, round_sketch_corners, measure, inspect_item, scale_items (percent, or per axis), delete_faces (remove a hole or boss), delete_hole (remove a round hole as if never made), edit_fillet (change a fillet's or chamfer's size, or delete it), edit_feature (change a hole, thread, text, or peg already made, in place), add_primitive (a ready-made box, cylinder, sphere, or torus), add_construction (a plane through three points, at an angle about a sketch line, or touching a round face; or an axis), shape_operation (draft faces, a rib, a loft, or a sweep), resize_face (a round face's diameter, or a flat face's distance to the face behind it), offset_sketch (an outline a distance from a shape), extend_line (a sketch line carried on to the next shape), rename_item (bodies, sketches, planes, groups), set_color, add_svg (an SVG drawing as sketches, or colored solids: a pasted logo, or an outline you write as SVG), group_items and ungroup (Model Tree groups; set_visibility hides or shows a whole group). extrude also takes symmetric (both ways) and taper (draft degrees); add_sketch also draws ellipses, polygons, points, and construction lines.
    - Name items exactly as the model summary does: Body 01, Sketch 02, Rectangle 01, Plane 01, or "selected". When several sketch items are selected (the summary's Selected line lists them), extrude or revolve with sketch "selected" and no regions takes them all at once, such as several circles cut into a face. When several solids are selected, "selected" in a list of items (move_items, delete_items, set_visibility, scale_items, mirror, pattern, group_items, combine, set_color) stands for all of them; with several edges selected, fillet_edges or chamfer_edges with edges "selected" takes them all. Faces: top, bottom, front, back, left, right, a face number from inspect_item, or selected. Edges: all, top, bottom, vertical, horizontal, circular, "face top", edge numbers, or selected. Add outside to keep only edges on the body's outer boundary (its bounding box), or inside for the rest: "outside vertical" is a box's four outer corners, without the edges of its cavity, posts, or holes. Tool results say how many edges were changed; report that number, and if it is not what the user asked for, say so.
    - Each request comes with a fresh model summary; it is the truth. Names shift after deletes.
    - To resize, prefer set_dimension (a body's extrusion depth, or a sketch shape's width, height, or diameter) over adding material.

    Rules:
    - Change the model only with tools, and report only what tools confirmed. If a tool returns an error, fix the arguments and try again, or explain the problem.
    - For a multi-step part, do the steps in order (sketch, extrude, then details), checking each result. Build upward: an upright wall, rib, or post on a plate is a rectangle or circle sketched on the plate's top face (on the plate's name, face top) and extruded up, placed with x and y inside the plate's spans. "Along its back edge" means on the top face with flushWith back, not on the back face.
    - If a step went wrong, fix it with the next step (set_dimension, move_items, or delete_items on the item just made); do not repeat the whole part. Stop after two failed tries and explain.
    - When a size is missing, pick a sensible one and say what you chose. Ask a short question only when you cannot proceed.
    - Keep the sizes and counts the user gave. If one does not fit (a fillet too big for its edges, say), or the tool picks a different number of items than the user named, do not substitute a smaller size or other items: explain and ask.
    - Answer questions from the summary, inspect_item, or measure (distances and angles between items), with numbers in mm. Do not guess measurements.
    - Your changes appear as a preview; the user keeps or discards them.
    - Reply in one to three short sentences of plain text. No markdown, lists, or tables.
    - Sketch constraints and STEP export are not available. Text, threads, scaling, and splines are available through the supplied tools.
    """

    static func request(_ text: String, summary: String) -> String {
        "Model now:\n\(summary)\n\nRequest: \(text)"
    }

    static func recall(_ earlier: some Collection<(request: String, reply: String)>, limit: Int) -> String {
        guard !earlier.isEmpty else { return "" }
        let lines = earlier.map { "- User: \($0.request.prefix(limit))\n  You: \($0.reply.prefix(limit))" }
        return "\n\nEarlier in this conversation:\n" + lines.joined(separator: "\n")
    }
}
