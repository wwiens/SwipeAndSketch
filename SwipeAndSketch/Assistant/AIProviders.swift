import Foundation
import FoundationModels

// The API providers the assistant can use with the user's own key (November 13, 2026: Claude, then
// OpenAI and Gemini): each with a model chosen from the ones the key can use and an effort level,
// all calling the same CAD tools through the same workbench. A choice is explicit: there is no
// fallback from one provider to another.

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, openAI = "openai", gemini
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: "Claude"; case .openAI: "OpenAI"; case .gemini: "Gemini" }
    }
    /// Who receives requests and bills for them.
    var company: String {
        switch self { case .claude: "Anthropic"; case .openAI: "OpenAI"; case .gemini: "Google" }
    }
    var credentials: APICredentials {
        switch self { case .claude: .shared; case .openAI: .openAI; case .gemini: .gemini }
    }
    var choice: AssistantModelChoice {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini }
    }
    var backend: AssistantBackend {
        switch self { case .claude: .claude; case .openAI: .openAI; case .gemini: .gemini }
    }
    /// Where to make a key.
    var keyPage: URL {
        switch self {
        case .claude: URL(string: "https://platform.claude.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
    /// What is sent, to whom, and who pays (Settings and the panel say it before a request is sent).
    var dataNote: String {
        let base = "Your key is stored in this device's Keychain. When you select \(title) and send a request, your request, conversation, model summary, and CAD tool results are sent directly to \(company)."
        switch self {
        case .claude: return base + " Anthropic bills API usage to your account; a Claude subscription does not cover API usage."
        case .openAI: return base + " OpenAI bills API usage to your account; a ChatGPT subscription does not cover API usage."
        case .gemini: return base + " Google bills API usage to your account. On Google's free tier, Google may use what is sent to improve its products; see the Gemini API terms."
        }
    }
    /// The model a provider starts with, before its list is read.
    var defaultModel: ProviderModel { builtInModels[0] }
    /// Used until the key's own list is read, and whenever it can't be.
    var builtInModels: [ProviderModel] {
        switch self {
        case .claude: [ProviderModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"), ProviderModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
                       ProviderModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")]
        case .openAI: [ProviderModel(id: "gpt-6-astra", name: "GPT-6 Astra"), ProviderModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
                       ProviderModel(id: "gpt-6-luna", name: "GPT-6 Luna")]
        case .gemini: [ProviderModel(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen"), ProviderModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
                       ProviderModel(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro Preview")]
        }
    }
}

/// How hard the model works on a request: higher is slower and costs more, and suits bigger changes.
enum AssistantEffort: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ProviderModel: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// The effort levels the provider says the model takes, or nil when it does not say.
    var efforts: [String]? = nil
}

/// Each provider's chosen model, effort, and last model list (app preferences; keys stay in Keychain).
enum ProviderSettings {
    private static func key(_ provider: AIProvider, _ name: String) -> String { "assistant.\(provider.rawValue).\(name)" }

    static func model(for provider: AIProvider) -> ProviderModel {
        guard let data = UserDefaults.standard.data(forKey: key(provider, "model")),
              let model = try? JSONDecoder().decode(ProviderModel.self, from: data), !model.id.isEmpty else { return provider.defaultModel }
        return model
    }
    static func setModel(_ model: ProviderModel, for provider: AIProvider) {
        UserDefaults.standard.set(try? JSONEncoder().encode(model), forKey: key(provider, "model"))
    }

    static func effort(for provider: AIProvider) -> AssistantEffort {
        UserDefaults.standard.string(forKey: key(provider, "effort")).flatMap(AssistantEffort.init) ?? .high
    }
    static func setEffort(_ effort: AssistantEffort, for provider: AIProvider) {
        UserDefaults.standard.set(effort.rawValue, forKey: key(provider, "effort"))
    }

    /// The effort to send: none when the model is known not to take the chosen level (its default applies).
    static func effortValue(for provider: AIProvider) -> String? {
        let effort = effort(for: provider).rawValue
        guard let efforts = model(for: provider).efforts else { return effort }
        return efforts.contains(effort) ? effort : nil
    }

    /// The key's models as last read, or the built-in list.
    static func models(for provider: AIProvider) -> [ProviderModel] {
        guard let data = UserDefaults.standard.data(forKey: key(provider, "models")),
              let models = try? JSONDecoder().decode([ProviderModel].self, from: data), !models.isEmpty else { return provider.builtInModels }
        return models
    }
    /// Remembers a freshly read list, and keeps the chosen model's details current (or picks the
    /// first model when the chosen one is no longer offered).
    static func storeModels(_ models: [ProviderModel], for provider: AIProvider) {
        guard !models.isEmpty else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(models), forKey: key(provider, "models"))
        let chosen = model(for: provider)
        if let current = models.first(where: { $0.id == chosen.id }) {
            if current != chosen { setModel(current, for: provider) }
        } else {
            setModel(models.first(where: { $0.id == provider.defaultModel.id }) ?? models[0], for: provider)
        }
    }
}

/// HTTP for the providers: an ephemeral session, waits and retries for busy services, and a
/// provider's own error text (kept out of the user's message; it can echo request details).
@MainActor enum ProviderHTTP {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func defaultTransport(_ provider: AIProvider) -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AssistantFailure(message: "\(provider.title) returned an invalid response.", kind: .service) }
            return (data, http)
        }
    }

    /// Rate limits (429) and a busy or overloaded service (503, 529) are tried again a few times,
    /// after the wait the service asks for (at most 20 seconds) or 2, 4, then 8 seconds. Running out
    /// of credit is not retried.
    static func send(_ request: URLRequest, with transport: Transport, retries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await transport(request)
            guard [429, 503, 529].contains(response.statusCode), attempt < retries, !isQuota(data) else { return (data, response) }
            attempt += 1
            let asked = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            try await Task.sleep(for: .seconds(min(max(asked ?? pow(2, Double(attempt)), 0), 20)))
        }
    }

    /// The account is out of credit or over its spending limit (OpenAI's insufficient_quota).
    static func isQuota(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        return text.contains("insufficient_quota") || text.contains("billing")
    }

    static func json(_ request: inout URLRequest, _ body: AssistantJSON) throws {
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sorted keys: a cached prefix must be byte for byte the same from one request to the next.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
    }
}

/// Reads which models a key can use, newest first, keeping the ones that can hold a conversation
/// and call tools (not embeddings, speech, images, or search-only models).
@MainActor enum ProviderCatalog {
    static func request(for provider: AIProvider, key: String) -> URLRequest {
        var request: URLRequest
        switch provider {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func fetch(_ provider: AIProvider, key: String, transport: ProviderHTTP.Transport? = nil) async throws -> [ProviderModel] {
        let (data, response) = try await ProviderHTTP.send(request(for: provider, key: key), with: transport ?? ProviderHTTP.defaultTransport(provider), retries: 1)
        switch response.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw AssistantFailure(message: "\(provider.company) did not accept this API key. Check it and save it again.")
        default: throw AssistantFailure(message: "\(provider.company) could not list models right now. The last list is kept.", kind: .service)
        }
        let models = try parse(provider, data: data)
        guard !models.isEmpty else { throw AssistantFailure(message: "\(provider.company) listed no models this key can use for the assistant.") }
        return models
    }

    static func parse(_ provider: AIProvider, data: Data) throws -> [ProviderModel] {
        guard let json = try? JSONDecoder().decode(AssistantJSON.self, from: data) else {
            throw AssistantFailure(message: "\(provider.company) returned an unreadable model list.", kind: .service)
        }
        switch provider {
        case .claude:
            // Newest first already; deprecated models stay callable for a while but are on their way out.
            return (json["data"]?.array ?? []).compactMap { model in
                guard let id = model["id"]?.string, (model["lifecycle"]?.string ?? "active") == "active" else { return nil }
                var efforts: [String]?
                if let effort = model["capabilities"]?["effort"] {
                    efforts = effort["supported"]?.bool == false ? []
                        : AssistantEffort.allCases.map(\.rawValue).filter { effort[$0]?["supported"]?.bool == true }
                }
                return ProviderModel(id: id, name: model["display_name"]?.string ?? id, efforts: efforts)
            }
        case .openAI:
            let models = (json["data"]?.array ?? []).compactMap { model -> (ProviderModel, Double)? in
                guard let id = model["id"]?.string, isOpenAIChatModel(id) else { return nil }
                return (ProviderModel(id: id, name: openAIName(id)), model["created"]?.number ?? 0)
            }
            return models.sorted { $0.1 > $1.1 }.map(\.0)
        case .gemini:
            let models = (json["models"]?.array ?? []).compactMap { model -> ProviderModel? in
                guard let name = model["name"]?.string, name.hasPrefix("models/gemini") else { return nil }
                let id = String(name.dropFirst("models/".count))
                guard !excluded(id) else { return nil }
                let methods = (model["supportedGenerationMethods"] ?? model["supportedActions"])?.array?.compactMap(\.string)
                if let methods, !methods.contains("generateContent") { return nil }
                return ProviderModel(id: id, name: model["displayName"]?.string ?? id)
            }
            return models.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
        }
    }

    /// Models for speech, images, embeddings, moderation, search, or code completion only.
    private static let excludedTerms = ["embed", "tts", "audio", "realtime", "transcribe", "image", "vision", "search",
                                        "moderation", "live", "robotics", "aqa", "computer-use", "whisper", "dall-e",
                                        "sora", "codex", "instruct", "babbage", "davinci", "deep-research", "gpt-3.5"]
    private static func excluded(_ id: String) -> Bool { excludedTerms.contains { id.contains($0) } }

    /// GPT and o-series chat models, without dated snapshots (the undated name follows the latest).
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let family = id.hasPrefix("gpt-") || (id.first == "o" && id.dropFirst().first?.isNumber == true)
        let dated = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        return family && !dated && !excluded(id)
    }

    /// "gpt-6.1-sol" reads "GPT-6.1 Sol"; o-series names stay as they are.
    static func openAIName(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        let parts = id.dropFirst(4).split(separator: "-").map(String.init)
        guard let version = parts.first else { return id }
        return (["GPT-" + version] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}

/// The CAD tools as each provider describes a function, and running one from a model's arguments.
@MainActor enum AssistantToolBridge {
    static func schema(_ tool: any Tool) throws -> AssistantJSON {
        try JSONDecoder().decode(AssistantJSON.self, from: JSONEncoder().encode(tool.parameters))
    }

    /// Arguments arrive as an object (Claude, Gemini) or as JSON text (OpenAI).
    static func call(_ tool: any Tool, arguments: AssistantJSON) async throws -> String {
        try await ClaudeToolBridge.call(tool, input: arguments)
    }

    /// Runs one call by name, turning bad arguments or an unknown name into an error the model can fix.
    static func run(_ name: String, arguments: AssistantJSON?, tools: [any Tool]) async throws -> String {
        guard let tool = tools.first(where: { $0.name == name }) else { return "Error: Unknown CAD tool. Use one of the supplied tools." }
        guard let arguments, case .object = arguments else {
            return "Error: Invalid arguments for \(name). Use its declared parameters and valid CAD dimensions."
        }
        do { return try await call(tool, arguments: arguments) }
        catch is CancellationError { throw CancellationError() }
        catch { return "Error: Invalid arguments for \(name). Use its declared parameters and valid CAD dimensions." }
    }
}
