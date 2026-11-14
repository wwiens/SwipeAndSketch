import Foundation

/// OpenAI through the Responses API with the user's key: the same CAD tools and workbench as Claude.
/// Requests are stateless (`store: false`): every output item, including encrypted reasoning, goes
/// back with the tool results, so nothing about the conversation is kept by OpenAI between requests.
@MainActor final class OpenAIAssistant {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let transport: ProviderHTTP.Transport
    /// Whole completed exchanges only: a function call can't be sent without its reasoning item.
    private var exchanges: [[AssistantJSON]] = []
    static let keptExchanges = 4
    /// Models that refused an effort setting; they run at their own default from then on.
    private var noEffort: Set<String> = []

    init(transport: ProviderHTTP.Transport? = nil) {
        self.transport = transport ?? ProviderHTTP.defaultTransport(.openAI)
    }

    func reset() { exchanges = [] }

    func respond(prompt: String, key: String, context: AssistantContext, model: String, effort: String?,
                 onText: (String) -> Void) async throws -> String {
        let tools = context.allTools
        let definitions: [AssistantJSON] = try tools.map { tool in
            .object(["type": .string("function"), "name": .string(tool.name), "description": .string(tool.description),
                     "parameters": try AssistantToolBridge.schema(tool), "strict": .bool(false)])
        }
        var exchange: [AssistantJSON] = [.object(["role": .string("user"), "content": .string(prompt)])]
        var calls = 0
        var wrappingUp = false
        for _ in 0...AssistantContext.maximumCalls + 1 {
            try Task.checkCancellation()
            var fields: [String: AssistantJSON] = [
                "model": .string(model), "instructions": .string(AssistantPrompt.instructions),
                "input": .array(exchanges.flatMap { $0 } + exchange), "store": .bool(false),
                "tools": .array(definitions), "tool_choice": .string(wrappingUp ? "none" : "auto"),
                "max_output_tokens": .number(16384)
            ]
            let sendsEffort = effort != nil && !noEffort.contains(model)
            if sendsEffort, let effort { fields["reasoning"] = .object(["effort": .string(effort)]) }
            var request = URLRequest(url: Self.endpoint)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            try ProviderHTTP.json(&request, .object(fields))
            let data: Data
            do {
                var (received, response) = try await ProviderHTTP.send(request, with: transport)
                // A model that takes no reasoning setting (or not this level) is asked again without it.
                if response.statusCode == 400, sendsEffort, String(decoding: received, as: UTF8.self).contains("reasoning") {
                    noEffort.insert(model)
                    fields["reasoning"] = nil
                    try ProviderHTTP.json(&request, .object(fields))
                    (received, response) = try await ProviderHTTP.send(request, with: transport)
                }
                try Task.checkCancellation()
                try Self.checkStatus(response.statusCode, data: received, model: model)
                data = received
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as AssistantFailure { throw error }
            catch { throw AssistantFailure(message: "OpenAI could not be reached. Check your internet connection and try again.", kind: .service) }

            guard let response = try? JSONDecoder().decode(AssistantJSON.self, from: data), let output = response["output"]?.array else {
                throw AssistantFailure(message: "OpenAI returned an incomplete response. Try again.", kind: .service)
            }
            let status = response["status"]?.string ?? "completed"
            if status == "incomplete" {
                let reason = response["incomplete_details"]?["reason"]?.string
                throw AssistantFailure(message: reason == "content_filter" ? "OpenAI declined this request."
                    : "OpenAI reached its response limit. Start a new conversation or ask for fewer changes.",
                    kind: reason == "content_filter" ? .refusal : .execution)
            }
            guard status == "completed" else { throw AssistantFailure(message: "OpenAI stopped before completing this request. Try a smaller request.") }
            let messages = output.filter { $0["type"]?.string == "message" }.flatMap { $0["content"]?.array ?? [] }
            if messages.contains(where: { $0["type"]?.string == "refusal" }) {
                throw AssistantFailure(message: "OpenAI declined this request.", kind: .refusal)
            }
            let toolCalls = output.filter { $0["type"]?.string == "function_call" }
            // Every item goes back as it came, in order, reasoning included.
            exchange += output
            if toolCalls.isEmpty {
                let reply = messages.filter { $0["type"]?.string == "output_text" }.compactMap { $0["text"]?.string }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty || context.bench.hasChanges else { throw AssistantFailure(message: "OpenAI returned no answer. Try again.") }
                exchanges.append(exchange)
                if exchanges.count > Self.keptExchanges { exchanges = Array(exchanges.suffix(Self.keptExchanges)) }
                onText(reply)
                return reply
            }
            guard !wrappingUp else { throw AssistantFailure(message: "OpenAI reached the CAD tool limit. Ask for fewer changes at a time.") }
            var ids = Set<String>()
            guard toolCalls.allSatisfy({ call in
                guard let id = call["call_id"]?.string, !id.isEmpty, call["name"]?.string != nil else { return false }
                return ids.insert(id).inserted
            }) else { throw AssistantFailure(message: "OpenAI returned incomplete tool instructions. Try again.") }
            if calls + toolCalls.count > AssistantContext.maximumCalls {
                // None of this batch runs; the reply says what the earlier calls did.
                wrappingUp = true
                exchange += toolCalls.map { call in
                    .object(["type": .string("function_call_output"), "call_id": .string(call["call_id"]!.string!),
                             "output": .string("Error: The CAD tool limit for this request is reached, so this was not done. Tell the user what was done and what is left.")])
                }
                continue
            }
            context.beginRound()
            for call in toolCalls {
                try Task.checkCancellation()
                calls += 1
                // Arguments come as JSON text.
                let arguments = call["arguments"]?.string.flatMap { try? JSONDecoder().decode(AssistantJSON.self, from: Data($0.utf8)) }
                let result = try await AssistantToolBridge.run(call["name"]!.string!, arguments: arguments, tools: tools)
                try Task.checkCancellation()
                exchange.append(.object(["type": .string("function_call_output"), "call_id": .string(call["call_id"]!.string!),
                                         "output": .string(result)]))
            }
        }
        throw AssistantFailure(message: "OpenAI reached the request limit. Ask for fewer changes at a time.")
    }

    private static func checkStatus(_ status: Int, data: Data, model: String) throws {
        switch status {
        case 200..<300: return
        case 401: throw AssistantFailure(message: "OpenAI rejected the API key. Replace it in Settings.")
        case 403, 404: throw AssistantFailure(message: "\(model) is not available to this API key. Choose another model in Settings, or check your OpenAI project's model access.")
        case 429 where ProviderHTTP.isQuota(data): throw AssistantFailure(message: "Your OpenAI API account needs credits or has reached its spending limit. Check your OpenAI billing.")
        case 429: throw AssistantFailure(message: "Your OpenAI API rate limit was reached. Try again later.", kind: .service)
        case 500...599: throw AssistantFailure(message: "OpenAI is temporarily unavailable. Try again later.", kind: .service)
        default: throw AssistantFailure(message: "OpenAI could not process this request. Start a new conversation or ask for fewer changes.")
        }
    }
}
