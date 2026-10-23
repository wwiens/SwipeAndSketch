import Foundation
import FoundationModels

// Evaluates assistant requests on this Mac's on-device model. Each request runs on its own copy of
// the scenario; consecutive requests in one run share the conversation (like the app's panel).

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--entitlements", arguments.count > 1 {
    // Checks the code-signature parser against a built app's executable.
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let entitlements = PrivateCloudEntitlement.entitlements(inExecutable: data)
    print("entitlements: \(entitlements?.keys.sorted() ?? []); cloud: \(entitlements?[PrivateCloudEntitlement.key] as? Bool == true)")
    exit(0)
}
var scenario = "empty"
var showTokens = false
var choice = AssistantModelChoice.onDevice
if let index = arguments.firstIndex(of: "--scenario"), index + 1 < arguments.count {
    scenario = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
if let index = arguments.firstIndex(of: "--tokens") { showTokens = true; arguments.remove(at: index) }
if let index = arguments.firstIndex(of: "--cloud") { choice = .cloud; arguments.remove(at: index) }
let carry = arguments.contains("--carry")
arguments.removeAll { $0 == "--carry" }

func scenarioWorkspace(_ name: String) throws -> Workspace {
    var bench = AssistantWorkbench(workspace: Workspace())
    switch name {
    case "box":
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: 20, mode: .auto, throughAll: false)
    case "plate":
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 80, height: 50)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: 5, mode: .auto, throughAll: false)
        try bench.addShapes([.init(kind: .circle, point: [0, 0, 0], diameter: 20)], on: .world(.top))
    case "two":
        try bench.addShapes([.init(kind: .rectangle, point: .zero, width: 60, height: 40)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 01", regions: [], distance: 20, mode: .auto, throughAll: false)
        try bench.addShapes([.init(kind: .circle, point: [30, 0, 0], diameter: 16)], on: .world(.top))
        try bench.extrude(sketch: "Sketch 02", regions: [], distance: 30, mode: .newBody, throughAll: false)
    default: break
    }
    return bench.workspace
}

let engine = AssistantEngine()
if let index = arguments.firstIndex(of: "--full") { AssistantEngine.onDeviceFull = true; arguments.remove(at: index) }
if let index = arguments.firstIndex(of: "--tools") { AssistantEngine.onDevicePlans = false; arguments.remove(at: index) }
if arguments.contains("--verbose") {
    arguments.removeAll { $0 == "--verbose" }
    engine.context.onResult = { print("      ↳ \($0.prefix(300))") }
}
if showTokens {
    let model = SystemLanguageModel.default
    let compact = try await model.tokenCount(for: engine.context.compactTools)
    let all = try await model.tokenCount(for: engine.context.allTools)
    let instructions = try await model.tokenCount(for: Instructions(AssistantPrompt.compactInstructions))
    let full = try await model.tokenCount(for: Instructions(AssistantPrompt.instructions))
    let summary = try await model.tokenCount(for: Prompt(AssistantPrompt.request("x", summary: AssistantWorkbench(workspace: try scenarioWorkspace(scenario)).summary())))
    print("on-device context \(model.contextSize); compact tools \(compact), all tools \(all); compact instructions \(instructions), full \(full); \(scenario) summary \(summary)")
}

var workspace = try scenarioWorkspace(scenario)
for request in arguments {
    print("\n▶︎ \(request)")
    let started = Date()
    do {
        let turn = try await engine.respond(to: request, workspace: workspace, selection: nil, choice: choice,
                                            onActivity: { print("  · \($0)") }, onText: { _ in })
        print("  ⟵ \(turn.reply)")
        print("  changes: \(turn.bench.changes.isEmpty ? "none" : turn.bench.changes.joined(separator: " | "))")
        print(String(format: "  %.1f s on %@", Date().timeIntervalSince(started), turn.backend.title))
        if carry { workspace = turn.bench.workspace }
        print(turn.bench.summary().split(separator: "\n").dropFirst().map { "    " + $0 }.joined(separator: "\n"))
    } catch {
        print("  ✗ \(error.localizedDescription)  [\(error)]")
    }
}
