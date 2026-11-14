import SwiftUI
import Combine

/// The assistant panel's state: the conversation, the model choice, and the request in progress.
/// Each request works on a draft of the document (or of the changes already under review); what
/// it changes is shown on the canvas for the user to keep as one undo step or discard.
@MainActor final class AssistantController: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        /// What happened to a reply's changes.
        enum Review: Equatable { case none, pending, kept, discarded }
        let id = UUID()
        var role: Role
        var text: String
        /// What the assistant is doing right now ("Extruding Sketch 01").
        var activity: String?
        /// The changes this reply made, as the workbench recorded them (not as the model claims).
        var changes: [String] = []
        var requirements: AssistantRequirementReport?
        var backend: AssistantBackend?
        var isWorking = false
        var failed = false
        /// Says the on-device model answered because Private Cloud Compute could not.
        var fallbackNote: String?
        /// What the service reported when the request (or its cloud attempt) failed.
        var details: [String] = []
        var review: Review = .none
    }

    typealias Responder = @MainActor (_ request: String, _ workspace: Workspace, _ selection: AssistantSelection?, _ choice: AssistantModelChoice,
                                      _ onActivity: @escaping (String) -> Void, _ onText: @escaping (String) -> Void) async throws -> AssistantEngine.Turn

    @Published private(set) var messages: [Message] = []
    @Published var draft = ""
    @Published var choice: AssistantModelChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey); refreshModelStatus() }
    }
    @Published private(set) var isWorking = false
    /// Which model a request would use now, or why none can. Asking the system is slow, and the panel
    /// redraws with every change to the model (each frame of a drag), so it is kept here and refreshed
    /// when it can change: the choice, the app becoming active, and each request's end.
    @Published private(set) var modelStatus = ModelStatus(title: "", available: false)
    /// The selection the next request refers to, for the chip above the field (kept for the same reason).
    /// Made only when read (the panel shows it): describing a face or an edge reads its outline from
    /// the kernel, and it was made on every selection change with the panel closed (November 8, 2026).
    var selectionLabel: String? {
        if let madeLabel { return madeLabel }
        let label = labelSource.selection.map {
            AssistantWorkbench(workspace: labelSource.base, selection: $0).selectionDescription()
                .replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
        }
        madeLabel = .some(label)
        return label
    }
    private var labelSource: (selection: AssistantSelection?, base: Workspace) = (nil, Workspace())
    private var madeLabel: String??
    /// The assistant's changes are waiting for Keep or Discard.
    @Published private(set) var isReviewing = false
    private var observers: Set<AnyCancellable> = []

    struct ModelStatus: Equatable {
        var title: String
        var available: Bool
    }
    let session: ModelingSession
    private let engine = AssistantEngine()
    private var task: Task<Void, Never>?
    /// Runs a request; tests replace it to drive the panel without a model.
    var responder: Responder
    private static let choiceKey = "assistant.model"

    init(session: ModelingSession) {
        self.session = session
        choice = UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(AssistantModelChoice.init) ?? .automatic
        let engine = self.engine
        responder = { request, workspace, selection, choice, onActivity, onText in
            try await engine.respond(to: request, workspace: workspace, selection: selection, choice: choice, onActivity: onActivity, onText: onText)
        }
        if ModelingSession.isRunningUITests && ProcessInfo.processInfo.arguments.contains("--ui-testing-assistant") {
            // UI tests: a scripted "model" that answers size questions and otherwise rounds the vertical edges.
            isScripted = true
            responder = { request, workspace, selection, _, onActivity, _ in
                onActivity("Filleting Body 01")
                try await Task.sleep(for: .milliseconds(400))
                var bench = AssistantWorkbench(workspace: workspace, selection: selection)
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-assistant-template") {
                    try bench.addSlipLidBox(.init(reference: .closed, width: 64, depth: 44, height: 24, wall: 2, radius: 6, clearance: 0.2, vents: false))
                    return AssistantEngine.Turn(reply: "The box and lid are ready to review.", bench: bench, backend: .onDevice)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-assistant-requirements") {
                    let plan = try AssistantRequirementPlan([.init(quote: request, kind: "bodySize", target: "Body 01", expected: [60, 40, 20])],
                                                            request: request, workspace: workspace, selection: selection)
                    try bench.setDimension(item: "Body 01", dimension: "depth", value: 10)
                    return AssistantEngine.Turn(reply: "Here is the draft.", bench: bench, backend: .onDevice, requirements: plan.evaluate(in: bench.workspace))
                }
                if request.lowercased().hasPrefix("how") { return AssistantEngine.Turn(reply: "Body 01 is 60 × 40 × 20 mm.", bench: bench, backend: .onDevice) }
                if request.lowercased().contains("chamfer") {
                    try bench.finish(.chamfer, body: "Body 01", edges: "top", size: 1)
                    return AssistantEngine.Turn(reply: "Chamfered the top edges of Body 01 by 1 mm.", bench: bench, backend: .onDevice)
                }
                try bench.finish(.fillet, body: "Body 01", edges: "vertical", size: 3)
                return AssistantEngine.Turn(reply: "Rounded the vertical edges of Body 01 by 3 mm.", bench: bench, backend: .onDevice)
            }
        }
        session.onAssistantReset = { [weak self] in self?.abandon() }
        refreshModelStatus()
        // The session calls back after each change, so labels are built from the new values: the
        // selection alone when it changes (before the sketch items picked with it are cleared), the
        // selection with those items when they change, and whenever the assistant's preview is set.
        updateSelectionLabel(ModelingSession.assistantSelection(for: session.selection), base: session.assistantBase)
        reviewChanged()
        session.observeSelection { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection:
                updateSelectionLabel(ModelingSession.assistantSelection(for: session.selection), base: session.assistantBase)
            case .extraSelection:
                updateSelectionLabel(ModelingSession.assistantSelection(for: (session.selection.map { [$0] } ?? []) + session.extraSelection),
                                     base: session.assistantBase)
            case .assistantPreview:
                reviewChanged()
            }
        }
        // NotificationCenter delivers on the posting thread. UserDefaults may change
        // from a background executor; Swift 6 must not enter these main-actor
        // observers until delivery has moved onto the main queue.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshModelStatus()
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: ClaudeCredentials.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.stop()
            self?.refreshModelStatus()
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            // A provider's model or effort changed in Settings: the badge shows the new effort.
            guard let value = UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(AssistantModelChoice.init), value != choice else {
                refreshModelStatus(); return
            }
            choice = value
        }.store(in: &observers)
    }

    /// The assistant's preview was set: the changes are under review while there is one.
    private func reviewChanged() {
        let preview = session.assistantPreview
        isReviewing = preview != nil
        updateSelectionLabel(session.assistantSelection, base: preview ?? session.workspace)
    }

    /// UI tests run a scripted model, available whatever the simulator's models are.
    private var isScripted = false

    /// The changes waiting for Keep or Discard, across replies.
    var pendingChanges: [String] { messages.filter { $0.review == .pending }.flatMap(\.changes) }

    /// Asks the system which model a request would use now, or why none can.
    func refreshModelStatus() {
        let status: ModelStatus
        if isScripted {
            status = ModelStatus(title: "On device", available: true)
        } else if let backend = AssistantEngine.backends(for: choice).first(where: { AssistantEngine.unavailableReason($0) == nil }) {
            status = ModelStatus(title: backend.shortTitle, available: true)
        } else {
            let backend: AssistantBackend = choice.provider?.backend ?? (choice == .cloud ? .cloud : .onDevice)
            status = ModelStatus(title: AssistantEngine.unavailableReason(backend) ?? "Unavailable", available: false)
        }
        if status != modelStatus { modelStatus = status }
    }

    private func updateSelectionLabel(_ selection: AssistantSelection?, base: Workspace) {
        if selection == nil && labelSource.selection == nil { return }
        objectWillChange.send()
        labelSource = (selection, base)
        madeLabel = nil
    }

    /// Starting points that fit the model as it is.
    var suggestions: [String] {
        let workspace = session.assistantBase
        if workspace.bodies.isEmpty {
            return ["Make a plate 80 by 50 mm, 5 mm thick, with M3 holes 6 mm in from the corners",
                    "Make a cylinder 30 mm across and 40 mm tall",
                    "Make a box 60 by 40 by 20 mm"]
        }
        if session.selectedFace != nil { return ["Add a round boss 10 mm across and 5 mm tall here", "Drill an M3 counterbore hole in the middle of this face"] }
        if session.selectedEdge != nil { return ["Round this edge 2 mm", "Chamfer this edge 1 mm"] }
        return ["How big is it, and what is its volume?", "Round the vertical edges 3 mm", "Hollow it out with 2 mm walls, open at the top"]
    }

    func send(_ text: String? = nil) {
        let request = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isWorking, !session.isProjectBusy else { return }
        // Questions remain available in viewing mode. Only a request begun with editing access
        // can produce a draft, including when its response arrives after the trial ends.
        let mayEdit = session.hasEditingAccess && !session.isReadOnly
        // The model must not change under the request; drafts and tools end first.
        if !session.isReviewingAssistant { session.cancelTransient() }
        if text == nil { draft = "" }
        messages.append(Message(role: .user, text: request))
        let reply = Message(role: .assistant, text: "", activity: "Thinking", isWorking: true)
        messages.append(reply)
        let id = reply.id, epoch = session.assistantEpoch
        isWorking = true
        session.isAssistantWorking = true
        let base = session.assistantBase, selection = session.assistantSelection, choice = choice, responder = responder
        task = Task { [weak self] in
            var turn: AssistantEngine.Turn?, failure: AssistantFailure?, cancelled = false
            do {
                turn = try await responder(request, base, selection, choice, { activity in
                    self?.update(id) { $0.activity = activity }
                }, { text in
                    // Streamed text shows about ten times a second: every token redrew the whole
                    // conversation (November 8, 2026). The reply's final text replaces it at the end.
                    guard let self else { return }
                    let now = Date()
                    guard now.timeIntervalSince(self.lastStreamedText) >= 0.1 else { self.pendingStreamedText = (id, text); return }
                    self.lastStreamedText = now
                    self.pendingStreamedText = nil
                    self.update(id) { $0.text = text }
                })
            } catch is CancellationError {
                cancelled = true
            } catch {
                failure = (error as? AssistantFailure) ?? AssistantFailure(message: error.localizedDescription)
            }
            self?.finish(id, epoch: epoch, turn: turn, failure: failure, cancelled: cancelled, mayEdit: mayEdit)
        }
    }

    private func update(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private var lastStreamedText = Date.distantPast
    /// Text that arrived inside the last tenth of a second, shown when the request ends.
    private var pendingStreamedText: (id: Message.ID, text: String)?

    private func finish(_ id: Message.ID, epoch: Int, turn: AssistantEngine.Turn?, failure: AssistantFailure?, cancelled: Bool, mayEdit: Bool) {
        if let pending = pendingStreamedText, pending.id == id { update(id) { $0.text = pending.text } }
        pendingStreamedText = nil
        lastStreamedText = .distantPast
        isWorking = false
        // A request can use up the cloud quota.
        refreshModelStatus()
        session.isAssistantWorking = false
        task = nil
        // The document was replaced while this request ran: its changes no longer apply.
        let cancelled = cancelled || epoch != session.assistantEpoch
        update(id) { message in
            message.isWorking = false
            message.activity = nil
            if cancelled {
                message.text = message.text.isEmpty ? "Stopped." : message.text
                return
            }
            if let failure {
                message.text = failure.message
                message.details = failure.details
                message.failed = true
                return
            }
            guard let turn else { return }
            message.text = turn.reply.isEmpty ? (turn.bench.hasChanges ? "Here are the changes." : "Done.") : turn.reply
            message.backend = turn.backend
            if let fallback = turn.fallback {
                message.fallbackNote = "Private Cloud Compute could not answer, so the on-device model did."
                message.details = [fallback.message] + fallback.details
            }
            message.changes = turn.bench.changes
            // Checks describe a draft: a question or a reply without a checklist shows none.
            if turn.bench.hasChanges && !turn.requirements.results.isEmpty { message.requirements = turn.requirements }
        }
        guard !cancelled, failure == nil, let turn, turn.bench.hasChanges else { return }
        guard mayEdit else {
            update(id) { message in
                message.text = "Creating and editing require an active trial or purchase. Your project has not changed. You can still ask questions about it."
                message.changes = []
                message.requirements = nil
            }
            if !session.hasEditingAccess { session.showPurchaseOffer = true }
            return
        }
        // The review covers every reply since the last Keep or Discard.
        guard session.showAssistantPreview(turn.bench.workspace, focus: turn.bench.focus, authorizedBeforeExpiration: mayEdit) else {
            update(id) { message in
                message.text += "\n\nThese changes could not be used, so they were left out."
                    + (session.isReviewingAssistant ? " The earlier changes are still under review." : "")
                message.changes = []
                message.requirements = nil
            }
            return
        }
        if session.isReviewingAssistant { update(id) { $0.review = .pending } }
        // Earlier replies' changes are no longer shown when this request ended the review.
        else { resolve(.discarded) }
    }

    func stop() { task?.cancel() }

    /// The session dropped the request and review (the file was reloaded): stop, and mark the changes discarded.
    private func abandon() {
        stop()
        resolve(.discarded)
    }

    func keep() {
        guard session.isReviewingAssistant, !isWorking else { return }
        guard session.keepAssistantChanges() else { return }
        resolve(.kept)
    }

    func discard() {
        guard session.isReviewingAssistant, !isWorking else { return }
        session.discardAssistantChanges()
        resolve(.discarded)
    }

    private func resolve(_ review: Message.Review) {
        for index in messages.indices where messages[index].review == .pending { messages[index].review = review }
    }

    /// Clears the conversation (pending changes stay under review).
    func newConversation() {
        stop()
        engine.reset()
        messages.removeAll { $0.review != .pending }
    }

    /// Asks again after a failure.
    func retry(_ message: Message) {
        guard !isWorking, let index = messages.firstIndex(of: message), index > 0, messages[index - 1].role == .user else { return }
        let request = messages[index - 1].text
        messages.removeSubrange((index - 1)...index)
        send(request)
    }
}
