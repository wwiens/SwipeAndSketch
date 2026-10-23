import XCTest
@testable import SwipeAndSketch

/// The assistant panel's review flow, with the model replaced by scripted workbench changes, and
/// (opt-in) live requests through the real engine.
@MainActor final class AssistantTests: XCTestCase {
    func boxScene() -> ModelingSession {
        let session = ModelingSession(inMemory: true)
        session.addShape(.init(kind: .rectangle, plane: .top, start: .init(x: -30, y: -20), end: .init(x: 30, y: 20)))
        session.beginExtrusion(); session.extrusionDepth = 20; session.confirmExtrusion()
        return session
    }

    /// A controller whose "model" runs `script` on the workbench and replies with `reply`.
    func controller(_ session: ModelingSession, reply: String = "Done.",
                    script: @escaping (inout AssistantWorkbench) throws -> Void) -> AssistantController {
        let assistant = AssistantController(session: session)
        assistant.responder = { _, workspace, selection, _, onActivity, _ in
            onActivity("Working")
            var bench = AssistantWorkbench(workspace: workspace, selection: selection)
            try script(&bench)
            return AssistantEngine.Turn(reply: reply, bench: bench, backend: .onDevice)
        }
        return assistant
    }

    func waitUntilIdle(_ assistant: AssistantController) async {
        for _ in 0..<400 where assistant.isWorking { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(assistant.isWorking)
    }

    func testChangesPreviewUntilKeptAsOneUndoStep() async throws {
        let session = boxScene()
        let before = session.workspace
        let assistant = controller(session) { try $0.finish(.fillet, body: "Body 01", edges: "vertical", size: 3) }
        assistant.send("Round the vertical edges 3 mm")
        XCTAssertTrue(session.isAssistantWorking)
        XCTAssertTrue(session.isEditingBlocked, "the document waits while the assistant works")
        await waitUntilIdle(assistant)

        XCTAssertTrue(session.isReviewingAssistant)
        XCTAssertEqual(session.workspace, before, "nothing is committed before Keep")
        XCTAssertEqual(session.displayWorkspace.bodies[0].finishes.count, 1, "the canvas shows the preview")
        XCTAssertTrue(session.isEditingBlocked, "editing waits for Keep or Discard")
        XCTAssertEqual(assistant.pendingChanges, ["Fillet 3 mm on 4 edges of Body 01"])
        XCTAssertEqual(assistant.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(assistant.messages[1].review, .pending)

        assistant.keep()
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertEqual(session.workspace.bodies[0].finishes.count, 1)
        XCTAssertEqual(session.selection, .body(session.workspace.bodies[0].id), "what changed is selected")
        XCTAssertEqual(assistant.messages[1].review, .kept)
        session.undo()
        XCTAssertEqual(session.workspace, before, "Keep is a single undo step")
    }

    func testAResetDropsTheReviewAndAnyLateResult() async throws {
        // The document was reloaded from its file: changes built on the old contents must not apply.
        let session = boxScene()
        let before = session.workspace
        let assistant = controller(session) { try $0.finish(.fillet, body: "Body 01", edges: "vertical", size: 3) }
        assistant.send("Round the vertical edges 3 mm")
        await waitUntilIdle(assistant)
        XCTAssertTrue(session.isReviewingAssistant)
        session.resetAssistant()
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertEqual(session.displayWorkspace, before)
        XCTAssertEqual(assistant.messages[1].review, .discarded)

        assistant.responder = { _, workspace, selection, _, _, _ in
            try? await Task.sleep(for: .milliseconds(150))
            var bench = AssistantWorkbench(workspace: workspace, selection: selection)
            try bench.finish(.chamfer, body: "Body 01", edges: "top", size: 1)
            return AssistantEngine.Turn(reply: "Done.", bench: bench, backend: .onDevice)
        }
        assistant.send("Chamfer the top edges 1 mm")
        session.resetAssistant()
        await waitUntilIdle(assistant)
        XCTAssertFalse(session.isReviewingAssistant, "a result that arrives after the reset is not shown")
        XCTAssertEqual(session.workspace, before)
    }

    func testTryAgainWaitsForTheRequestInProgress() async throws {
        let session = boxScene()
        let assistant = controller(session) { _ in throw AssistantWorkbench.Failure("No such edge.") }
        assistant.send("Round the purple edges")
        await waitUntilIdle(assistant)
        let failed = try XCTUnwrap(assistant.messages.last)
        XCTAssertTrue(failed.failed)
        assistant.responder = { _, workspace, selection, _, _, _ in
            try? await Task.sleep(for: .milliseconds(150))
            return AssistantEngine.Turn(reply: "Body 01 is 60 × 40 × 20 mm.", bench: AssistantWorkbench(workspace: workspace, selection: selection), backend: .onDevice)
        }
        assistant.send("How big is it?")
        assistant.retry(failed)
        XCTAssertEqual(assistant.messages.count, 4, "the failed exchange stays while another request runs")
        await waitUntilIdle(assistant)
        XCTAssertEqual(assistant.messages.last?.text, "Body 01 is 60 × 40 × 20 mm.")
    }

    func testDiscardLeavesTheModelAsItWas() async throws {
        let session = boxScene()
        let before = session.workspace
        let assistant = controller(session) { try $0.shell(body: "Body 01", openFaces: ["top"], thickness: 2) }
        assistant.send("Hollow it out")
        await waitUntilIdle(assistant)
        XCTAssertTrue(session.isReviewingAssistant)
        assistant.discard()
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertFalse(session.isEditingBlocked)
        XCTAssertEqual(session.workspace, before)
        XCTAssertEqual(session.displayWorkspace, before)
        XCTAssertEqual(assistant.messages[1].review, .discarded)
        XCTAssertFalse(session.history.canRedo, "Discard is not an undo step")
    }

    func testFollowUpRequestsBuildOnThePreviewAndKeepTogether() async throws {
        let session = boxScene()
        let before = session.workspace
        var step = 0
        let assistant = controller(session) { bench in
            step += 1
            if step == 1 { try bench.finish(.fillet, body: "Body 01", edges: "vertical", size: 3) }
            else { try bench.hole(body: "Body 01", face: "top", kind: .simple, size: "M3", depth: nil) }
        }
        assistant.send("Round the vertical edges")
        await waitUntilIdle(assistant)
        assistant.send("Now drill an M3 hole in the top")
        await waitUntilIdle(assistant)
        XCTAssertEqual(session.displayWorkspace.bodies[0].finishes.count, 1, "the second request started from the first's preview")
        XCTAssertEqual(session.displayWorkspace.bodies[0].cuts.count, 1)
        XCTAssertEqual(assistant.pendingChanges.count, 2)
        assistant.keep()
        XCTAssertEqual(assistant.messages.filter { $0.review == .kept }.count, 2)
        session.undo()
        XCTAssertEqual(session.workspace, before, "both requests' changes are one undo step")
    }

    func testFailuresAndAnswersChangeNothing() async throws {
        let session = boxScene()
        let before = session.workspace
        let failing = controller(session) { try $0.finish(.fillet, body: "Body 01", edges: "top", size: 50) }
        failing.send("Round the top 50 mm")
        await waitUntilIdle(failing)
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertTrue(failing.messages[1].failed)
        XCTAssertTrue(failing.messages[1].text.contains("smaller"), failing.messages[1].text)
        XCTAssertEqual(session.workspace, before)

        let answering = controller(session, reply: "It is 60 × 40 × 20 mm.") { _ in }
        answering.send("How big is it?")
        await waitUntilIdle(answering)
        XCTAssertFalse(session.isReviewingAssistant)
        XCTAssertEqual(answering.messages[1].text, "It is 60 × 40 × 20 mm.")
        XCTAssertTrue(answering.messages[1].changes.isEmpty)
        XCTAssertFalse(session.isEditingBlocked)
    }

    func testTheSelectionIsTheRequestsContext() async throws {
        let session = boxScene()
        let body = session.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        let top = try XCTUnwrap((0..<solid.faceCount).first { solid.facePlane($0)?.normal.z ?? 0 > 0.99 })
        session.select(.face(FaceSelection(bodyID: body.id, face: top, plane: SketchPlane.through(solid.facePlane(top)!.origin, normal: solid.facePlane(top)!.normal),
                                           center: solid.faceCenter(top)!)))
        var seen: AssistantSelection?
        let assistant = AssistantController(session: session)
        XCTAssertEqual(assistant.selectionLabel, "Body 01 face \(top)")
        // The label is kept, not rebuilt on every redraw, and follows the selection.
        session.select(.body(body.id))
        XCTAssertEqual(assistant.selectionLabel, "Body 01")
        session.select(nil)
        XCTAssertNil(assistant.selectionLabel)
        session.select(.face(FaceSelection(bodyID: body.id, face: top, plane: SketchPlane.through(solid.facePlane(top)!.origin, normal: solid.facePlane(top)!.normal),
                                           center: solid.faceCenter(top)!)))
        XCTAssertEqual(assistant.selectionLabel, "Body 01 face \(top)")
        assistant.responder = { _, workspace, selection, _, _, _ in
            seen = selection
            var bench = AssistantWorkbench(workspace: workspace, selection: selection)
            try bench.hole(body: "selected", face: "selected", kind: .simple, size: "M3", depth: nil)
            return AssistantEngine.Turn(reply: "", bench: bench, backend: .cloud)
        }
        assistant.send("Drill an M3 hole here")
        await waitUntilIdle(assistant)
        XCTAssertEqual(seen, .face(bodyID: body.id, face: top))
        XCTAssertEqual(session.displayWorkspace.bodies[0].cuts.first?.operation, .hole)
        XCTAssertEqual(assistant.messages[1].text, "Here are the changes.")
    }

    func testTheCloudModelNeedsTheSignedEntitlement() throws {
        // Unsigned test builds have no entitlements; signed ones carry the cloud entitlement.
        let entitlements = PrivateCloudEntitlement.signedEntitlements()
        XCTAssertEqual(PrivateCloudEntitlement.isPresent, entitlements?[PrivateCloudEntitlement.key] as? Bool == true)
        if !PrivateCloudEntitlement.isPresent {
            XCTAssertEqual(AssistantEngine.unavailableReason(.cloud), "Private Cloud Compute is not available in this version of the app. Choose On device.")
            XCTAssertFalse(AssistantEngine.backends(for: .automatic).contains(.cloud), "Automatic never picks a cloud model that would stop the app")
        }
        print("Private Cloud Compute entitlement present: \(PrivateCloudEntitlement.isPresent); entitlements: \(entitlements?.keys.sorted() ?? [])")
    }

    /// Live requests through the real engine. Run with TEST_RUNNER_LIVE_ASSISTANT=1 (and
    /// TEST_RUNNER_LIVE_BACKEND=cloud or onDevice); prints each request's trace.
    func testLiveRequests() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["LIVE_ASSISTANT"] == "1", "Set TEST_RUNNER_LIVE_ASSISTANT=1 to run live model requests.")
        let choice = AssistantModelChoice(rawValue: environment["LIVE_BACKEND"] ?? "") ?? .cloud
        if let reason = AssistantEngine.backends(for: choice).first.flatMap(AssistantEngine.unavailableReason) { throw XCTSkip(reason) }
        let requests = (environment["LIVE_REQUESTS"]?.components(separatedBy: "|")) ?? [
            "How big is it, and what is its volume?",
            "Round the vertical edges 3 mm",
            "Hollow it out with 2 mm walls, open at the top",
            "Add a round boss 12 mm across and 8 mm tall in the middle of the top",
            "Make a plate 80 by 50 mm and 5 mm thick with an M3 hole 6 mm in from each corner, next to the box",
        ]
        let session = environment["LIVE_SCENE"] == "empty" ? ModelingSession(inMemory: true) : boxScene()
        for request in requests {
            let engine = AssistantEngine()
            if let seconds = environment["LIVE_TIMEOUT"].flatMap(Double.init) { AssistantEngine.cloudTimeout = seconds }
            engine.context.onResult = { print("      ↳ \($0.prefix(240))") }
            print("▶︎ [\(choice.rawValue)] \(request)")
            let started = Date()
            do {
                let turn = try await engine.respond(to: request, workspace: session.workspace, selection: nil, choice: choice,
                                                    onActivity: { print("  · \($0)") }, onText: { _ in })
                print("  ⟵ \(turn.reply)\n  changes: \(turn.bench.changes.joined(separator: " | "))")
                print(String(format: "  %.1f s on %@", Date().timeIntervalSince(started), turn.backend.title))
            } catch {
                print("  ✗ \(error.localizedDescription) [\(error)]")
            }
        }
    }
}
