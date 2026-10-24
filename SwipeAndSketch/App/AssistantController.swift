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
        var backend: AssistantBackend?
        var isWorking = false
        var failed = false
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
    @Published private(set) var selectionLabel: String?
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
        // @Published sends before the property changes, so labels are built from the values sent.
        session.$selection.removeDuplicates().sink { [weak self] selection in
            guard let self else { return }
            updateSelectionLabel(ModelingSession.assistantSelection(for: selection), base: session.assistantBase)
        }.store(in: &observers)
        // Sketch items picked along with the selection (it is already set when they change).
        session.$extraSelection.removeDuplicates().dropFirst().sink { [weak self] extra in
            guard let self else { return }
            updateSelectionLabel(ModelingSession.assistantSelection(for: (session.selection.map { [$0] } ?? []) + extra), base: session.assistantBase)
        }.store(in: &observers)
        session.$assistantPreview.sink { [weak self] preview in
            guard let self else { return }
            isReviewing = preview != nil
            updateSelectionLabel(session.assistantSelection, base: preview ?? session.workspace)
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.refreshModelStatus()
        }.store(in: &observers)
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
            status = ModelStatus(title: AssistantEngine.unavailableReason(choice == .cloud ? .cloud : .onDevice) ?? "Unavailable", available: false)
        }
        if status != modelStatus { modelStatus = status }
    }

    private func updateSelectionLabel(_ selection: AssistantSelection?, base: Workspace) {
        let label = selection.map {
            AssistantWorkbench(workspace: base, selection: $0).selectionDescription()
                .replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
        }
        if label != selectionLabel { selectionLabel = label }
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
        guard !request.isEmpty, !isWorking, !session.isReadOnly, !session.isProjectBusy else { return }
        // After the free trial the assistant needs Unlock and AI Assistant (Licensing.swift).
        guard LicenseStore.shared.access.canUseAssistant else { LicenseStore.shared.isShowingStore = true; return }
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
            var turn: AssistantEngine.Turn?, failure: String?, cancelled = false
            do {
                turn = try await responder(request, base, selection, choice, { activity in
                    self?.update(id) { $0.activity = activity }
                }, { text in
                    self?.update(id) { $0.text = text }
                })
            } catch is CancellationError {
                cancelled = true
            } catch {
                failure = (error as? AssistantFailure)?.message ?? error.localizedDescription
            }
            self?.finish(id, epoch: epoch, turn: turn, failure: failure, cancelled: cancelled)
        }
    }

    private func update(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func finish(_ id: Message.ID, epoch: Int, turn: AssistantEngine.Turn?, failure: String?, cancelled: Bool) {
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
                message.text = failure
                message.failed = true
                return
            }
            guard let turn else { return }
            message.text = turn.reply.isEmpty ? (turn.bench.hasChanges ? "Here are the changes." : "Done.") : turn.reply
            message.backend = turn.backend
            message.changes = turn.bench.changes
        }
        guard !cancelled, failure == nil, let turn, turn.bench.hasChanges else { return }
        // The review covers every reply since the last Keep or Discard.
        session.showAssistantPreview(turn.bench.workspace, focus: turn.bench.focus)
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
        guard session.isReviewingAssistant, !isWorking, session.keepAssistantChanges() else { return }
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
