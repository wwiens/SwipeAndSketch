import XCTest
import Foundation
@testable import SwipeAndSketch

/// Claude and OpenAI through the design harness: one strict structured request with no tools, the
/// proposal applied and measured by the app, and a hand-off to the CAD tools for what it cannot
/// express. The HTTP boundary is scripted; the geometry is built by the real kernel.
@MainActor final class DesignHarnessProviderTests: XCTestCase {
    let fakeKey = "test-credential-never-send-to-network"
    private var harness = true
    private static let preferenceKeys = AIProvider.allCases.flatMap { p in ["model", "effort", "models"].map { "assistant.\(p.rawValue).\($0)" } }
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        harness = AssistantEngine.designHarnessEnabled
        AssistantEngine.designHarnessEnabled = true
        saved = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
    override func tearDown() async throws {
        AssistantEngine.designHarnessEnabled = harness
        for key in Self.preferenceKeys { UserDefaults.standard.set(saved[key], forKey: key) }
        try await super.tearDown()
    }

    func payload(_ request: URLRequest) throws -> AssistantJSON { try JSONDecoder().decode(AssistantJSON.self, from: XCTUnwrap(request.httpBody)) }
    func http(_ body: AssistantJSON, url: URL, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONEncoder().encode(body), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    /// The mounting plate as a proposal's JSON text.
    func plate(rightDiameter: Double = 4.5) -> String {
        var features = [DesignFeature(id: "plate", body: "Plate", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0,
                                      width: 80, depth: 50, height: 5, radius: 5)]
        for (x, y) in [(-34.0, -19.0), (-34, 19), (34, -19), (34, 19)] {
            features.append(DesignFeature(id: "bore\(features.count)", body: "Plate", kind: .cylinder, operation: .cut, axis: .pz,
                                          x: x, y: y, z: 0, height: 5, radius: (x > 0 ? rightDiameter : 4.5) / 2))
        }
        let proposal = DesignProposal(intent: .change, message: "Corner radius 5 mm.",
                                      requirements: [.init(quote: "80 × 50 × 5 mm plate", kind: "bodySize", target: "Plate", expected: [80, 50, 5])],
                                      features: features)
        return String(decoding: try! JSONEncoder().encode(proposal), as: UTF8.self)
    }

    func claudeAnswer(_ text: String, reason: String = "end_turn") -> AssistantJSON {
        .object(["role": .string("assistant"), "model": .string("claude-opus-5-5"), "stop_reason": .string(reason),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    func openAIAnswer(_ text: String) -> AssistantJSON {
        .object(["status": .string("completed"), "model": .string("gpt-fixture"), "output": .array([
            .object(["type": .string("reasoning"), "summary": .array([])]),
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])
        ])])
    }

    func testOpenAISendsOneStrictProposalAndTheAppBuildsIt() async throws {
        try XCTSkipUnless(AIProvider.offersOpenAIAndGemini, "OpenAI is hidden in this build.")
        var requests: [AssistantJSON] = []
        let client = OpenAIAssistant { request in
            requests.append(try self.payload(request))
            return try self.http(self.openAIAnswer(self.plate()), url: OpenAIAssistant.endpoint)
        }
        let engine = AssistantEngine(openAI: client, providerKey: { $0 == .openAI ? self.fakeKey : nil })
        let turn = try await engine.respond(to: "Make an 80 × 50 × 5 mm plate with four Ø4.5 holes.", workspace: Workspace(), selection: nil,
                                            choice: .openAI, onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(requests.count, 1)
        let body = requests[0]
        XCTAssertNil(body["tools"], "No tools in a design proposal")
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["text"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(body["text"]?["format"]?["name"]?.string, "design_proposal")
        XCTAssertEqual(body["text"]?["format"]?["strict"], .bool(true))
        XCTAssertEqual(body["text"]?["format"]?["schema"]?["additionalProperties"], .bool(false))
        XCTAssertTrue(body["input"]?.string?.contains("Design document:\nBlank") ?? false)
        XCTAssertEqual(turn.backend, .openAI)
        XCTAssertEqual(turn.bench.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: turn.bench.workspace.bodies[0]).volume, 19_574.613, accuracy: 0.1)
        XCTAssertEqual(turn.reply, "Corner radius 5 mm.", "The model's sentence; the card lists the changes")
        XCTAssertTrue(turn.bench.changes.first?.hasPrefix("New Plate: 80 × 50 × 5 mm block, R5 corners") ?? false, "\(turn.bench.changes)")
        XCTAssertEqual(turn.requirements.results.map(\.status), [.passed])
    }

    func testGeminiSendsTheSchemaAsItsResponseFormat() async throws {
        try XCTSkipUnless(AIProvider.offersOpenAIAndGemini, "Gemini is hidden in this build.")
        var requests: [AssistantJSON] = []
        let client = GeminiAssistant { request in
            requests.append(try self.payload(request))
            return try self.http(.object(["status": .string("completed"), "model": .string("gemini-fixture"), "steps": .array([
                .object(["type": .string("thought"), "signature": .string("x")]),
                .object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string(self.plate())])])])
            ])]), url: GeminiAssistant.endpoint)
        }
        let engine = AssistantEngine(gemini: client, providerKey: { $0 == .gemini ? self.fakeKey : nil })
        let turn = try await engine.respond(to: "Make an 80 × 50 × 5 mm plate with four Ø4.5 holes.", workspace: Workspace(), selection: nil,
                                            choice: .gemini, onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(requests.count, 1)
        let body = requests[0]
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["response_format"]?["type"]?.string, "text")
        XCTAssertEqual(body["response_format"]?["mime_type"]?.string, "application/json")
        XCTAssertEqual(body["response_format"]?["schema"]?["additionalProperties"], .bool(false))
        XCTAssertEqual(turn.backend, .gemini)
        XCTAssertEqual(try SolidKernel.solid(for: turn.bench.workspace.bodies[0]).volume, 19_574.613, accuracy: 0.1)
        XCTAssertEqual(turn.reply, "Corner radius 5 mm.")
    }

    func testClaudeUsesStructuredOutputAndHandsUnsupportedRequestsToTheTools() async throws {
        var requests: [AssistantJSON] = []
        let claude = ClaudeAssistant { request in
            let body = try self.payload(request)
            requests.append(body)
            if body["output_config"]?["format"] != nil {
                return try self.http(self.claudeAnswer(#"{"intent":"handOff","message":"","requirements":[],"features":[],"removeIDs":[],"solidOps":[]}"#),
                                     url: ClaudeAssistant.endpoint)
            }
            return try self.http(self.claudeAnswer("Threads need the thread tool."), url: ClaudeAssistant.endpoint)
        }
        let engine = AssistantEngine(claude: claude, claudeKey: { self.fakeKey })
        var activity: [String] = []
        let turn = try await engine.respond(to: "Add an M6 thread to the post.", workspace: Workspace(), selection: nil,
                                            choice: .claude, onActivity: { activity.append($0) }, onText: { _ in })
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0]["tools"])
        XCTAssertEqual(requests[0]["output_config"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(requests[0]["output_config"]?["effort"]?.string, "high")
        XCTAssertNotNil(requests[1]["tools"], "The hand-off runs the tool loop")
        XCTAssertEqual(turn.reply, "Threads need the thread tool.")
        XCTAssertEqual(activity.prefix(1), ["Planning the design"])
        XCTAssertTrue(activity.contains("Using the CAD tools"))
    }

    func testClaudeEditsBeforeKeepBuildOnThePreview() async throws {
        var stage = 0
        let claude = ClaudeAssistant { request in
            stage += 1
            let input = try self.payload(request)["messages"]?.array?.first?["content"]?.string ?? ""
            if stage == 2 {
                // The second request sees the plate the first one made, by alias.
                XCTAssertTrue(input.contains("\"id\":\"B1.F4\""), input)
                let edit = #"{"intent":"change","message":"","requirements":[],"removeIDs":[],"solidOps":[],"features":["#
                    + #"{"id":"B1.F4","body":"B1","kind":"cylinder","operation":"cut","axis":"+z","x":34,"y":-19,"z":0,"height":5,"radius":3},"#
                    + #"{"id":"B1.F5","body":"B1","kind":"cylinder","operation":"cut","axis":"+z","x":34,"y":19,"z":0,"height":5,"radius":3}]}"#
                return try self.http(self.claudeAnswer(edit), url: ClaudeAssistant.endpoint)
            }
            return try self.http(self.claudeAnswer(self.plate()), url: ClaudeAssistant.endpoint)
        }
        let engine = AssistantEngine(claude: claude, claudeKey: { self.fakeKey })
        let first = try await engine.respond(to: "Make an 80 × 50 × 5 mm plate with four holes.", workspace: Workspace(), selection: nil,
                                             choice: .claude, onActivity: { _ in }, onText: { _ in })
        let second = try await engine.respond(to: "Enlarge only the two right holes to 6 mm.", workspace: first.bench.workspace, selection: nil,
                                              choice: .claude, onActivity: { _ in }, onText: { _ in })
        let before = first.bench.workspace.bodies[0], after = second.bench.workspace.bodies[0]
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.cuts.map(\.id), before.cuts.map(\.id))
        XCTAssertEqual(try SolidKernel.solid(for: after).volume, 19_450.913, accuracy: 0.1)
        XCTAssertEqual(second.reply, "Plate: Ø4.5 mm cut 5 mm deep along +Z → Ø6 mm cut 5 mm deep along +Z ×2.", "With no sentence, the reply is the changes")
    }

    func testClaudeRefusalsAndCutOffRepliesAreErrorsNotDesigns() async throws {
        for (reason, kind) in [("refusal", AssistantFailure.Kind.refusal), ("max_tokens", .execution)] {
            let claude = ClaudeAssistant { _ in try self.http(self.claudeAnswer("{", reason: reason), url: ClaudeAssistant.endpoint) }
            let engine = AssistantEngine(claude: claude, claudeKey: { self.fakeKey })
            do {
                _ = try await engine.respond(to: "Make a plate.", workspace: Workspace(), selection: nil, choice: .claude, onActivity: { _ in }, onText: { _ in })
                XCTFail("\(reason) should fail")
            } catch let failure as AssistantFailure {
                XCTAssertEqual(failure.kind, kind, failure.message)
            }
        }
    }

    func testSwitchingTheHarnessOffUsesOnlyTheTools() async throws {
        AssistantEngine.designHarnessEnabled = false
        var requests: [AssistantJSON] = []
        let claude = ClaudeAssistant { request in
            requests.append(try self.payload(request))
            return try self.http(self.claudeAnswer("Done."), url: ClaudeAssistant.endpoint)
        }
        let engine = AssistantEngine(claude: claude, claudeKey: { self.fakeKey })
        _ = try await engine.respond(to: "How big is it?", workspace: Workspace(), selection: nil, choice: .claude, onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(requests.count, 1)
        XCTAssertNotNil(requests[0]["tools"])
        XCTAssertNil(requests[0]["output_config"]?["format"])
    }
}
