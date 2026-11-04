import Foundation
import FoundationModels

/// Preserve every response block (including signed thinking and future block types) in tool loops.
enum ClaudeJSON: Codable, Equatable, Sendable {
    case object([String: ClaudeJSON]), array([ClaudeJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let n = try? value.decode(Double.self) { self = .number(n) }
        else if let s = try? value.decode(String.self) { self = .string(s) }
        else if let a = try? value.decode([ClaudeJSON].self) { self = .array(a) }
        else { self = .object(try value.decode([String: ClaudeJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> ClaudeJSON? { if case .object(let v) = self { v[key] } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [ClaudeJSON]? { if case .array(let v) = self { v } else { nil } }
}

/// Both providers expose the same typed tools and call the same workbench validation.
@MainActor enum ClaudeToolBridge {
    static func definition(_ tool: any Tool) throws -> ClaudeJSON {
        let schema = try JSONDecoder().decode(ClaudeJSON.self, from: JSONEncoder().encode(tool.parameters))
        return .object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": schema])
    }

    static func call<T: Tool>(_ tool: T, input: ClaudeJSON) async throws -> String {
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let arguments = try T.Arguments(GeneratedContent(json: json))
        let result = try await tool.call(arguments: arguments)
        guard let text = result as? String else { throw AssistantFailure(message: "This CAD tool returned an unsupported result.") }
        return text
    }
}

@MainActor final class ClaudeAssistant {
    static let model = "claude-opus-5-5"
    static let effort = "high"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    /// Whole completed exchanges only, so pruning never leaves unmatched tool results or thinking.
    private var exchanges: [[ClaudeJSON]] = []
    static let keptExchanges = 4

    init(transport: Transport? = nil) {
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw AssistantFailure(message: "Claude returned an invalid response.", kind: .service) }
                return (data, http)
            }
        }
    }

    func reset() { exchanges = [] }

    /// An assistant message without its thinking blocks (one left empty says it is done).
    static func withoutThinking(_ message: ClaudeJSON) -> ClaudeJSON {
        guard case .object(var fields) = message, fields["role"]?.string == "assistant",
              let content = fields["content"]?.array else { return message }
        let kept = content.filter { !["thinking", "redacted_thinking"].contains($0["type"]?.string ?? "") }
        fields["content"] = .array(kept.isEmpty ? [.object(["type": .string("text"), "text": .string("Done.")])] : kept)
        return .object(fields)
    }

    func respond(prompt: String, key: String, context: AssistantContext, onText: (String) -> Void) async throws -> String {
        let tools = context.allTools
        let definitions = try tools.map { try ClaudeToolBridge.definition($0) }
        var exchange: [ClaudeJSON] = [.object(["role": .string("user"), "content": .string(prompt)])]
        var calls = 0
        // Past the tool limit, Claude is asked once more, with tools off, to say what it did.
        var wrappingUp = false
        for _ in 0...AssistantContext.maximumCalls + 1 {
            try Task.checkCancellation()
            let body: ClaudeJSON = .object([
                "model": .string(Self.model), "max_tokens": .number(16384),
                "output_config": .object(["effort": .string(Self.effort)]),
                "system": .string(AssistantPrompt.instructions), "stream": .bool(false),
                "tools": .array(definitions), "tool_choice": .object(["type": .string(wrappingUp ? "none" : "auto")]),
                "messages": .array(exchanges.flatMap { $0 } + exchange)
            ])
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 240
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(body)
            let data: Data
            do {
                let (received, response) = try await send(request)
                try Task.checkCancellation()
                try Self.checkStatus(response.statusCode)
                data = received
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as AssistantFailure { throw error }
            catch { throw AssistantFailure(message: "Claude could not be reached. Check your internet connection and try again.", kind: .service) }

            guard let response = try? JSONDecoder().decode(ClaudeJSON.self, from: data),
                  response["role"]?.string == "assistant", let content = response["content"]?.array,
                  let reason = response["stop_reason"]?.string else {
                throw AssistantFailure(message: "Claude returned an incomplete response. Try again.", kind: .service)
            }
            // Refusals are also represented by stop_details on newer API versions.
            if reason == "refusal" || response["stop_details"]?["type"]?.string == "refusal" {
                throw AssistantFailure(message: "Claude declined this request.", kind: .refusal)
            }
            guard reason == "tool_use" || reason == "end_turn" else {
                throw AssistantFailure(message: reason == "max_tokens"
                    ? "Claude reached its response limit. Start a new conversation or ask for fewer changes."
                    : "Claude stopped before completing this request. Try a smaller request.")
            }
            let toolCalls = content.filter { $0["type"]?.string == "tool_use" }
            guard (reason == "tool_use") == !toolCalls.isEmpty else {
                throw AssistantFailure(message: "Claude returned inconsistent tool instructions. Try again.")
            }
            // Echo the entire content array, preserving signed thinking blocks and their order.
            exchange.append(.object(["role": .string("assistant"), "content": .array(content)]))
            if reason == "end_turn" {
                let reply = content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty || context.bench.hasChanges else { throw AssistantFailure(message: "Claude returned no answer. Try again.") }
                exchanges.append(exchange)
                if exchanges.count > Self.keptExchanges {
                    // Dropping the oldest exchanges edits the history, and signed thinking is bound to
                    // everything before it, so the API refuses thinking in exchanges kept after a cut.
                    // They keep their text and tool calls.
                    exchanges = exchanges.suffix(Self.keptExchanges).map { $0.map(Self.withoutThinking) }
                }
                onText(reply)
                return reply
            }
            guard !wrappingUp else {
                throw AssistantFailure(message: "Claude reached the CAD tool limit. Ask for fewer changes at a time.")
            }
            var ids = Set<String>()
            guard toolCalls.allSatisfy({ call in
                guard let id = call["id"]?.string, !id.isEmpty, call["name"]?.string != nil,
                      case .object = call["input"] else { return false }
                return ids.insert(id).inserted
            }) else { throw AssistantFailure(message: "Claude returned incomplete tool instructions. Try again.") }
            var results: [ClaudeJSON] = []
            if calls + toolCalls.count > AssistantContext.maximumCalls {
                // None of this batch runs; the reply says what the earlier calls did.
                wrappingUp = true
                results = toolCalls.map { call in
                    .object(["type": .string("tool_result"), "tool_use_id": .string(call["id"]!.string!), "is_error": .bool(true),
                             "content": .string("Error: The CAD tool limit for this request is reached, so this was not done. Tell the user what was done and what is left.")])
                }
                exchange.append(.object(["role": .string("user"), "content": .array(results)]))
                continue
            }
            context.beginRound()
            for call in toolCalls {
                try Task.checkCancellation()
                calls += 1
                let name = call["name"]!.string!, id = call["id"]!.string!
                let result: String
                if let tool = tools.first(where: { $0.name == name }) {
                    do { result = try await ClaudeToolBridge.call(tool, input: call["input"]!) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result = "Error: Invalid arguments for \(name). Use its declared parameters and valid CAD dimensions." }
                } else { result = "Error: Unknown CAD tool. Use one of the supplied tools." }
                try Task.checkCancellation()
                results.append(.object(["type": .string("tool_result"), "tool_use_id": .string(id),
                                        "content": .string(result), "is_error": .bool(result.hasPrefix("Error:"))]))
            }
            exchange.append(.object(["role": .string("user"), "content": .array(results)]))
        }
        throw AssistantFailure(message: "Claude reached the request limit. Ask for fewer changes at a time.")
    }

    /// Rate limits (429) and a busy or overloaded service (503, 529) are tried again a few times,
    /// after the wait the service asks for (at most 20 seconds) or 2, 4, then 8 seconds.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await transport(request)
            guard [429, 503, 529].contains(response.statusCode), attempt < Self.retries else { return (data, response) }
            attempt += 1
            let asked = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            try await Task.sleep(for: .seconds(min(max(asked ?? pow(2, Double(attempt)), 0), 20)))
        }
    }
    static let retries = 3

    private static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw AssistantFailure(message: "Claude rejected the API key. Replace it in Settings.")
        case 402: throw AssistantFailure(message: "Your Claude API account needs credits. Check your Anthropic billing.")
        case 403, 404: throw AssistantFailure(message: "Claude Opus 5.5 is not available to this API key. Check your Anthropic account's model access.")
        case 429: throw AssistantFailure(message: "Your Claude API rate or spending limit was reached. Check your Anthropic account and try again later.", kind: .service)
        case 500...599: throw AssistantFailure(message: "Claude is temporarily unavailable. Try again later.", kind: .service)
        default: throw AssistantFailure(message: "Claude could not process this request. Start a new conversation or ask for fewer changes.")
        }
    }
}
