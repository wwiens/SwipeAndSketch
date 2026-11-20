import XCTest
import Foundation
@testable import SwipeAndSketch

/// OpenAI and Gemini, and each provider's model list and settings. The HTTP boundary is scripted;
/// every geometry change runs the actual CAD tools and kernel, as in ClaudeAssistantTests.
@MainActor final class ProviderAssistantTests: XCTestCase {
    let fakeKey = "test-credential-never-send-to-network"
    private static let preferenceKeys = AIProvider.allCases.flatMap { p in ["model", "effort", "models"].map { "assistant.\(p.rawValue).\($0)" } }
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        saved = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        // These tests script the tool loop; DesignHarnessProviderTests covers the design proposal.
        harness = AssistantEngine.designHarnessEnabled
        AssistantEngine.designHarnessEnabled = false
    }
    private var harness = true
    override func tearDown() async throws {
        AssistantEngine.designHarnessEnabled = harness
        for key in Self.preferenceKeys { UserDefaults.standard.set(saved[key], forKey: key) }
        try await super.tearDown()
    }

    func payload(_ request: URLRequest) throws -> AssistantJSON { try JSONDecoder().decode(AssistantJSON.self, from: XCTUnwrap(request.httpBody)) }
    func http(_ body: AssistantJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONEncoder().encode(body), try XCTUnwrap(HTTPURLResponse(url: OpenAIAssistant.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
    func run(_ engine: AssistantEngine, choice: AssistantModelChoice) async throws -> AssistantEngine.Turn {
        try await engine.respond(to: "Make an open-top container with 2 mm walls and floor.",
                                 workspace: ClaudeAssistantTests.fixture("block"), selection: nil, choice: choice,
                                 onActivity: { _ in }, onText: { _ in })
    }
    let container: AssistantJSON = .object(["body": .string("Body 01"), "openFaces": .array([.string("top")]), "thickness": .number(2)])

    // MARK: OpenAI

    /// OpenAI and Gemini stay hidden until `AIProvider.offersOpenAIAndGemini` is turned on
    /// (November 13, 2026); a stored choice of either falls back to Claude.
    func testOpenAIAndGeminiAreHiddenUntilOffered() throws {
        try XCTSkipIf(AIProvider.offersOpenAIAndGemini, "OpenAI and Gemini are offered.")
        XCTAssertEqual(AIProvider.offered, [.claude])
        XCTAssertEqual(AIProvider.offeredNames, "Claude")
        XCTAssertEqual(AssistantModelChoice.offered, [.claude])
        XCTAssertEqual(AssistantModelChoice.stored("openai"), .claude)
        XCTAssertEqual(AssistantModelChoice.stored("gemini"), .claude)
        XCTAssertEqual(AssistantModelChoice.stored("claude"), .claude)
        XCTAssertEqual(AssistantModelChoice.stored(nil), .claude)
    }

    /// OpenAI and Gemini are offered beside Claude again (November 17, 2026).
    func testOpenAIAndGeminiAreOffered() throws {
        try XCTSkipUnless(AIProvider.offersOpenAIAndGemini, "OpenAI and Gemini are hidden.")
        XCTAssertEqual(AIProvider.offered, [.claude, .openAI, .gemini])
        XCTAssertEqual(AIProvider.offeredNames, "Claude, OpenAI, or Gemini")
        XCTAssertEqual(AssistantModelChoice.offered, [.claude, .openAI, .gemini])
        XCTAssertEqual(AssistantModelChoice.stored("openai"), .openAI)
        XCTAssertEqual(AssistantModelChoice.stored("gemini"), .gemini)
    }

    /// Apple's models were removed (November 19, 2026): a stored Automatic, Private Cloud Compute,
    /// or on-device choice becomes Claude, the default.
    func testRemovedAppleChoicesBecomeClaude() {
        for removed in ["automatic", "cloud", "onDevice"] { XCTAssertEqual(AssistantModelChoice.stored(removed), .claude, removed) }
        XCTAssertEqual(AssistantModelChoice.stored(nil), .claude)
    }

    func testOpenAIRunsToolsStatelesslyAndReturnsReasoning() async throws {
        ProviderSettings.setModel(ProviderModel(id: "gpt-test", name: "GPT Test"), for: .openAI)
        ProviderSettings.setEffort(.medium, for: .openAI)
        let reasoning: AssistantJSON = .object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("opaque")])
        let arguments = String(decoding: try JSONEncoder().encode(container), as: UTF8.self)
        let call: AssistantJSON = .object(["type": .string("function_call"), "id": .string("fc_1"), "call_id": .string("call_1"),
                                           "name": .string("make_container"), "arguments": .string(arguments)])
        let message: AssistantJSON = .object(["type": .string("message"), "role": .string("assistant"),
                                              "content": .array([.object(["type": .string("output_text"), "text": .string("The block is now an open container.")])])])
        var requests: [URLRequest] = []
        let client = OpenAIAssistant { request in
            requests.append(request)
            let output: [AssistantJSON] = requests.count == 1 ? [reasoning, call] : [message]
            return try self.http(.object(["status": .string("completed"), "output": .array(output)]))
        }
        let engine = AssistantEngine(openAI: client, providerKey: { $0 == .openAI ? self.fakeKey : nil })
        let turn = try await run(engine, choice: .openAI)
        XCTAssertEqual(turn.backend, .openAI)
        XCTAssertEqual(turn.reply, "The block is now an open container.")
        XCTAssertTrue(turn.bench.hasChanges, "The shell ran through the real tool")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, OpenAIAssistant.endpoint)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeKey)")
        let first = try payload(requests[0]), second = try payload(requests[1])
        XCTAssertEqual(first["model"]?.string, "gpt-test")
        XCTAssertEqual(first["reasoning"]?["effort"]?.string, "medium")
        XCTAssertEqual(first["store"]?.bool, false)
        XCTAssertNotNil(first["tools"]?.array?.first { $0["name"]?.string == "make_container" })
        let input = try XCTUnwrap(second["input"]?.array)
        XCTAssertEqual(input.map { $0["type"]?.string ?? "user" }, ["user", "reasoning", "function_call", "function_call_output"],
                       "Reasoning goes back with the call and its result")
        XCTAssertEqual(input[1]["encrypted_content"]?.string, "opaque")
        XCTAssertEqual(input[3]["call_id"]?.string, "call_1")
        XCTAssertFalse(input[3]["output"]?.string?.hasPrefix("Error:") ?? true)
    }

    func testOpenAIRetriesWithoutEffortWhenAModelRefusesIt() async throws {
        var bodies: [AssistantJSON] = []
        let client = OpenAIAssistant { request in
            bodies.append(try self.payload(request))
            if bodies.count == 1 {
                return try self.http(.object(["error": .object(["message": .string("Unsupported parameter: 'reasoning.effort'.")])]), status: 400)
            }
            return try self.http(.object(["status": .string("completed"), "output": .array([.object(["type": .string("message"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("It is 20 mm tall.")])])])])]))
        }
        let engine = AssistantEngine(openAI: client, providerKey: { _ in self.fakeKey })
        let turn = try await engine.respond(to: "How tall is it?", workspace: ClaudeAssistantTests.fixture("block"), selection: nil, choice: .openAI,
                                            onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(turn.reply, "It is 20 mm tall.")
        XCTAssertNotNil(bodies[0]["reasoning"])
        XCTAssertNil(bodies[1]["reasoning"], "Asked again at the model's own default")
    }

    func testOpenAIFailuresAreClear() async throws {
        for (status, body, expected) in [(401, "{}", "rejected the API key"), (429, #"{"error":{"code":"insufficient_quota"}}"#, "credits"),
                                         (404, "{}", "not available")] {
            var calls = 0
            let client = OpenAIAssistant { _ in
                calls += 1
                return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: OpenAIAssistant.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)))
            }
            do { _ = try await run(AssistantEngine(openAI: client, providerKey: { _ in self.fakeKey }), choice: .openAI); XCTFail("\(status) must fail") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains(fakeKey))
            }
            XCTAssertEqual(calls, 1, "Quota and key failures are not retried")
        }
    }

    // MARK: Gemini

    func testGeminiRunsToolsStatelesslyAndReturnsSignedThoughts() async throws {
        ProviderSettings.setModel(ProviderModel(id: "gemini-test", name: "Gemini Test"), for: .gemini)
        let thought: AssistantJSON = .object(["type": .string("thought"), "signature": .string("signed-thought")])
        let call: AssistantJSON = .object(["type": .string("function_call"), "id": .string("call_9"), "name": .string("make_container"), "arguments": container])
        let output: AssistantJSON = .object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string("Shelled.")])])])
        var requests: [URLRequest] = []
        let client = GeminiAssistant { request in
            requests.append(request)
            let steps: [AssistantJSON] = requests.count == 1 ? [thought, call] : [output]
            return try self.http(.object(["id": .string("i_\(requests.count)"), "status": .string(requests.count == 1 ? "requires_action" : "completed"),
                                          "steps": .array(steps)]))
        }
        let engine = AssistantEngine(gemini: client, providerKey: { $0 == .gemini ? self.fakeKey : nil })
        let turn = try await run(engine, choice: .gemini)
        XCTAssertEqual(turn.backend, .gemini)
        XCTAssertEqual(turn.reply, "Shelled.")
        XCTAssertTrue(turn.bench.hasChanges)
        XCTAssertEqual(requests[0].url, GeminiAssistant.endpoint)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-goog-api-key"), fakeKey)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        let first = try payload(requests[0]), second = try payload(requests[1])
        XCTAssertEqual(first["model"]?.string, "gemini-test")
        XCTAssertEqual(first["store"]?.bool, false)
        XCTAssertEqual(first["generation_config"]?["thinking_level"]?.string, "high", "High unless chosen otherwise")
        let input = try XCTUnwrap(second["input"]?.array)
        XCTAssertEqual(input.compactMap { $0["type"]?.string }, ["user_input", "thought", "function_call", "function_result"])
        XCTAssertEqual(input[1]["signature"]?.string, "signed-thought")
        XCTAssertEqual(input[3]["call_id"]?.string, "call_9")
        XCTAssertEqual(input[3]["is_error"]?.bool, false)
    }

    func testGeminiRetriesWithoutThinkingWhenAModelRefusesIt() async throws {
        var bodies: [AssistantJSON] = []
        let client = GeminiAssistant { request in
            bodies.append(try self.payload(request))
            if bodies.count == 1 {
                return try self.http(.object(["error": .object(["message": .string("Thinking level is not supported for this model."),
                                                                "code": .string("invalid_request")])]), status: 400)
            }
            return try self.http(.object(["status": .string("completed"), "steps": .array([.object(["type": .string("model_output"),
                "content": .array([.object(["type": .string("text"), "text": .string("It is 20 mm tall.")])])])])]))
        }
        let engine = AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey })
        let turn = try await engine.respond(to: "How tall is it?", workspace: ClaudeAssistantTests.fixture("block"), selection: nil, choice: .gemini,
                                            onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(turn.reply, "It is 20 mm tall.")
        XCTAssertNotNil(bodies[0]["generation_config"]?["thinking_level"])
        XCTAssertNil(bodies[1]["generation_config"]?["thinking_level"], "Asked again at the model's own default")
    }

    /// Gemini 4 Carbon can spend its whole output budget thinking (November 17, 2026): the request
    /// comes back incomplete with a continuation token and no steps, and carries on with a larger budget.
    func testGeminiContinuesARequestThatRanOutOfOutputTokens() async throws {
        let call: AssistantJSON = .object(["type": .string("function_call"), "id": .string("call_1"), "name": .string("make_container"), "arguments": container])
        let output: AssistantJSON = .object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string("Shelled.")])])])
        var bodies: [AssistantJSON] = []
        let client = GeminiAssistant { request in
            XCTAssertEqual(request.timeoutInterval, GeminiAssistant.requestTimeout)
            bodies.append(try self.payload(request))
            switch bodies.count {
            case 1, 2: return try self.http(.object(["status": .string("incomplete"), "continuation_token": .string("token-\(bodies.count)")]))
            case 3: return try self.http(.object(["status": .string("requires_action"), "steps": .array([call])]))
            default: return try self.http(.object(["status": .string("completed"), "steps": .array([output])]))
            }
        }
        let turn = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini)
        XCTAssertEqual(turn.reply, "Shelled.")
        XCTAssertTrue(turn.bench.hasChanges)
        XCTAssertEqual(bodies.map { $0["generation_config"]?["max_output_tokens"]?.number }, [16384, 32768, 49152, 16384],
                       "The budget counts across continuations and starts over for the next round")
        XCTAssertEqual(bodies.map { $0["continuation_token"]?.string }, [nil, "token-1", "token-2", nil])
        XCTAssertEqual(bodies[1]["input"], bodies[0]["input"], "A continuation repeats the request")
        XCTAssertEqual(bodies[2]["generation_config"]?["thinking_level"]?.string, "high")
    }

    func testGeminiPastGooglesDeadlineSuggestsLowerEffort() async throws {
        let client = GeminiAssistant { _ in
            try self.http(.object(["error": .object(["message": .string("Deadline expired before operation could complete."),
                                                     "code": .string("deadline_exceeded")])]), status: 504)
        }
        do { _ = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("lower Effort"), error.localizedDescription) }
    }

    func testGeminiThatNeverFinishesThinkingSaysSo() async throws {
        var count = 0
        let client = GeminiAssistant { _ in
            count += 1
            return try self.http(.object(["status": .string("incomplete"), "continuation_token": .string("token")]))
        }
        do { _ = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("response limit"), error.localizedDescription) }
        XCTAssertEqual(count, GeminiAssistant.maximumContinuations + 1)
    }

    func testGeminiBadKeyIsClear() async throws {
        let client = GeminiAssistant { _ in
            (Data(#"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8),
             try XCTUnwrap(HTTPURLResponse(url: GeminiAssistant.endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)))
        }
        do { _ = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini); XCTFail("Bad key must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Gemini API key"), error.localizedDescription) }
    }

    func testGeminiUnreadableReplyDetailsShowOnlyItsShape() async throws {
        let secret = "Secret model text"
        let client = GeminiAssistant { _ in
            try self.http(.object(["id": .string("i_1"), "status": .string("completed"),
                                   "outputs": .array([.object(["type": .string("text"), "text": .string(secret)])])]))
        }
        do { _ = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini); XCTFail("A reply without steps must fail") }
        catch let failure as AssistantFailure {
            XCTAssertTrue(failure.message.contains("incomplete response"), failure.message)
            XCTAssertTrue(failure.details.contains { $0.contains("fields: id, outputs, status") }, "\(failure.details)")
            XCTAssertTrue(failure.details.contains("outputs: text."), "\(failure.details)")
            XCTAssertFalse(failure.details.joined().contains(secret), "Details never carry the reply's text")
        }
        XCTAssertEqual(GeminiAssistant.shape(of: Data("<html>".utf8)), ["Reply: 6 bytes, not JSON."])
    }

    /// Google answers a garbled tool call with HTTP 200, status failed, and no steps (seen live with
    /// gemini-3.1-pro-preview, November 15, 2026); the request is sent again.
    func testGeminiRetriesAMalformedToolCall() async throws {
        let malformed: AssistantJSON = .object(["status": .string("failed"), "errors": .array([.object([
            "code": .string("malformed_tool_call"), "message": .string("Model generated invalid JSON syntax.")])])])
        let output: AssistantJSON = .object(["type": .string("model_output"), "content": .array([.object(["type": .string("text"), "text": .string("Done.")])])])
        var requests = 0
        let client = GeminiAssistant { _ in
            requests += 1
            return try self.http(requests == 1 ? malformed : .object(["status": .string("completed"), "steps": .array([output])]))
        }
        let turn = try await run(AssistantEngine(gemini: client, providerKey: { _ in self.fakeKey }), choice: .gemini)
        XCTAssertEqual(turn.reply, "Done.")
        XCTAssertEqual(requests, 2)

        var attempts = 0
        let failing = GeminiAssistant { _ in attempts += 1; return try self.http(malformed) }
        do { _ = try await run(AssistantEngine(gemini: failing, providerKey: { _ in self.fakeKey }), choice: .gemini); XCTFail("Repeated malformed calls must fail") }
        catch let failure as AssistantFailure {
            XCTAssertEqual(attempts, 1 + GeminiAssistant.malformedRetries)
            XCTAssertTrue(failure.message.contains("choose another Gemini model"), failure.message)
            XCTAssertEqual(failure.details, ["Gemini: malformed_tool_call: Model generated invalid JSON syntax."])
        }
    }

    func testGeminiModelListLeavesOutModelsWithoutFunctionCalls() throws {
        let list = #"{"models":[{"name":"models/gemini-omni-1.2-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-4-hydrogen","displayName":"Gemini 4 Hydrogen","supportedGenerationMethods":["generateContent"]}]}"#
        XCTAssertEqual(try ProviderCatalog.parse(.gemini, data: Data(list.utf8)).map(\.id), ["gemini-4-hydrogen"])
    }

    // MARK: Engine, model lists, and settings

    func testProvidersNeedTheirOwnKeyAndNeverFallBack() async throws {
        XCTAssertEqual(AssistantModelChoice.openAI.backend, .openAI)
        XCTAssertEqual(AssistantModelChoice.gemini.backend, .gemini)
        var calls = 0
        let engine = AssistantEngine(openAI: OpenAIAssistant { _ in calls += 1; return try self.http(.null) }, providerKey: { _ in nil })
        do { _ = try await run(engine, choice: .openAI); XCTFail("Missing key must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "Add your OpenAI API key in Settings to use OpenAI.") }
        XCTAssertEqual(calls, 0)
    }

    func testModelListsKeepChatModelsNewestFirst() throws {
        let claude = Data(#"""
        {"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","lifecycle":"active",
          "capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"max":{"supported":true}}}},
         {"id":"claude-old","display_name":"Old","lifecycle":"deprecated"},
         {"id":"claude-plain","display_name":"Plain","lifecycle":"active","capabilities":{"effort":{"supported":false}}}]}
        """#.utf8)
        let claudeModels = try ProviderCatalog.parse(.claude, data: claude)
        XCTAssertEqual(claudeModels.map(\.id), ["claude-opus-5-5", "claude-plain"])
        XCTAssertEqual(claudeModels[0].efforts, ["low", "medium", "high"])
        XCTAssertEqual(claudeModels[1].efforts, [])

        let openAI = Data(#"""
        {"data":[{"id":"gpt-5.5","created":100},{"id":"gpt-6-astra","created":300},{"id":"gpt-6-astra-2026-09-01","created":301},
                 {"id":"text-embedding-3-large","created":400},{"id":"gpt-realtime","created":350},{"id":"o4-mini","created":50},
                 {"id":"tts-1","created":10},{"id":"gpt-6.1-sol","created":320},{"id":"gpt-5.3-codex","created":90},
                 {"id":"chat-latest","created":200},{"id":"gpt-image-2","created":330},{"id":"gpt-live-1","created":340}]}
        """#.utf8)
        let openAIModels = try ProviderCatalog.parse(.openAI, data: openAI)
        XCTAssertEqual(openAIModels.map(\.id), ["gpt-6.1-sol", "gpt-6-astra", "chat-latest", "gpt-5.5", "gpt-5.3-codex", "o4-mini"])
        XCTAssertEqual(openAIModels.map(\.name), ["GPT-6.1 Sol", "GPT-6 Astra", "ChatGPT Latest", "GPT-5.5", "GPT-5.3 Codex", "o4-mini"])

        let gemini = Data(#"""
        {"models":[{"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
                   {"name":"models/gemini-embedding-002","displayName":"Embedding","supportedGenerationMethods":["embedContent"]},
                   {"name":"models/gemini-4-hydrogen","displayName":"Gemini 4 Hydrogen","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-3.6-flash-tts","displayName":"TTS","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/imagen-5","displayName":"Imagen"},
                   {"name":"models/gemini-pro-latest","displayName":"Gemini Pro Latest","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-omni-1.2-flash","displayName":"Omni","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-nano-banana-2.1","displayName":"Nano Banana","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-3.8-live","displayName":"Live","supportedGenerationMethods":["bidiGenerateContent"]}]}
        """#.utf8)
        XCTAssertEqual(try ProviderCatalog.parse(.gemini, data: gemini).map(\.id), ["gemini-4-hydrogen", "gemini-3.8-flash", "gemini-pro-latest"],
                       "Numbered versions newest first, then aliases; no image, Omni, or Live models")
    }

    func testSettingsKeepTheChosenModelAndEffortPerProvider() {
        XCTAssertEqual(ProviderSettings.model(for: .claude).id, "claude-opus-5-5", "The model Claude used before")
        XCTAssertEqual(ProviderSettings.effort(for: .gemini), .high)
        XCTAssertEqual(AssistantModelChoice.claude.title, "Claude Opus 5.5 · High")
        XCTAssertEqual(AssistantBackend.openAI.shortTitle, "OpenAI · High")

        ProviderSettings.setModel(ProviderModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"), for: .gemini)
        ProviderSettings.storeModels([ProviderModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash (new)"), ProviderModel(id: "gemini-x", name: "X")], for: .gemini)
        XCTAssertEqual(ProviderSettings.model(for: .gemini).name, "Gemini 3.8 Flash (new)", "Details follow the fresh list")
        ProviderSettings.storeModels([ProviderModel(id: "gemini-y", name: "Y"), ProviderModel(id: "gemini-z", name: "Z")], for: .gemini)
        XCTAssertEqual(ProviderSettings.model(for: .gemini).id, "gemini-y", "A model no longer offered gives way to the first")
        XCTAssertEqual(ProviderSettings.models(for: .gemini).map(\.id), ["gemini-y", "gemini-z"])

        ProviderSettings.setModel(ProviderModel(id: "claude-plain", name: "Plain", efforts: []), for: .claude)
        XCTAssertNil(ProviderSettings.effortValue(for: .claude), "A model without effort uses its default")
        ProviderSettings.setModel(ProviderModel(id: "claude-lmh", name: "LMH", efforts: ["low", "medium", "high"]), for: .claude)
        ProviderSettings.setEffort(.low, for: .claude)
        XCTAssertEqual(ProviderSettings.effortValue(for: .claude), "low")
        XCTAssertEqual(AssistantModelChoice.claude.title, "LMH · Low")
    }

    func testClaudeSendsTheChosenModelAndEffort() async throws {
        ProviderSettings.setModel(ProviderModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"), for: .claude)
        ProviderSettings.setEffort(.low, for: .claude)
        var body: AssistantJSON = .null
        let client = ClaudeAssistant { request in
            body = try self.payload(request)
            return try self.http(.object(["role": .string("assistant"), "stop_reason": .string("end_turn"),
                                          "content": .array([.object(["type": .string("text"), "text": .string("It is 20 mm tall.")])])]))
        }
        let engine = AssistantEngine(claude: client, claudeKey: { self.fakeKey })
        _ = try await engine.respond(to: "How tall is it?", workspace: ClaudeAssistantTests.fixture("block"), selection: nil, choice: .claude,
                                     onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(body["model"]?.string, "claude-sonnet-5-5")
        XCTAssertEqual(body["output_config"]?["effort"]?.string, "low")
    }
}
