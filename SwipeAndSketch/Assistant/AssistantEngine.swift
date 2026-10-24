import Foundation
import FoundationModels

// Runs assistant requests on Apple's Foundation Models: the larger Private Cloud Compute model
// when it is available (it needs the com.apple.developer.private-cloud-compute entitlement and a
// network connection), else the on-device model, whose ~4K-token context gets a compact toolset,
// shorter instructions, and a fresh session per request. UI-free so it can be evaluated on a Mac.

enum AssistantBackend: String, Sendable {
    case cloud, onDevice
    var title: String { self == .cloud ? "Private Cloud Compute" : "On device" }
    var shortTitle: String { self == .cloud ? "Cloud" : "On device" }
}

/// The user's model preference.
enum AssistantModelChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, cloud, onDevice
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: "Automatic"; case .cloud: "Private Cloud Compute"; case .onDevice: "On device" }
    }
}

struct AssistantFailure: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

@MainActor final class AssistantEngine {
    let context = AssistantContext()
    /// Evaluation switch: give the on-device model the cloud model's full tools and instructions.
    nonisolated(unsafe) static var onDeviceFull = false
    /// The on-device model fills one typed plan (AssistantPlanner) instead of calling tools.
    nonisolated(unsafe) static var onDevicePlans = true
    /// How long a cloud request may take before Automatic falls back to the on-device model.
    nonisolated(unsafe) static var cloudTimeout: Double = 90
    private var cloudSession: LanguageModelSession?
    /// Earlier requests and replies, to rebuild a session that ran out of room and to give the
    /// stateless on-device sessions some memory.
    private var history: [(request: String, reply: String)] = []

    struct Turn {
        var reply: String
        var bench: AssistantWorkbench
        var backend: AssistantBackend
    }

    /// Why a backend cannot be used right now, or nil when it can.
    static func unavailableReason(_ backend: AssistantBackend) -> String? {
        switch backend {
        case .cloud:
            // Using the cloud model without the entitlement would stop the app.
            guard PrivateCloudEntitlement.isPresent else { return "Private Cloud Compute is not available in this version of the app. Choose On device." }
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available: return model.quotaUsage.isLimitReached ? "The Private Cloud Compute limit is reached for now." : nil
            case .unavailable(.deviceNotEligible): return "This iPad cannot use Private Cloud Compute."
            case .unavailable(.systemNotReady): return "Private Cloud Compute is not ready. Check that Apple Intelligence is on."
            case .unavailable: return "Private Cloud Compute is unavailable."
            }
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This iPad does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use the on-device model."
            case .unavailable(.modelNotReady): return "The on-device model is still downloading."
            case .unavailable: return "The on-device model is unavailable."
            }
        }
    }

    /// Backends to try for a choice, best first.
    static func backends(for choice: AssistantModelChoice) -> [AssistantBackend] {
        switch choice {
        case .automatic: [.cloud, .onDevice].filter { unavailableReason($0) == nil }
        case .cloud: [.cloud]
        case .onDevice: [.onDevice]
        }
    }

    /// Forgets the conversation.
    func reset() {
        cloudSession = nil
        history = []
    }

    func respond(to request: String, workspace: Workspace, selection: AssistantSelection?, choice: AssistantModelChoice,
                 onActivity: @escaping (String) -> Void, onText: @escaping (String) -> Void) async throws -> Turn {
        let backends = Self.backends(for: choice)
        guard !backends.isEmpty else {
            throw AssistantFailure(message: Self.unavailableReason(.onDevice) ?? Self.unavailableReason(.cloud) ?? "No model is available.")
        }
        context.onActivity = onActivity
        var lastError: Error?
        for (index, backend) in backends.enumerated() {
            if let reason = Self.unavailableReason(backend) { lastError = AssistantFailure(message: reason); continue }
            do {
                // A request that never answers (no network, a stalled service) gives up instead of hanging.
                let reply = try await Self.limit(seconds: backend == .cloud ? Self.cloudTimeout : 120, backend: backend) {
                    try await self.run(request, workspace: workspace, selection: selection, on: backend, onText: onText)
                }
                history.append((request, reply))
                if history.count > 12 { history.removeFirst(history.count - 12) }
                return Turn(reply: reply, bench: context.bench, backend: backend)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // Automatic falls back to the on-device model when the cloud cannot answer, or its
                // guardrails stop an ordinary modeling request.
                guard index < backends.count - 1, Self.isServiceProblem(error) || Self.isRefusal(error) else { throw Self.friendly(error, backend: backend) }
                onActivity(Self.isRefusal(error) ? "Trying the on-device model" : "Private Cloud Compute is unavailable; using the on-device model")
                onText("")
            }
        }
        throw Self.friendly(lastError ?? AssistantFailure(message: "No model is available."), backend: backends.last ?? .onDevice)
    }

    private func run(_ request: String, workspace: Workspace, selection: AssistantSelection?, on backend: AssistantBackend,
                     onText: @escaping (String) -> Void) async throws -> String {
        context.reset(workspace: workspace, selection: selection)
        let prompt = AssistantPrompt.request(request, summary: context.bench.summary(maximumLines: backend == .cloud ? 250 : 40))
        switch backend {
        case .cloud:
            let session = cloudSession ?? makeCloudSession(recalling: [])
            cloudSession = session
            do {
                return try await stream(prompt, in: session, onText: onText)
            } catch let error as LanguageModelError where Self.isRefusal(error) && context.bench.hasChanges {
                // The cloud model's output guardrails sometimes stop its closing sentence after the
                // tools have done the work; the changes stand, and the reply is written from them.
                let reply = context.bench.changes.filter { !$0.hasPrefix("Sketched ") }.joined(separator: ". ") + "."
                cloudSession = nil
                onText(reply)
                return reply
            } catch let error as LanguageModelError {
                if let log = context.onResult {
                    // Evaluation: how far the model got before the error.
                    for entry in session.transcript.suffix(4) { log("transcript: \(String(describing: entry).prefix(600))") }
                    let feedback = session.logFeedbackAttachment(sentiment: .negative, desiredResponseText: nil)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-feedback-\(UUID().uuidString).json")
                    try? feedback.write(to: url)
                    log("feedback: \(url.path)")
                }
                guard case .contextSizeExceeded = error else { throw error }
                // Start over with a short memory of the conversation, from the original document.
                context.reset(workspace: workspace, selection: selection)
                onText("")
                let fresh = makeCloudSession(recalling: history.suffix(6))
                cloudSession = fresh
                return try await stream(prompt, in: fresh, onText: onText)
            }
        case .onDevice where Self.onDevicePlans:
            let parts = try await AssistantPlanner.split(prompt, request: request, recall: AssistantPrompt.recall(history.suffix(2), limit: 200))
            try Task.checkCancellation()
            context.onResult?("parts: \(parts.isQuestion ? "question" : parts.parts.map { "\($0.action): \($0.text)" }.joined(separator: " | "))")
            if parts.isQuestion || parts.parts.isEmpty {
                let answer = try await AssistantPlanner.answer(prompt, recall: AssistantPrompt.recall(history.suffix(2), limit: 200))
                onText(answer)
                return answer
            }
            var bench = context.bench, failure: String?
            for part in parts.parts.prefix(8) {
                context.onActivity?(part.action.prefix(1).uppercased() + part.action.dropFirst())
                do {
                    // Each part sees the model as the earlier parts left it.
                    try await AssistantPlanner.perform(part, on: &bench)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep what the earlier parts did; report this one (a refusal, or a kernel error).
                    let message = (error as? AssistantWorkbench.Failure)?.message ?? error.localizedDescription
                    failure = "Could not \(part.action) (\(part.text)): \(message)"
                    break
                }
                try Task.checkCancellation()
            }
            context.adopt(bench)
            let done = bench.changes.filter { !$0.hasPrefix("Sketched ") }
            let reply = ([done.isEmpty ? nil : done.joined(separator: ". ") + "."] + [failure]).compactMap { $0 }.joined(separator: " ")
            onText(reply)
            return reply
        case .onDevice:
            let session = LanguageModelSession(model: SystemLanguageModel.default, tools: Self.onDeviceFull ? context.allTools : context.compactTools,
                                               instructions: (Self.onDeviceFull ? AssistantPrompt.instructions : AssistantPrompt.compactInstructions) + AssistantPrompt.recall(history.suffix(2), limit: 200))
            do {
                return try await stream(prompt, in: session, onText: onText)
            } catch let error as LanguageModelError {
                guard case .contextSizeExceeded = error else { throw error }
                // A large model: try once more without the earlier exchange and with a shorter summary.
                context.reset(workspace: workspace, selection: selection)
                onText("")
                let lean = LanguageModelSession(model: SystemLanguageModel.default, tools: context.compactTools, instructions: AssistantPrompt.compactInstructions)
                return try await stream(AssistantPrompt.request(request, summary: context.bench.summary(maximumLines: 15)), in: lean, onText: onText)
            }
        }
    }

    private func makeCloudSession(recalling earlier: some Collection<(request: String, reply: String)>) -> LanguageModelSession {
        LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: context.allTools,
                             instructions: AssistantPrompt.instructions + AssistantPrompt.recall(earlier, limit: 400))
    }

    private func stream(_ prompt: String, in session: LanguageModelSession, onText: @escaping (String) -> Void) async throws -> String {
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(samplingMode: .greedy)) {
            try Task.checkCancellation()
            text = snapshot.content
            onText(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let error = error as? LanguageModelError else { return false }
        switch error { case .guardrailViolation, .refusal: return true; default: return false }
    }

    /// Network, quota, and service problems of the cloud model, which the on-device model can cover.
    static func isServiceProblem(_ error: Error) -> Bool {
        if error is PrivateCloudComputeLanguageModel.Error { return true }
        if let timeout = error as? TimedOut, timeout.backend == .cloud { return true }
        if let error = error as? LanguageModelError, case .rateLimited = error { return true }
        return false
    }

    static func friendly(_ error: Error, backend: AssistantBackend) -> AssistantFailure {
        if let failure = error as? AssistantFailure { return failure }
        if let timeout = error as? TimedOut {
            return AssistantFailure(message: timeout.backend == .cloud ? "Private Cloud Compute did not answer in time. Check the connection, or switch to the on-device model."
                                                                       : "The on-device model took too long. Try a shorter request.")
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: return AssistantFailure(message: "Private Cloud Compute could not be reached. Check the connection, or switch to the on-device model.")
            case .quotaLimitReached(let limit):
                let reset = limit.resetDate.map { " It resets \($0.formatted(.relative(presentation: .named)))." } ?? ""
                return AssistantFailure(message: "The Private Cloud Compute limit is reached.\(reset) The on-device model still works.")
            case .serviceUnavailable: return AssistantFailure(message: "Private Cloud Compute is busy right now. Try again shortly, or use the on-device model.")
            @unknown default: return AssistantFailure(message: error.localizedDescription)
            }
        }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return AssistantFailure(message: "That is too much for the \(backend == .cloud ? "cloud" : "on-device") model at once. Start a new conversation or ask for less.")
            case .rateLimited: return AssistantFailure(message: "Too many requests at once. Wait a moment and try again.")
            case .guardrailViolation, .refusal: return AssistantFailure(message: "The model declined that request. Try rephrasing it.")
            case .unsupportedLanguageOrLocale: return AssistantFailure(message: "The model does not support this language yet. Try English.")
            default: return AssistantFailure(message: error.localizedDescription)
            }
        }
        return AssistantFailure(message: error.localizedDescription)
    }
}

/// What the model is told.
enum AssistantPrompt {
    static let instructions = """
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
    - Also available: extrude_face, fillet_edges and chamfer_edges (any edge, including edges of holes, cuts, and joins), make_container (shell), add_hole (M2–M5 simple, counterbore, countersink, or heat-set insert), add_peg (press-fit pegs with matching sockets), add_thread (real screw threads in holes or on round bosses), add_matching_part (the nut, cap, bolt, or plug that screws onto a thread), add_text (raised or sunk lettering), add_fit_test, move_items, set_dimension, delete_items, set_visibility, combine (union, subtract, or intersect), mirror, pattern (rows, grids, or around an axis), add_plane, revolve, round_sketch_corners, measure, inspect_item, scale_items (percent, or per axis), delete_faces (remove a hole or boss), delete_hole (remove a round hole as if never made), edit_fillet (change a fillet's or chamfer's size, or delete it), edit_feature (change a hole, thread, text, or peg already made, in place), add_primitive (a ready-made box, cylinder, sphere, or torus), add_construction (a plane through three points, or an axis), shape_operation (draft faces, a rib, a loft, or a sweep), resize_face (a round face's diameter, or a flat face's distance to the face behind it), offset_sketch (an outline a distance from a shape), rename_item (bodies, sketches, planes, groups), set_color, group_items and ungroup (Model Tree groups; set_visibility hides or shows a whole group). extrude also takes symmetric (both ways) and taper (draft degrees); add_sketch also draws ellipses, polygons, points, and construction lines.
    - Name items exactly as the model summary does: Body 01, Sketch 02, Rectangle 01, Plane 01, or "selected". When several sketch items are selected (the summary's Selected line lists them), extrude or revolve with sketch "selected" and no regions takes them all at once, such as several circles cut into a face. Faces: top, bottom, front, back, left, right, a face number from inspect_item, or selected. Edges: all, top, bottom, vertical, horizontal, circular, "face top", edge numbers, or selected.
    - Each request comes with a fresh model summary; it is the truth. Names shift after deletes.
    - To resize, prefer set_dimension (a body's extrusion depth, or a sketch shape's width, height, or diameter) over adding material.

    Rules:
    - Change the model only with tools, and report only what tools confirmed. If a tool returns an error, fix the arguments and try again, or explain the problem.
    - For a multi-step part, do the steps in order (sketch, extrude, then details), checking each result. Build upward: an upright wall, rib, or post on a plate is a rectangle or circle sketched on the plate's top face (on the plate's name, face top) and extruded up, placed with x and y inside the plate's spans. "Along its back edge" means on the top face with flushWith back, not on the back face.
    - If a step went wrong, fix it with the next step (set_dimension, move_items, or delete_items on the item just made); do not repeat the whole part. Stop after two failed tries and explain.
    - When a size is missing, pick a sensible one and say what you chose. Ask a short question only when you cannot proceed.
    - Answer questions from the summary, inspect_item, or measure (distances and angles between items), with numbers in mm. Do not guess measurements.
    - Your changes appear as a preview; the user keeps or discards them.
    - Reply in one to three short sentences of plain text. No markdown, lists, or tables.
    - Not available: splines, text, threads, scaling, sketch constraints, STEP export. Say so briefly and suggest the closest tool.
    """

    static let compactInstructions = """
    You are the design assistant in Swipe & Sketch, an iPad CAD app. Answer questions about the user's model and change it with tools.
    Units mm, Z up. Top plane = XY (extrudes +Z); Front = XZ (extrudes -Y); Right = YZ (extrudes +X).
    Make each box, cylinder, boss, or pocket with one sketch_and_extrude call: on top, front, or right for a new solid (x y z is the center of its base), or on a body's face (on Body 01, face top) with a positive distance for a boss or a negative one for a pocket. Rectangles are centered on x y z.
    One sketch_and_extrude call makes a whole plate or block at its full thickness; never add a second layer unless asked.
    Holes need no sketch: call add_hole on the body's face (diameter for a plain hole, or an M size), once with cornerInset for holes near the corners. Holes go through unless a depth is asked for.
    Directions: up = +Z, down = -Z, right = +X, left = -X, back = +Y, front = -Y.
    To resize a body, use set_dimension (an extrusion's depth is its height when made on top). To move or copy, use move_items.
    Refer only to items the summary lists, by their exact names; when it lists no bodies, start on top, front, or right. Faces: top, bottom, front, back, left, right. Edges: all, top, bottom, vertical, circular.
    Change the model only with tools and report only what they confirm; on an error, fix and retry. Pick sensible sizes when missing and say so. Reply in one or two plain sentences.

    Examples (the body is 60 × 40 × 20 at the origin, top face at z = 20):
    "plate 80 by 50, 6 thick" → sketch_and_extrude(on: "top", shape: "rectangle", x: 0, y: 0, z: 0, width: 80, height: 50, distance: 6)
    "cylinder 30 across, 40 tall" → sketch_and_extrude(on: "top", shape: "circle", x: 0, y: 0, z: 0, diameter: 30, distance: 40)
    "round boss 12 across, 8 tall on top" → sketch_and_extrude(on: "Body 01", face: "top", shape: "circle", x: 0, y: 0, z: 20, diameter: 12, distance: 8)
    "20 by 10 pocket 5 deep in the top" → sketch_and_extrude(on: "Body 01", face: "top", shape: "rectangle", x: 0, y: 0, z: 20, width: 20, height: 10, distance: -5)
    "M3 holes 6 in from the corners" → add_hole(body: "Body 01", face: "top", cornerInset: 6, size: "M3")
    "8 mm hole through the middle" → add_hole(body: "Body 01", face: "top", diameter: 8)
    "move it up 10 and copy it 70 to the right" → move_items(items: ["Body 01"], dz: 10), then move_items(items: ["Body 01"], dx: 70, copy: true)
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
