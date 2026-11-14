import XCTest
import Foundation
import FoundationModels
#if os(iOS)
@testable import SwipeAndSketch
#else
@testable import AssistantEval
#endif

/// Script the HTTP boundary; every geometry operation below uses the actual CAD tools/kernel.
@MainActor final class ClaudeAssistantTests: XCTestCase {
    let fakeKey = "test-credential-never-send-to-network"

    /// Starting models built through the assistant's own workbench.
    static func fixture(_ id: String) throws -> Workspace {
        var bench = AssistantWorkbench(workspace: Workspace())
        func box(_ width: Double, _ length: Double, _ height: Double) throws {
            try bench.addShapes([.init(kind: .rectangle, point: [0, 0, 0], width: width, height: length)], on: .world(.top))
            try bench.extrude(sketch: "Sketch \(bench.workspace.sketches.count)", regions: [], distance: height, mode: .newBody, throughAll: false)
        }
        switch id {
        case "block": try box(60, 40, 20)
        case "open-box":
            try box(60, 40, 20)
            try bench.shell(body: "Body 01", openFaces: ["top"], thickness: 2)
        case "three-sketches":
            // Each rectangle in its own sketch, so rounding one sketch renumbers the others.
            for (x, width) in [(-40.0, 30.0), (0, 20), (40, 16)] {
                try bench.addShapes([.init(kind: .rectangle, point: [x, 0, 0], width: width, height: 20)], on: .world(.top))
            }
        default: XCTFail("No fixture \(id)")
        }
        return bench.workspace
    }

    func testNativeRecipeToolBuildsEditablePartsAndRejectsUnclampedSizes() async throws {
        var stage = 0
        let make = tool("make_slip_lid_box", input: .object([
            "reference": .string("closed"), "width": .number(64), "depth": .number(44), "height": .number(24),
            "wall": .number(2), "radius": .number(6), "clearance": .number(0.2), "vents": .bool(false)
        ]))
        let engine = AssistantEngine(claude: ClaudeAssistant { _ in
            stage += 1
            return try self.http(stage == 1 ? self.answer([make], reason: "tool_use") : self.answer([self.text("The box and lid are ready to review.")]))
        }, claudeKey: { self.fakeKey })
        let turn = try await engine.respond(to: "Make a closed 64 by 44 by 24 mm enclosure with a slip-on lid.", workspace: Workspace(), selection: nil,
                                            choice: .claude, onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(turn.bench.workspace.bodies.count, 2)
        XCTAssertEqual(turn.bench.changes.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: turn.bench.workspace.bodies[0]).bounds.max.z, 22, accuracy: 0.001)
        let context = AssistantContext(); context.reset(workspace: Workspace(), selection: nil)
        let invalid = try await ClaudeToolBridge.call(MakeSlipLidBoxTool(context: context), input: .object([
            "reference": .string("inside"), "width": .number(500), "depth": .number(40), "height": .number(20)
        ]))
        XCTAssertTrue(invalid.hasPrefix("Error:"))
        XCTAssertEqual(context.bench.workspace, Workspace())
    }

    func testPlannerFindsNamesSaidOnTheirOwn() {
        XCTAssertTrue(AssistantPlanner.mentions("round the lid's edges", "Lid"))
        XCTAssertFalse(AssistantPlanner.mentions("make it lidded", "Lid"))
        XCTAssertTrue(AssistantPlanner.mentions("move bracket (2) up", "bracket (2)"))
        XCTAssertFalse(AssistantPlanner.mentions("move body 10 up", "Body 1"))
        XCTAssertTrue(AssistantPlanner.mentions("body 1", "Body 1"))
    }

    func testPlannerTemplateActionUsesSameValidationAndCapabilitySwitch() throws {
        var bench = AssistantWorkbench(workspace: Workspace())
        let v = SlipLidBoxValues(reference: "inside", width: 60, depth: 40, height: 20, wall: 2, radius: 6, clearance: 0.2, vents: false)
        try AssistantPlanner.applySlipLidBox(v, to: &bench)
        XCTAssertEqual(bench.workspace.bodies.count, 2)
        var other = AssistantWorkbench(workspace: Workspace())
        XCTAssertThrowsError(try AssistantPlanner.applySlipLidBox(.init(reference: "unspecified", width: 60, depth: 40, height: 20,
                                                                       wall: nil, radius: nil, clearance: nil, vents: nil), to: &other))
        XCTAssertFalse(other.hasChanges)
        let old = AssistantEngine.nativeTemplatesEnabled
        defer { AssistantEngine.nativeTemplatesEnabled = old }
        AssistantEngine.nativeTemplatesEnabled = false
        XCTAssertFalse(AssistantContext().allTools.contains { $0.name == "make_slip_lid_box" })
        XCTAssertFalse(AssistantPrompt.instructions.contains("Native recipe available:"))
        AssistantEngine.nativeTemplatesEnabled = true
        XCTAssertTrue(AssistantContext().allTools.contains { $0.name == "make_slip_lid_box" })
        XCTAssertTrue(AssistantPrompt.instructions.contains("Native recipe available:"))
    }

    func testRequirementChecksReportWrongGeometryDespiteConfidentReplyAndResetPerRequest() async throws {
        let request = "Keep the block 60 by 40 by 20 mm."
        let record = tool("record_requirements", input: .object(["requirements": .array([.object([
            "quote": .string(request), "kind": .string("bodySize"), "target": .string("Body 01"),
            "expected": .array([.number(60), .number(40), .number(20)])
        ])])]))
        let resize = tool("set_dimension", id: "resize", input: .object([
            "item": .string("Body 01"), "dimension": .string("depth"), "value": .number(10)
        ]))
        var count = 0
        let engine = AssistantEngine(claude: ClaudeAssistant { _ in
            count += 1
            return try self.http(count == 1 ? self.answer([record, resize], reason: "tool_use") : self.answer([self.text("All dimensions are correct.")]))
        }, claudeKey: { self.fakeKey })
        let workspace = try Self.fixture("block")
        let turn = try await engine.respond(to: request, workspace: workspace, selection: nil, choice: .claude, onActivity: { _ in }, onText: { _ in })
        XCTAssertEqual(turn.requirements.results.map(\.status), [.unmet])
        XCTAssertTrue(turn.requirements.results[0].detail.contains("60 × 40 × 10"))
        XCTAssertEqual(workspace.bodies[0].depth, 20, "Only the draft changed")
        let query = try await engine.respond(to: "How tall is it?", workspace: turn.bench.workspace, selection: nil, choice: .claude, onActivity: { _ in }, onText: { _ in })
        XCTAssertTrue(query.requirements.results.isEmpty, "Checks from an earlier request must not be certified against a later draft")
    }

    func testRequirementExpectationsCannotBeReplacedOrAddedAfterAnEdit() async throws {
        let context = AssistantContext(), workspace = try Self.fixture("block")
        let requirement = AssistantRequirement(quote: "20 mm tall", kind: "bodySize", target: "Body 01", expected: [60, 40, 20])
        context.reset(workspace: workspace, selection: nil, request: "60 by 40 by 20 mm tall")
        XCTAssertFalse(context.recordRequirements([requirement]).hasPrefix("Error:"))
        XCTAssertTrue(context.recordRequirements([requirement]).hasPrefix("Error:"))
        context.reset(workspace: workspace, selection: nil, request: "60 by 40 by 20 mm tall")
        _ = await context.run("Resize") { bench in try bench.setDimension(item: "Body 01", dimension: "depth", value: 10) }
        XCTAssertTrue(context.recordRequirements([requirement]).hasPrefix("Error:"))
        XCTAssertTrue(context.requirementReport.results.isEmpty)
    }

    /// The free-construction traces' stale call, replayed at the HTTP boundary: Rectangle 01 is
    /// retired by rounding, then offset by that name. Structural context only changes what the
    /// rounding result tells the model; the stale call fails the same way, within the same budget.
    func testRoundingResultReportsTheRetiredRectangleOnlyWithStructuralContext() async throws {
        let old = AssistantEngine.structuralContextEnabled
        defer { AssistantEngine.structuralContextEnabled = old }
        let sketch = tool("add_sketch", id: "sketch", input: .object([
            "on": .string("top"), "shapes": .array([.object([
                "kind": .string("rectangle"), "x": .number(0), "y": .number(0), "z": .number(0), "width": .number(60), "height": .number(40)
            ])])
        ]))
        let round = tool("round_sketch_corners", id: "round", input: .object(["sketch": .string("Sketch 01"), "radius": .number(5)]))
        let offset = tool("offset_sketch", id: "offset", input: .object(["shape": .string("Rectangle 01"), "distance": .number(-3)]))
        for enabled in [false, true] {
            AssistantEngine.structuralContextEnabled = enabled
            var requests: [URLRequest] = []
            let engine = AssistantEngine(claude: ClaudeAssistant { request in
                requests.append(request)
                switch requests.count {
                case 1: return try self.http(self.answer([sketch, round], reason: "tool_use"))
                case 2: return try self.http(self.answer([offset], reason: "tool_use"))
                default: return try self.http(self.answer([self.text()]))
                }
            }, claudeKey: { self.fakeKey })
            _ = try await run(engine, workspace: Workspace())
            let results = try XCTUnwrap(payload(requests[1])["messages"]?.array?.last?["content"]?.array)
            let rounded = try XCTUnwrap(results.first { $0["tool_use_id"]?.string == "round" }?["content"]?.string)
            XCTAssertEqual(rounded.contains("Retired, no longer usable: Rectangle 01 (in Sketch 01)."), enabled, rounded)
            XCTAssertEqual(rounded.contains("New in Sketch 01: Line 01–04, Arc 01–04."), enabled, rounded)
            let stale = try XCTUnwrap(payload(requests[2])["messages"]?.array?.last?["content"]?.array?.first)
            XCTAssertTrue(stale["content"]?.string?.hasPrefix("Error: There is no Rectangle 01") == true)
            XCTAssertEqual(engine.context.toolCalls, 3)
        }
    }

    /// structure-01's wrong-target edit, replayed: rounding Sketch 01 and widening "Rectangle 02" in
    /// one round. With the name guard the second call is refused instead of widening Sketch 03's
    /// rectangle; the next round's names mean what the results said.
    func testNameGuardRefusesASameRoundRenumberedNameAtTheClaudeBoundary() async throws {
        let old = AssistantEngine.nameGuardEnabled
        defer { AssistantEngine.nameGuardEnabled = old }
        let round = tool("round_sketch_corners", id: "round", input: .object(["sketch": .string("Sketch 01"), "radius": .number(4)]))
        let widen = tool("set_dimension", id: "widen", input: .object(["item": .string("Rectangle 02"), "dimension": .string("width"), "value": .number(30)]))
        let retry = tool("set_dimension", id: "retry", input: .object(["item": .string("Rectangle 01"), "dimension": .string("width"), "value": .number(30)]))
        let start = try Self.fixture("three-sketches")
        let third = start.sketches[2].id, second = start.sketches[1].id
        for enabled in [false, true] {
            AssistantEngine.nameGuardEnabled = enabled
            var requests: [URLRequest] = []
            let engine = AssistantEngine(claude: ClaudeAssistant { request in
                requests.append(request)
                switch requests.count {
                case 1: return try self.http(self.answer([round, widen], reason: "tool_use"))
                case 2 where enabled: return try self.http(self.answer([retry], reason: "tool_use"))
                default: return try self.http(self.answer([self.text()]))
                }
            }, claudeKey: { self.fakeKey })
            let turn = try await run(engine, workspace: start)
            let results = try XCTUnwrap(payload(requests[1])["messages"]?.array?.last?["content"]?.array)
            let widened = try XCTUnwrap(results.first { $0["tool_use_id"]?.string == "widen" }?["content"]?.string)
            XCTAssertEqual(widened.hasPrefix("Error: Rectangle 02 meant Rectangle 02 (in Sketch 02) when this call was sent"), enabled, widened)
            let rectangles = { (sketch: UUID) in turn.bench.workspace.shapes(in: sketch).filter { $0.kind == .rectangle } }
            XCTAssertEqual(rectangles(third) == start.shapes(in: third), enabled, "Sketch 03 is untouched only with the guard")
            XCTAssertEqual(abs((rectangles(second).first?.end.x ?? 0) - (rectangles(second).first?.start.x ?? 0)), enabled ? 30 : 20, accuracy: 1e-9)
        }
    }

    func testBackendsWithoutRoundsKeepCurrentNamesButLearnWhatWasRetired() async throws {
        let old = AssistantEngine.nameGuardEnabled
        defer { AssistantEngine.nameGuardEnabled = old }
        AssistantEngine.nameGuardEnabled = true
        let context = AssistantContext()
        context.reset(workspace: try Self.fixture("three-sketches"), selection: nil)
        _ = await context.run("Rounding") { try $0.roundCorners(sketch: "Sketch 01", radius: 4) }
        // No beginRound: the on-device and Apple cloud paths resolve names as they are now.
        let changed = await context.run("Changing") { try $0.setDimension(item: "Rectangle 01", dimension: "width", value: 30) }
        XCTAssertFalse(changed.hasPrefix("Error:"))
        let renamed = await context.run("Changing") { try $0.setDimension(item: "Rectangle 03", dimension: "width", value: 30) }
        XCTAssertEqual(renamed,
                       "Error: Rectangle 03 (Rectangle 03 (in Sketch 03)) was renamed or renumbered earlier in this request: it is now Rectangle 02 (in Sketch 03).")
    }

    func tool(_ name: String = "make_container", id: String = "call-1", input: ClaudeJSON? = nil) -> ClaudeJSON {
        .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name),
                 "input": input ?? .object(["body": .string("Body 01"), "openFaces": .array([.string("top")]), "thickness": .number(2)])])
    }
    func answer(_ content: [ClaudeJSON], reason: String = "end_turn", details: ClaudeJSON = .null) -> ClaudeJSON {
        .object(["role": .string("assistant"), "content": .array(content), "stop_reason": .string(reason), "stop_details": details])
    }
    func text(_ value: String = "Done.") -> ClaudeJSON { .object(["type": .string("text"), "text": .string(value)]) }
    func payload(_ request: URLRequest) throws -> ClaudeJSON { try JSONDecoder().decode(ClaudeJSON.self, from: XCTUnwrap(request.httpBody)) }
    func http(_ body: ClaudeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONEncoder().encode(body), try XCTUnwrap(HTTPURLResponse(url: ClaudeAssistant.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
    func run(_ engine: AssistantEngine, workspace: Workspace? = nil) async throws -> AssistantEngine.Turn {
        try await engine.respond(to: "Make an open-top container with 2 mm walls and floor.",
                                 workspace: workspace ?? Self.fixture("block"), selection: nil, choice: .claude,
                                 onActivity: { _ in }, onText: { _ in })
    }

    func testClaudeShellUsesSharedToolsAndPreservesSignedThinking() async throws {
        var requests: [URLRequest] = []
        let thinking: ClaudeJSON = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("opaque-signature")])
        let blocks = [thinking, tool()]
        let client = ClaudeAssistant { request in
            requests.append(request)
            return try self.http(requests.count == 1 ? self.answer(blocks, reason: "tool_use") : self.answer([self.text()]))
        }
        let engine = AssistantEngine(claude: client, claudeKey: { self.fakeKey })
        let original = try Self.fixture("block")
        let turn = try await run(engine, workspace: original)
        XCTAssertEqual(turn.backend, .claude)
        XCTAssertEqual(original.bodies[0].cuts.count, 0, "the original remains unchanged")
        XCTAssertEqual(turn.bench.workspace.bodies[0].cuts.first?.shell?.thickness, 2)
        XCTAssertEqual(engine.context.toolCalls, 1)
        XCTAssertTrue(turn.bench.workspace.isValid)
        XCTAssertEqual(turn.bench.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: turn.bench.workspace.bodies[0]).volume,
                       try SolidKernel.solid(for: Self.fixture("open-box").bodies[0]).volume, accuracy: 0.01)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, ClaudeAssistant.endpoint)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeKey)")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let first = try payload(requests[0])
        XCTAssertEqual(first["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(first["output_config"]?["effort"]?.string, "high")
        XCTAssertNil(first["temperature"])
        XCTAssertEqual(first["tool_choice"]?["type"]?.string, "auto")
        XCTAssertFalse(String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self).contains(fakeKey))
        let definitions = try XCTUnwrap(first["tools"]?.array)
        XCTAssertEqual(definitions.compactMap { $0["name"]?.string }, engine.context.allTools.map(\.name))
        XCTAssertTrue(definitions.allSatisfy { $0["input_schema"]?["type"]?.string == "object" })
        let messages = try XCTUnwrap(payload(requests[1])["messages"]?.array)
        XCTAssertEqual(messages[1]["content"]?.array, blocks, "signed thinking is echoed unchanged")
        let result = try XCTUnwrap(messages.last?["content"]?.array?.first)
        XCTAssertEqual(result["tool_use_id"]?.string, "call-1")
        XCTAssertTrue(result["content"]?.string?.contains("Measured result:") == true)
    }

    func testBadToolArgumentsReturnErrorsAndCanBeCorrected() async throws {
        var requests: [URLRequest] = []
        let malformed = tool(input: .object(["body": .string("Body 01"), "openFaces": .array([.string("top")]), "thickness": .string("invalid")]))
        let client = ClaudeAssistant { request in
            requests.append(request)
            switch requests.count {
            case 1: return try self.http(self.answer([malformed], reason: "tool_use"))
            case 2: return try self.http(self.answer([self.tool(id: "corrected")], reason: "tool_use"))
            default: return try self.http(self.answer([self.text()]))
            }
        }
        let result = try await run(AssistantEngine(claude: client, claudeKey: { self.fakeKey }))
        XCTAssertEqual(result.bench.workspace.bodies[0].cuts.first?.shell?.thickness, 2)
        let messages = try XCTUnwrap(payload(requests[1])["messages"]?.array)
        XCTAssertEqual(messages.last?["content"]?.array?.first?["is_error"], .bool(true))
    }

    func testNestedSketchArgumentsAndSequentialToolsCreateAnAnalyticSolid() async throws {
        let sketch = tool("add_sketch", id: "sketch", input: .object([
            "on": .string("top"), "shapes": .array([.object([
                "kind": .string("rectangle"), "x": .number(0), "y": .number(0), "z": .number(0),
                "width": .number(60), "height": .number(40)
            ])])
        ]))
        let extrusion = tool("extrude", id: "extrusion", input: .object([
            "sketch": .string("Sketch 01"), "distance": .number(20), "operation": .string("new body")
        ]))
        var count = 0
        let engine = AssistantEngine(claude: ClaudeAssistant { _ in
            count += 1
            return try self.http(count == 1 ? self.answer([sketch, extrusion], reason: "tool_use") : self.answer([self.text()]))
        }, claudeKey: { self.fakeKey })
        let result = try await run(engine, workspace: Workspace())
        XCTAssertEqual(engine.context.toolCalls, 2)
        XCTAssertEqual(result.bench.workspace.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: XCTUnwrap(result.bench.workspace.bodies.first)).volume, 48000, accuracy: 0.01)
        XCTAssertFalse(result.bench.workspace.sketches.isEmpty)
    }

    func testTruncationAndRefusalsNeverExecuteIncludedTools() async throws {
        let responses = [answer([tool()], reason: "max_tokens"), answer([tool()], reason: "refusal"),
                         answer([tool()], reason: "tool_use", details: .object(["type": .string("refusal")]))]
        for (index, response) in responses.enumerated() {
            var calls = 0
            let engine = AssistantEngine(claude: ClaudeAssistant { _ in calls += 1; return try self.http(response) }, claudeKey: { self.fakeKey })
            do { _ = try await run(engine); XCTFail("Incomplete/refused response must fail") }
            catch { XCTAssertEqual(AssistantEngine.failureKind(error), index == 0 ? .execution : .refusal) }
            XCTAssertEqual(calls, 1, "explicit Claude never silently falls back or retries")
            XCTAssertEqual(engine.context.toolCalls, 0)
            XCTAssertFalse(engine.context.bench.hasChanges)
        }
    }

    func testCredentialFailuresAreClearAndNeverExposeProviderBody() async throws {
        var calls = 0
        let client = ClaudeAssistant { _ in
            calls += 1
            return try self.http(.object(["error": .string(self.fakeKey)]), status: 401)
        }
        let missing = AssistantEngine(claude: client, claudeKey: { nil })
        do { _ = try await run(missing); XCTFail("Missing key must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Settings")) }
        XCTAssertEqual(calls, 0)
        let invalid = AssistantEngine(claude: client, claudeKey: { self.fakeKey })
        var diagnostics: [AssistantDiagnostic] = []
        invalid.onDiagnostic = { diagnostics.append($0) }
        do { _ = try await run(invalid); XCTFail("Unauthorized key must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("API key"))
            XCTAssertFalse(error.localizedDescription.contains(fakeKey))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(diagnostics.last?.backend, .claude)
        XCTAssertFalse(String(describing: diagnostics).contains(fakeKey))
        XCTAssertEqual(AssistantEngine.backends(for: .claude), [.claude])
        XCTAssertFalse(AssistantEngine.backends(for: .automatic).contains(.claude))
    }

    func testCancellationStopsBeforeAnyGeometryChange() async throws {
        var started = false
        let client = ClaudeAssistant { _ in
            started = true
            try await Task.sleep(for: .seconds(30))
            return try self.http(self.answer([self.tool()], reason: "tool_use"))
        }
        let engine = AssistantEngine(claude: client, claudeKey: { self.fakeKey })
        let task = Task { try await self.run(engine) }
        for _ in 0..<100 where !started { await Task.yield() }
        XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must not return a draft") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.context.toolCalls, 0)
        XCTAssertFalse(engine.context.bench.hasChanges)
    }

    /// A batch past the tool limit doesn't run: Claude is asked, with tools off, to say what it did;
    /// asking for tools even then ends the request.
    func testToolBudgetRejectsOversizedBatchBeforeExecutingAndAsksForASummary() async throws {
        let calls = (0...AssistantContext.maximumCalls).map { tool(id: "call-\($0)") }
        var requests: [URLRequest] = []
        let engine = AssistantEngine(claude: ClaudeAssistant { request in
            requests.append(request)
            return try self.http(requests.count == 1 ? self.answer(calls, reason: "tool_use") : self.answer([self.text("Nothing was changed: that was too many steps.")]))
        }, claudeKey: { self.fakeKey })
        let turn = try await run(engine)
        XCTAssertEqual(turn.reply, "Nothing was changed: that was too many steps.")
        XCTAssertFalse(engine.context.bench.hasChanges)
        XCTAssertEqual(try payload(requests[1])["tool_choice"]?["type"]?.string, "none")
        let results = try XCTUnwrap(payload(requests[1])["messages"]?.array?.last?["content"]?.array)
        XCTAssertEqual(results.count, calls.count, "Every call is answered")

        let stubborn = AssistantEngine(claude: ClaudeAssistant { _ in try self.http(self.answer(calls, reason: "tool_use")) }, claudeKey: { self.fakeKey })
        do { _ = try await run(stubborn); XCTFail("Tool budget must apply") }
        catch { XCTAssertTrue(error.localizedDescription.contains("tool limit")) }
        XCTAssertFalse(stubborn.context.bench.hasChanges)
    }

    /// Rate limits and an overloaded service are tried again after the wait the service asks for.
    func testRateLimitsAndOverloadAreRetried() async throws {
        var statuses = [429, 529]
        let engine = AssistantEngine(claude: ClaudeAssistant { _ in
            let status = statuses.isEmpty ? 200 : statuses.removeFirst()
            let body = try JSONEncoder().encode(self.answer([self.text("The block is 20 mm tall.")]))
            return (body, try XCTUnwrap(HTTPURLResponse(url: ClaudeAssistant.endpoint, statusCode: status, httpVersion: nil, headerFields: ["retry-after": "0"])))
        }, claudeKey: { self.fakeKey })
        let turn = try await run(engine)
        XCTAssertEqual(turn.reply, "The block is 20 mm tall.")
        XCTAssertTrue(statuses.isEmpty)
    }

    func testDroppingOldExchangesAlsoDropsThinkingFromTheOnesKept() async throws {
        var requests: [URLRequest] = []
        let thinking: ClaudeJSON = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("opaque-signature")])
        let engine = AssistantEngine(claude: ClaudeAssistant { request in
            requests.append(request)
            return try self.http(self.answer([thinking, self.text("The block is 20 mm tall.")]))
        }, claudeKey: { self.fakeKey })
        for _ in 0..<6 { _ = try await run(engine) }
        func thinkingBlocks(_ request: URLRequest) throws -> Int {
            try XCTUnwrap(payload(request)["messages"]?.array).flatMap { $0["content"]?.array ?? [] }.filter { $0["type"]?.string == "thinking" }.count
        }
        // Up to the limit the history only grows, with every signed thinking block echoed.
        XCTAssertEqual(try payload(requests[4])["messages"]?.array?.count, 9)
        XCTAssertEqual(try thinkingBlocks(requests[4]), 4)
        // After the oldest exchange is dropped, the kept ones carry no thinking.
        let messages = try XCTUnwrap(payload(requests[5])["messages"]?.array)
        XCTAssertEqual(messages.count, 2 * ClaudeAssistant.keptExchanges + 1)
        XCTAssertEqual(try thinkingBlocks(requests[5]), 0)
        XCTAssertTrue(messages.filter { $0["role"]?.string == "assistant" }.allSatisfy { $0["content"]?.array?.first?["text"]?.string == "The block is 20 mm tall." })
    }

    func testChangingKeyAndResettingConversationDropEarlierMessages() async throws {
        var requests: [URLRequest] = []
        var key = fakeKey
        let engine = AssistantEngine(claude: ClaudeAssistant { request in
            requests.append(request)
            return try self.http(self.answer([self.text("The block is 20 mm tall.")]))
        }, claudeKey: { key })
        _ = try await run(engine)
        _ = try await run(engine)
        XCTAssertEqual(try payload(requests[1])["messages"]?.array?.count, 3)
        key = "different-test-account"
        _ = try await run(engine)
        XCTAssertEqual(try payload(requests[2])["messages"]?.array?.count, 1)
        engine.reset()
        _ = try await run(engine)
        XCTAssertEqual(try payload(requests[3])["messages"]?.array?.count, 1)
    }

    #if os(iOS)
    func testKeychainSaveReplaceValidateAndRemove() throws {
        // Clean up only the exact synthetic key left if a prior Settings UI test was interrupted.
        if try ClaudeCredentials.shared.read() == "test-ui-credential-not-a-real-key" { try ClaudeCredentials.shared.remove() }
        let store = ClaudeCredentials(service: "noventix.SwipeAndSketch.tests.\(UUID().uuidString)")
        defer { try? store.remove() }
        XCTAssertNil(try store.read())
        try store.save("  test-key-one\n")
        XCTAssertEqual(try store.read(), "test-key-one")
        try store.save("test-key-two")
        XCTAssertEqual(try store.read(), "test-key-two")
        XCTAssertThrowsError(try store.save("invalid\r\nheader: value"))
        XCTAssertEqual(try store.read(), "test-key-two", "invalid input cannot replace a working key")
        try store.remove()
        XCTAssertNil(try store.read())
        try store.remove()
    }
    #endif
}
