import Foundation

/// Gemini through Google's Interactions API with the user's Gemini API key: the same CAD tools and
/// workbench as Claude. Requests are stateless (`store: false`): the steps the model returned,
/// signed thoughts included, go back with the function results.
@MainActor final class GeminiAssistant {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private let transport: ProviderHTTP.Transport
    /// Whole completed exchanges only, so a function call is never sent without its thought.
    private var exchanges: [[AssistantJSON]] = []
    static let keptExchanges = 4
    /// Models that refused a thinking level; they run at their own default from then on.
    private var noEffort: Set<String> = []

    init(transport: ProviderHTTP.Transport? = nil) {
        self.transport = transport ?? ProviderHTTP.defaultTransport(.gemini)
    }

    func reset() { exchanges = [] }

    func respond(prompt: String, key: String, context: AssistantContext, model: String, effort: String?,
                 onText: (String) -> Void) async throws -> String {
        let tools = context.allTools
        let definitions: [AssistantJSON] = try tools.map { tool in
            .object(["type": .string("function"), "name": .string(tool.name), "description": .string(tool.description),
                     "parameters": try AssistantToolBridge.schema(tool)])
        }
        var exchange: [AssistantJSON] = [.object(["type": .string("user_input"),
                                                  "content": .array([.object(["type": .string("text"), "text": .string(prompt)])])])]
        var calls = 0
        var wrappingUp = false
        for _ in 0...AssistantContext.maximumCalls + 1 {
            try Task.checkCancellation()
            var configuration: [String: AssistantJSON] = ["tool_choice": .string(wrappingUp ? "none" : "auto"),
                                                          "max_output_tokens": .number(16384)]
            let sendsEffort = effort != nil && !noEffort.contains(model)
            if sendsEffort, let effort { configuration["thinking_level"] = .string(effort) }
            var fields: [String: AssistantJSON] = [
                "model": .string(model), "system_instruction": .string(AssistantPrompt.instructions),
                "input": .array(exchanges.flatMap { $0 } + exchange), "tools": .array(definitions),
                "generation_config": .object(configuration), "store": .bool(false)
            ]
            var request = URLRequest(url: Self.endpoint)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            try ProviderHTTP.json(&request, .object(fields))
            let data: Data
            do {
                var (received, response) = try await ProviderHTTP.send(request, with: transport)
                // A model that takes no thinking level (or not this one) is asked again without it.
                if response.statusCode == 400, sendsEffort, String(decoding: received, as: UTF8.self).contains("thinking") {
                    noEffort.insert(model)
                    configuration["thinking_level"] = nil
                    fields["generation_config"] = .object(configuration)
                    try ProviderHTTP.json(&request, .object(fields))
                    (received, response) = try await ProviderHTTP.send(request, with: transport)
                }
                try Task.checkCancellation()
                try Self.checkStatus(response.statusCode, data: received, model: model)
                data = received
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as AssistantFailure { throw error }
            catch { throw AssistantFailure(message: "Gemini could not be reached. Check your internet connection and try again.", kind: .service) }

            guard let response = try? JSONDecoder().decode(AssistantJSON.self, from: data), let steps = response["steps"]?.array else {
                throw AssistantFailure(message: "Gemini returned an incomplete response. Try again.", kind: .service)
            }
            switch response["status"]?.string ?? "completed" {
            case "completed", "requires_action": break
            case "incomplete": throw AssistantFailure(message: "Gemini reached its response limit. Start a new conversation or ask for fewer changes.")
            case "failed":
                let text = (response["errors"]?.array ?? []).compactMap { $0["message"]?.string }.joined(separator: " ").lowercased()
                if text.contains("safety") || text.contains("blocked") { throw AssistantFailure(message: "Gemini declined this request.", kind: .refusal) }
                throw AssistantFailure(message: "Gemini could not complete this request. Try again, or ask for fewer changes.", kind: .service)
            default: throw AssistantFailure(message: "Gemini stopped before completing this request. Try a smaller request.")
            }
            let toolCalls = steps.filter { $0["type"]?.string == "function_call" }
            // Every step goes back as it came, in order, signed thoughts included.
            exchange += steps
            if toolCalls.isEmpty {
                let reply = steps.filter { $0["type"]?.string == "model_output" }.flatMap { $0["content"]?.array ?? [] }
                    .filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty || context.bench.hasChanges else { throw AssistantFailure(message: "Gemini returned no answer. Try again.") }
                exchanges.append(exchange)
                if exchanges.count > Self.keptExchanges { exchanges = Array(exchanges.suffix(Self.keptExchanges)) }
                onText(reply)
                return reply
            }
            guard !wrappingUp else { throw AssistantFailure(message: "Gemini reached the CAD tool limit. Ask for fewer changes at a time.") }
            var ids = Set<String>()
            guard toolCalls.allSatisfy({ call in
                guard let id = call["id"]?.string, !id.isEmpty, call["name"]?.string != nil else { return false }
                return ids.insert(id).inserted
            }) else { throw AssistantFailure(message: "Gemini returned incomplete tool instructions. Try again.") }
            func result(_ call: AssistantJSON, _ text: String) -> AssistantJSON {
                .object(["type": .string("function_result"), "call_id": .string(call["id"]!.string!), "name": .string(call["name"]!.string!),
                         "result": .string(text), "is_error": .bool(text.hasPrefix("Error:"))])
            }
            if calls + toolCalls.count > AssistantContext.maximumCalls {
                // None of this batch runs; the reply says what the earlier calls did.
                wrappingUp = true
                exchange += toolCalls.map { result($0, "Error: The CAD tool limit for this request is reached, so this was not done. Tell the user what was done and what is left.") }
                continue
            }
            context.beginRound()
            for call in toolCalls {
                try Task.checkCancellation()
                calls += 1
                // Arguments come as an object (a streamed call's text form is not used here).
                var arguments = call["arguments"]
                if let text = arguments?.string { arguments = try? JSONDecoder().decode(AssistantJSON.self, from: Data(text.utf8)) }
                let text = try await AssistantToolBridge.run(call["name"]!.string!, arguments: arguments, tools: tools)
                try Task.checkCancellation()
                exchange.append(result(call, text))
            }
        }
        throw AssistantFailure(message: "Gemini reached the request limit. Ask for fewer changes at a time.")
    }

    private static func checkStatus(_ status: Int, data: Data, model: String) throws {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        switch status {
        case 200..<300: return
        // Google answers a bad key with 400 (API_KEY_INVALID) as well as 401 or 403.
        case 400 where text.contains("API_KEY_INVALID") || text.contains("API key not valid"), 401:
            throw AssistantFailure(message: "Google rejected the Gemini API key. Replace it in Settings.")
        case 403: throw AssistantFailure(message: "This Gemini API key can't use \(model). Check the key's project in Google AI Studio.")
        case 404: throw AssistantFailure(message: "\(model) is not available to this API key. Choose another model in Settings.")
        case 429: throw AssistantFailure(message: "Your Gemini API quota or rate limit was reached. Check your Google AI Studio plan and try again later.", kind: .service)
        case 500...599: throw AssistantFailure(message: "Gemini is temporarily unavailable. Try again later.", kind: .service)
        default: throw AssistantFailure(message: "Gemini could not process this request. Start a new conversation or ask for fewer changes.")
        }
    }
}
