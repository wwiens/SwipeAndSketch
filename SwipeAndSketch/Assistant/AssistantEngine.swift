import Foundation
import FoundationModels
import CryptoKit

// Runs assistant requests on Apple's Foundation Models: the larger Private Cloud Compute model
// when it is available (it needs the com.apple.developer.private-cloud-compute entitlement and a
// network connection), else the on-device model, whose ~4K-token context gets a compact toolset,
// shorter instructions, and a fresh session per request. UI-free so it can be evaluated on a Mac.

enum AssistantBackend: String, Codable, Sendable {
    case cloud, onDevice, claude, openAI = "openai", gemini
    /// The API provider behind it, for the ones that use the user's own key.
    var provider: AIProvider? {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini; case .cloud, .onDevice: nil }
    }
    var title: String {
        switch self {
        case .cloud: "Private Cloud Compute"
        case .onDevice: "On device"
        case .claude, .openAI, .gemini: AssistantModelChoice.providerTitle(provider!)
        }
    }
    /// The panel's badge: "Claude · High".
    var shortTitle: String {
        switch self {
        case .cloud: "Cloud"
        case .onDevice: "On device"
        case .claude, .openAI, .gemini: "\(provider!.title) · \(ProviderSettings.effort(for: provider!).title)"
        }
    }
}

/// The user's model preference.
enum AssistantModelChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, cloud, onDevice, claude, openAI = "openai", gemini
    var id: String { rawValue }
    var provider: AIProvider? {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini; case .automatic, .cloud, .onDevice: nil }
    }
    var title: String {
        switch self {
        case .automatic: "Automatic (Apple)"
        case .cloud: "Private Cloud Compute"
        case .onDevice: "On device"
        case .claude, .openAI, .gemini: Self.providerTitle(provider!)
        }
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
    /// What the service said, for the panel's Details (Private Cloud Compute failures).
    var details: [String] = []
    var errorDescription: String? { message }
}

/// Evaluation data, including interruptions recovered after tools changed the draft.
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
    /// Evaluation only: exported with the run, never uploaded automatically.
    var feedbackDirectory: URL?
    /// Evaluation switch: give the on-device model the cloud model's full tools and instructions.
    nonisolated(unsafe) static var onDeviceFull = false
    /// The on-device model fills one typed plan (AssistantPlanner) instead of calling tools.
    nonisolated(unsafe) static var onDevicePlans = true
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
    /// The on-device planner sends lid-box requests to the native recipe (or declines other lids)
    /// by their words, and declines fixed sizes the recipe cannot make. On since the October 30,
    /// 2026 on-device comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerRecipeRouting = true
    /// The on-device planner takes the lid-box recipe's reference and per-side clearance from the
    /// request's own words, and asks when its sizes have no reference or disagree. On since the
    /// October 31, 2026 on-device comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerValueWords = true
    /// The on-device planner keeps "delete hole" only when the words ask to remove a hole; a
    /// request to drill or make one becomes a hole. On since the October 31, 2026 on-device
    /// comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerHoleCorrection = true
    /// The on-device planner turns "change feature" into a new hole when the words make one and
    /// change none. On since the October 31, 2026 on-device comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerNewHoleCorrection = true
    /// The on-device planner places holes where the words say ("at X=25, Y=10", "X=±30",
    /// "along X") instead of at the face center. On since the October 31, 2026 on-device
    /// comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerHolePlacement = true
    /// The on-device planner takes a plain hole's depth ("12 mm deep", "a depth of 7 mm") or
    /// "through" from the words. On since the October 31, 2026 on-device comparison;
    /// evaluations can switch it off.
    nonisolated(unsafe) static var plannerHoleDepth = true
    /// The on-device planner changes only the feature values the words give (a diameter, a depth
    /// or height, a size, new text), not ones the model fills in. On since the October 31, 2026
    /// on-device comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerFeatureEditWords = true
    /// The on-device planner sends "set height" to "change feature" when the thing being sized is a
    /// peg, pin, hole, thread, or text. On since the October 31, 2026 on-device comparison;
    /// evaluations can switch it off.
    nonisolated(unsafe) static var plannerFeatureSizeCorrection = true
    /// Length words (length, lengthen, extend, shorten, shorter) count as height words when a
    /// feature edit keeps only stated values. On since the October 31, 2026 on-device comparison;
    /// evaluations can switch it off.
    nonisolated(unsafe) static var plannerLengthWords = true
    /// A feature edit's size counts only in hole or thread size form (M3, M8x1, 1/4), not a plain
    /// millimeter number. On since the October 31, 2026 on-device comparison; evaluations can
    /// switch it off.
    nonisolated(unsafe) static var plannerSizeForm = true
    /// The on-device planner skips a delete step the user's own request does not ask for (the
    /// splitter can write one into a change). On since the October 31, 2026 on-device comparison;
    /// evaluations can switch it off.
    nonisolated(unsafe) static var plannerRemovalWords = true
    /// A feature edit's stated values are read from the user's request rather than the step text
    /// the splitter wrote. On since the October 31, 2026 on-device comparison; evaluations can
    /// switch it off.
    nonisolated(unsafe) static var plannerRequestWords = true
    /// A feature edit takes its new diameter and depth or height from the words when they state
    /// them, over the model's values. On since the October 31, 2026 on-device comparison;
    /// evaluations can switch it off.
    nonisolated(unsafe) static var plannerEditSizes = true
    /// The on-device planner sends a one-sentence request whose object is an existing hole, peg,
    /// thread, or text to a single feature edit with the user's words (or a hole removal), instead
    /// of the splitter's parts. On since the October 31, 2026 on-device comparison; evaluations
    /// can switch it off.
    nonisolated(unsafe) static var plannerFeatureRouting = true
    /// A request the words already route (lid-box recipe, single feature edit or removal) skips
    /// the splitter's model call, whose answer routing would discard. On since the October 31, 2026
    /// on-device comparison; evaluations can switch it off.
    nonisolated(unsafe) static var plannerSkipRoutedSplit = true
    /// How long a cloud request may take before Automatic falls back to the on-device model.
    nonisolated(unsafe) static var cloudTimeout: Double = 90
    private var cloudSession: LanguageModelSession?
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
    /// Earlier requests and replies, to rebuild a session that ran out of room and to give the
    /// stateless on-device sessions some memory.
    private var history: [(request: String, reply: String)] = []

    struct Turn {
        var reply: String
        var bench: AssistantWorkbench
        var backend: AssistantBackend
        var requirements = AssistantRequirementReport()
        /// Why Private Cloud Compute did not answer, when Automatic moved on to the on-device model.
        var fallback: AssistantFailure?
    }

    /// Why a backend cannot be used right now, or nil when it can.
    static func unavailableReason(_ backend: AssistantBackend) -> String? {
        switch backend {
        case .claude, .openAI, .gemini:
            let provider = backend.provider!
            do { return try provider.credentials.read() == nil ? Self.missingKey(provider) : nil }
            catch { return error.localizedDescription }
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
        case .claude: [.claude]
        case .openAI: [.openAI]
        case .gemini: [.gemini]
        }
    }

    static func missingKey(_ provider: AIProvider) -> String { "Add your \(provider.title) API key in Settings to use \(provider.title)." }

    /// Forgets the conversation.
    func reset() {
        cloudSession = nil
        claude.reset()
        openAI.reset()
        gemini.reset()
        previousBackend = nil
        previousProviderHash = nil
        history = []
    }

    func respond(to request: String, workspace: Workspace, selection: AssistantSelection?, choice: AssistantModelChoice,
                 onActivity: @escaping (String) -> Void, onText: @escaping (String) -> Void) async throws -> Turn {
        let backends = Self.backends(for: choice)
        guard !backends.isEmpty else {
            throw AssistantFailure(message: Self.unavailableReason(.onDevice) ?? Self.unavailableReason(.cloud) ?? "No model is available.")
        }
        context.onActivity = onActivity
        var lastError: Error?, fallback: AssistantFailure?
        // A failure after the cloud one also says why the cloud did not answer.
        func failure(_ error: Error, backend: AssistantBackend) -> AssistantFailure {
            var failure = Self.friendly(error, backend: backend)
            if backend == .cloud { failure.details += Self.cloudDetails(for: error, status: .current()) }
            if let fallback { failure.details += ["Private Cloud Compute: " + fallback.message] + fallback.details }
            return failure
        }
        for (index, backend) in backends.enumerated() {
            // A provider's key is read below, allowing tests to supply one without Keychain.
            if backend.provider == nil, let reason = Self.unavailableReason(backend) { lastError = AssistantFailure(message: reason); continue }
            // Each model keeps its own session; the conversation so far (`history`) carries over, so
            // Automatic falling back to the on-device model, and back, doesn't forget it.
            if previousBackend != backend {
                cloudSession = nil
                claude.reset()
                openAI.reset()
                gemini.reset()
                previousProviderHash = nil
                previousBackend = backend
            }
            do {
                // A request that never answers (no network, a stalled service) gives up instead of hanging.
                // Claude's limit covers its whole tool loop; each of its requests also has its own.
                let reply = try await Self.limit(seconds: backend.provider != nil ? 600 : backend == .cloud ? Self.cloudTimeout : 120, backend: backend) {
                    try await self.run(request, workspace: workspace, selection: selection, on: backend, onText: onText)
                }
                history.append((request, reply))
                if history.count > 12 { history.removeFirst(history.count - 12) }
                return Turn(reply: reply, bench: context.bench, backend: backend, requirements: context.requirementReport, fallback: fallback)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if backend != .cloud || !(error is LanguageModelError) {
                    record(error, backend: backend, session: nil, outcome: "thrown")
                }
                // Automatic falls back to the on-device model when the cloud cannot answer, or its
                // guardrails stop an ordinary modeling request.
                guard index < backends.count - 1, Self.isServiceProblem(error) || Self.isRefusal(error) else { throw failure(error, backend: backend) }
                if backend == .cloud { fallback = failure(error, backend: backend) }
                onActivity(Self.isRefusal(error) ? "Trying the on-device model" : "Private Cloud Compute is unavailable; using the on-device model")
                onText("")
            }
        }
        throw failure(lastError ?? AssistantFailure(message: "No model is available."), backend: backends.last ?? .onDevice)
    }

    private func run(_ request: String, workspace: Workspace, selection: AssistantSelection?, on backend: AssistantBackend,
                     onText: @escaping (String) -> Void) async throws -> String {
        context.reset(workspace: workspace, selection: selection, request: request)
        let prompt = AssistantPrompt.request(request, summary: context.bench.summary(maximumLines: backend == .onDevice ? 40 : 250))
        switch backend {
        case .claude, .openAI, .gemini:
            let provider = backend.provider!
            guard let key = try provider == .claude ? claudeKey() : providerKey(provider), !key.isEmpty else {
                throw AssistantFailure(message: Self.missingKey(provider))
            }
            let model = ProviderSettings.model(for: provider).id, effort = ProviderSettings.effortValue(for: provider)
            let hash = SHA256.hash(data: Data((key + "\n" + model).utf8))
            if hash != previousProviderHash { claude.reset(); openAI.reset(); gemini.reset(); previousProviderHash = hash }
            switch provider {
            case .claude: return try await claude.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
            case .openAI: return try await openAI.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
            case .gemini: return try await gemini.respond(prompt: prompt, key: key, context: context, model: model, effort: effort, onText: onText)
            }
        case .cloud:
            let session = cloudSession ?? makeCloudSession(recalling: history.suffix(6))
            cloudSession = session
            do {
                return try await stream(prompt, in: session, onText: onText)
            } catch let error as LanguageModelError where Self.isRefusal(error) && context.bench.hasChanges {
                record(error, backend: backend, session: session, outcome: "returnedDraft")
                // The cloud model's output guardrails sometimes stop its closing sentence after the
                // tools have done the work; the changes stand, and the reply is written from them.
                let reply = context.bench.changes.filter { !$0.hasPrefix("Sketched ") }.joined(separator: ". ") + "."
                cloudSession = nil
                onText(reply)
                return reply
            } catch let error as LanguageModelError {
                record(error, backend: backend, session: session, outcome: "thrown")
                guard case .contextSizeExceeded = error else { throw error }
                // Start over with a short memory of the conversation, from the original document.
                context.reset(workspace: workspace, selection: selection, request: request)
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
            var bench = context.bench, failure: String?, skipped = 0
            let maximumParts = 8
            for part in parts.parts.prefix(maximumParts) {
                if Self.plannerRemovalWords, AssistantPlanner.inventsRemoval(part, request: request) {
                    context.onResult?("skipped \(part.action): the request does not ask to remove anything")
                    skipped += 1
                    continue
                }
                context.onActivity?(part.action.prefix(1).uppercased() + part.action.dropFirst())
                do {
                    // Each part sees the model as the earlier parts left it.
                    try await AssistantPlanner.perform(part, on: &bench, request: request)
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
            let unasked = done.isEmpty && failure == nil && skipped > 0 ? "Nothing was changed: the request does not ask to remove anything." : nil
            // Parts past the limit are not done; the reply says so instead of leaving them out unmentioned.
            let left = failure == nil && parts.parts.count > maximumParts
                ? "The rest of the request (\(parts.parts.count - maximumParts) more \(parts.parts.count - maximumParts == 1 ? "step" : "steps")) was not done; ask for it next." : nil
            let reply = ([done.isEmpty ? nil : done.joined(separator: ". ") + "."] + [failure, unasked, left]).compactMap { $0 }.joined(separator: " ")
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
                context.reset(workspace: workspace, selection: selection, request: request)
                onText("")
                let lean = LanguageModelSession(model: SystemLanguageModel.default, tools: context.compactTools, instructions: AssistantPrompt.compactInstructions)
                return try await stream(AssistantPrompt.request(request, summary: context.bench.summary(maximumLines: 15)), in: lean, onText: onText)
            }
        }
    }

    private func record(_ error: Error, backend: AssistantBackend, session: LanguageModelSession?, outcome: String) {
        var feedbackFile: String?
        if let session, context.onResult != nil || onDiagnostic != nil {
            for entry in session.transcript.suffix(4) { context.onResult?("transcript: \(String(describing: entry).prefix(600))") }
            let url = (feedbackDirectory ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("assistant-feedback-\(UUID().uuidString).json")
            do {
                try session.logFeedbackAttachment(sentiment: .negative, desiredResponseText: nil).write(to: url)
                feedbackFile = url.lastPathComponent
                context.onResult?("feedback: \(url.lastPathComponent)")
            } catch { context.onResult?("Could not save feedback: \(error.localizedDescription)") }
        }
        onDiagnostic?(AssistantDiagnostic(kind: Self.failureKind(error), backend: backend,
                                          toolCalls: context.toolCalls, hasChanges: context.bench.hasChanges,
                                          outcome: outcome, detail: String(reflecting: error), feedbackFile: feedbackFile))
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
        switch failureKind(error) { case .guardrailViolation, .refusal: true; default: false }
    }

    static func failureKind(_ error: Error) -> AssistantFailure.Kind {
        if let failure = error as? AssistantFailure { return failure.kind }
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation: return .guardrailViolation
            case .refusal: return .refusal
            default: break
            }
        }
        return isServiceProblem(error) ? .service : .execution
    }

    /// Network, quota, and service problems of the cloud model, which the on-device model can cover.
    static func isServiceProblem(_ error: Error) -> Bool {
        if let failure = error as? AssistantFailure { return failure.kind == .service }
        if error is PrivateCloudComputeLanguageModel.Error { return true }
        if let timeout = error as? TimedOut, timeout.backend != .onDevice { return true }
        if let error = error as? LanguageModelError, case .rateLimited = error { return true }
        return isUntypedModelError(error)
    }

    /// The framework sometimes fails with a plain error in `LanguageModelError`'s domain that is none of its
    /// cases: Private Cloud Compute stopped this way after a burst of requests (code -1 wrapping
    /// `ModelManagerError 1001`). It says nothing about the request, so it counts as a service problem.
    static func isUntypedModelError(_ error: Error) -> Bool {
        !(error is LanguageModelError) && (error as NSError).domain == String(reflecting: LanguageModelError.self)
    }

    static func friendly(_ error: Error, backend: AssistantBackend) -> AssistantFailure {
        if let failure = error as? AssistantFailure { return failure }
        if let timeout = error as? TimedOut {
            if let provider = timeout.backend.provider { return AssistantFailure(message: "\(provider.title) did not finish in time. Try a smaller request.", kind: .service) }
            return AssistantFailure(message: timeout.backend == .cloud ? "Private Cloud Compute did not answer in time. Check the connection, or switch to the on-device model."
                                                                       : "The on-device model took too long. Try a shorter request.", kind: failureKind(error))
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: return AssistantFailure(message: "Private Cloud Compute could not be reached. Check the connection, or switch to the on-device model.", kind: .service)
            case .quotaLimitReached(let limit):
                let reset = limit.resetDate.map { " It resets \($0.formatted(.relative(presentation: .named)))." } ?? ""
                return AssistantFailure(message: "The Private Cloud Compute limit is reached.\(reset) The on-device model still works.", kind: .service)
            case .serviceUnavailable: return AssistantFailure(message: "Private Cloud Compute is busy right now. Try again shortly, or use the on-device model.", kind: .service)
            @unknown default: return AssistantFailure(message: error.localizedDescription, kind: .service)
            }
        }
        if isUntypedModelError(error) {
            return AssistantFailure(message: backend == .cloud ? "Private Cloud Compute stopped answering. Try again later, or switch to the on-device model."
                                                               : "The on-device model could not answer. Try again shortly.", kind: .service)
        }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return AssistantFailure(message: "That is too much for the \(backend == .cloud ? "cloud" : "on-device") model at once. Start a new conversation or ask for less.")
            case .rateLimited: return AssistantFailure(message: "Too many requests at once. Wait a moment and try again.", kind: .service)
            case .guardrailViolation: return AssistantFailure(message: "The model's safety filter stopped this request or response. Try rephrasing it.", kind: .guardrailViolation)
            case .refusal: return AssistantFailure(message: "The model declined that request. Try rephrasing it.", kind: .refusal)
            case .unsupportedLanguageOrLocale: return AssistantFailure(message: "The model does not support this language yet. Try English.")
            default: return AssistantFailure(message: error.localizedDescription)
            }
        }
        return AssistantFailure(message: error.localizedDescription)
    }

    /// Private Cloud Compute's own account of itself when a request failed.
    struct CloudStatus: Equatable {
        var availability: String
        var quota: String
        var resetDate: Date?

        /// Nil without the entitlement, whose absence would stop the app.
        static func current() -> CloudStatus? {
            guard PrivateCloudEntitlement.isPresent else { return nil }
            let model = PrivateCloudComputeLanguageModel()
            let availability = switch model.availability {
            case .available: "available"
            case .unavailable(.deviceNotEligible): "unavailable (device not eligible)"
            case .unavailable(.systemNotReady): "unavailable (system not ready)"
            case .unavailable(let reason): "unavailable (\(reason))"
            }
            let usage = model.quotaUsage
            let quota = switch usage.status {
            case .belowLimit(let below): below.isApproachingLimit ? "below the limit, approaching it" : "below the limit"
            case .limitReached: "limit reached"
            @unknown default: "\(usage.status)"
            }
            return CloudStatus(availability: availability, quota: quota, resetDate: usage.resetDate)
        }
    }

    /// The error as the framework gave it (with the errors under it) and the service's status, for the
    /// panel's Details: enough to tell a quota or rate limit from an outage.
    static func cloudDetails(for error: Error, status: CloudStatus?, at time: Date = .now) -> [String] {
        func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
        var lines = ["Failed: \(date(time))"]
        switch error {
        case let error as PrivateCloudComputeLanguageModel.Error:
            lines.append("Error: \(error.debugDescription)")
            if case .quotaLimitReached(let limit) = error, let reset = limit.resetDate { lines.append("Quota resets: \(date(reset))") }
        case let error as LanguageModelError:
            if case .rateLimited(let limit) = error {
                lines.append("Error: rate limited. \(limit.debugDescription)")
                if let reset = limit.resetDate { lines.append("Rate limit resets: \(date(reset))") }
                if !limit.metadata.isEmpty {
                    lines.append("Metadata: " + limit.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
                }
            } else {
                lines.append("Error: \(String(reflecting: error))")
            }
        case let timeout as TimedOut:
            lines.append("Error: no answer within \(Int(timeout.backend == .cloud ? cloudTimeout : 120)) s")
        default:
            // Plain framework errors carry their cause in the errors under them.
            var chain: [String] = [], next: NSError? = error as NSError
            while let current = next, chain.count < 6 {
                let link = "\(current.domain) \(current.code)"
                // The framework wraps its error in another of the same kind.
                if chain.last != link { chain.append(link) }
                next = current.userInfo[NSUnderlyingErrorKey] as? NSError
                    ?? (current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError])?.first
            }
            lines.append("Error: " + chain.joined(separator: " ← "))
        }
        if let status {
            lines.append("Private Cloud Compute: \(status.availability)")
            lines.append("Quota: \(status.quota)")
            if let reset = status.resetDate { lines.append("Quota resets: \(date(reset))") }
        }
        return lines
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
    - Also available: extrude_face, fillet_edges and chamfer_edges (any edge, including edges of holes, cuts, and joins), make_container (shell), add_hole (M2–M5 simple, counterbore, countersink, or heat-set insert), add_peg (press-fit pegs with matching sockets), add_thread (real screw threads in holes or on round bosses), add_matching_part (the nut, cap, bolt, or plug that screws onto a thread), add_screw_lid (a container's neck threaded and a lid screwed onto it, in one step; testPrint makes a thread fit test for that neck instead), add_text (raised or sunk lettering), add_fit_test, move_items, set_dimension, delete_items, set_visibility, combine (union, subtract, or intersect), mirror, pattern (rows, grids, or around an axis), add_plane, revolve, round_sketch_corners, measure, inspect_item, scale_items (percent, or per axis), delete_faces (remove a hole or boss), delete_hole (remove a round hole as if never made), edit_fillet (change a fillet's or chamfer's size, or delete it), edit_feature (change a hole, thread, text, or peg already made, in place), add_primitive (a ready-made box, cylinder, sphere, or torus), add_construction (a plane through three points, at an angle about a sketch line, or touching a round face; or an axis), shape_operation (draft faces, a rib, a loft, or a sweep), resize_face (a round face's diameter, or a flat face's distance to the face behind it), offset_sketch (an outline a distance from a shape), extend_line (a sketch line carried on to the next shape), rename_item (bodies, sketches, planes, groups), set_color, group_items and ungroup (Model Tree groups; set_visibility hides or shows a whole group). extrude also takes symmetric (both ways) and taper (draft degrees); add_sketch also draws ellipses, polygons, points, and construction lines.
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
