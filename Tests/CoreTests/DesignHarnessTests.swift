import XCTest
import simd
@testable import SwipeAndSketchCore

/// The assistant's design harness: the document a model reads (native solids as features), how a
/// proposal changes native solids while keeping their identities, and the one-correction loop.
final class DesignHarnessTests: XCTestCase {
    typealias Feature = DesignFeature

    // MARK: Fixtures

    /// The mounting plate: 80 × 50 × 5 mm, R5 corners, four Ø4.5 through holes at (±34, ±19).
    func plateProposal(rightRadius: Double = 2.25) -> DesignProposal {
        var features = [Feature(id: "plate", body: "Plate", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0,
                                width: 80, depth: 50, height: 5, radius: 5)]
        for (name, x, y) in [("bore-left-front", -34.0, -19.0), ("bore-left-back", -34, 19), ("bore-right-front", 34, -19), ("bore-right-back", 34, 19)] {
            features.append(Feature(id: name, body: "Plate", kind: .cylinder, operation: .cut, axis: .pz, x: x, y: y, z: 0,
                                    height: 5, radius: x > 0 ? rightRadius : 2.25))
        }
        return DesignProposal(intent: .change, features: features)
    }

    func applied(_ proposal: DesignProposal, to workspace: Workspace = Workspace()) throws -> (bench: AssistantWorkbench, document: DesignDocument, aliases: DesignAliases) {
        let (document, aliases) = DesignExport.document(of: workspace)
        var bench = AssistantWorkbench(workspace: workspace)
        try bench.applyDesign(proposal, aliases: aliases)
        return (bench, document, aliases)
    }

    func volume(_ body: SolidBody) throws -> Double { try SolidKernel.solid(for: body).volume }

    func json(_ proposal: DesignProposal) -> String {
        String(decoding: try! JSONEncoder().encode(proposal), as: UTF8.self)
    }

    // MARK: Create and edit

    func testPlateFromABlankDocumentMatchesTheReferenceMeasurements() throws {
        let bench = try applied(plateProposal()).bench
        XCTAssertEqual(bench.workspace.bodies.count, 1)
        let body = bench.workspace.bodies[0]
        XCTAssertEqual(body.name, "Plate")
        XCTAssertEqual(body.cuts.count, 4)
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertEqual(solid.volume, 19_574.613, accuracy: 0.1)
        let bounds = solid.bounds
        for (actual, expected) in zip([bounds.min.x, bounds.min.y, bounds.min.z, bounds.max.x, bounds.max.y, bounds.max.z], [-40.0, -25, 0, 40, 25, 5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.025)
        }
        XCTAssertEqual(bench.changes.count, 1)
        XCTAssertTrue(bench.changes[0].hasPrefix("New Plate: 80 × 50 block 5 mm along +Z, R5 corners, then 4 more features"), bench.changes[0])
    }

    func testExportReadsTheNativePlateBackAsTheSameFeatures() throws {
        let workspace = try applied(plateProposal()).bench.workspace
        let (document, aliases) = DesignExport.document(of: workspace)
        XCTAssertEqual(document.bodies.map(\.id), ["B1"])
        XCTAssertEqual(document.bodies[0].name, "Plate")
        XCTAssertEqual(document.features.map(\.id), ["B1.F1", "B1.F2", "B1.F3", "B1.F4", "B1.F5"])
        let base = document.features[0]
        XCTAssertEqual(base.kind, .block); XCTAssertEqual(base.operation, .add); XCTAssertEqual(base.axis, .pz)
        XCTAssertEqual(base.width, 80); XCTAssertEqual(base.depth, 50); XCTAssertEqual(base.height, 5); XCTAssertEqual(base.radius, 5)
        XCTAssertEqual([base.x, base.y, base.z], [0, 0, 0])
        let bore = document.features[3]
        XCTAssertEqual(bore.kind, .cylinder); XCTAssertEqual(bore.operation, .cut); XCTAssertEqual(bore.radius, 2.25)
        XCTAssertEqual([bore.x, bore.y, bore.z], [34, -19, 0])
        XCTAssertEqual(aliases.bodies["B1"], workspace.bodies[0].id)
        XCTAssertEqual(aliases.features["B1.F4"], .init(body: workspace.bodies[0].id, role: .step(workspace.bodies[0].cuts[2].id)))
        // Repeating every feature unchanged changes nothing.
        var bench = AssistantWorkbench(workspace: workspace)
        try bench.applyDesign(DesignProposal(features: document.features), aliases: aliases)
        XCTAssertEqual(bench.workspace, workspace)
        XCTAssertTrue(bench.changes.isEmpty)
    }

    func testEnlargingOnlyTheRightHolesKeepsEveryIdentity() throws {
        let original = try applied(plateProposal()).bench.workspace
        let (document, aliases) = DesignExport.document(of: original)
        let right = document.features.filter { $0.kind == .cylinder && $0.x == 34 }.map { feature -> Feature in
            var feature = feature
            feature.radius = 3
            return feature
        }
        XCTAssertEqual(right.count, 2)
        var bench = AssistantWorkbench(workspace: original)
        try bench.applyDesign(DesignProposal(features: right), aliases: aliases)
        let before = original.bodies[0], after = bench.workspace.bodies[0]
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.profile, before.profile)
        XCTAssertEqual(after.cuts.map(\.id), before.cuts.map(\.id))
        XCTAssertEqual(zip(before.cuts, after.cuts).filter { $0 != $1 }.count, 2)
        XCTAssertEqual(try volume(after), 19_450.913, accuracy: 0.1)
        XCTAssertEqual(bench.changes.count, 1)
        XCTAssertEqual(bench.changes[0], "Plate: cut Ø4.5 cylinder 5 mm along +Z → cut Ø6 cylinder 5 mm along +Z; cut Ø4.5 cylinder 5 mm along +Z → cut Ø6 cylinder 5 mm along +Z")
        // And the same edit read from the model's JSON.
        let text = json(DesignProposal(features: right))
        var fromText = AssistantWorkbench(workspace: original)
        try fromText.applyDesign(try DesignProposal.decode("```json\n" + text + "\n```"), aliases: aliases)
        XCTAssertEqual(fromText.workspace, bench.workspace)
    }

    func testFeaturesTheDocumentCannotSayAreLockedButKept() throws {
        var body = try box()
        body.taper = 5
        var other = try box(50, -10, 70, 10, depth: 10)
        other.cuts.append(.subtract(try box(55, -5, 65, 5, depth: 30)))
        let workspace = Workspace(bodies: [body, other])
        let (document, aliases) = DesignExport.document(of: workspace)
        XCTAssertEqual(document.features.map(\.kind), [.locked, .block, .locked])
        XCTAssertEqual(document.features[0].note, "profile extruded 20 mm with 5° taper")
        XCTAssertEqual(document.features[2].note, "another solid subtracted")
        // A hole added after a locked step keeps the locked step as it was.
        var bench = AssistantWorkbench(workspace: workspace)
        try bench.applyDesign(DesignProposal(features: [Feature(id: "pin", body: "B2", kind: .hole, axis: .pz, x: 52, y: 8, z: 10,
                                                                    throughAll: true, hole: .init(type: .simple, diameter: 2))]), aliases: aliases)
        XCTAssertEqual(bench.workspace.bodies[1].cuts.count, 2)
        XCTAssertEqual(bench.workspace.bodies[1].cuts[0], other.cuts[0])
        XCTAssertEqual(bench.workspace.bodies[0], body, "The other solid is untouched")
        // Changing a locked feature is refused, with what it is.
        var locked = document.features[2]
        locked.height = 4
        var repeated = AssistantWorkbench(workspace: workspace)
        try repeated.applyDesign(DesignProposal(features: [locked]), aliases: aliases)
        XCTAssertEqual(repeated.workspace, workspace, "Values a locked feature does not use are ignored")
        locked.kind = .block
        locked.operation = .cut
        locked.width = 5; locked.depth = 5; locked.x = 60; locked.y = 0; locked.z = 0; locked.axis = .pz
        XCTAssertThrowsError(try AssistantWorkbench(workspace: workspace).applying(DesignProposal(features: [locked]), aliases: aliases)) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.contains("is locked (another solid subtracted)") ?? false, "\(error)")
        }
    }

    func testProposalsThatCannotApplySayWhy() throws {
        let workspace = try applied(plateProposal()).bench.workspace
        let (document, aliases) = DesignExport.document(of: workspace)
        let bench = AssistantWorkbench(workspace: workspace)
        func message(_ proposal: DesignProposal) -> String {
            do { _ = try bench.applying(proposal, aliases: aliases); return "applied" }
            catch { return (error as? AssistantWorkbench.Failure)?.message ?? "\(error)" }
        }
        XCTAssertTrue(message(DesignProposal(removeIDs: ["B1.F9"])).contains("not in the document"))
        XCTAssertTrue(message(DesignProposal(removeIDs: ["B1.F1"])).contains("first feature of its solid"))
        XCTAssertTrue(message(DesignProposal(features: [document.features[1]], removeIDs: ["B1.F2"])).contains("both removed and changed"))
        XCTAssertTrue(message(DesignProposal(features: [document.features[1], document.features[1]])).contains("only once"))
        var moved = document.features[1]; moved.body = "B2"
        XCTAssertTrue(message(DesignProposal(features: [moved])).contains("cannot move to another solid"))
        let cutFirst = Feature(id: "cutter", body: "Bracket", kind: .cylinder, operation: .cut, axis: .pz, x: 0, y: 0, z: 0, height: 5, radius: 2)
        XCTAssertTrue(message(DesignProposal(features: [cutFirst])).contains("must add a block, cylinder, or polygon"))
        let badCorner = Feature(id: "block", body: "Bracket", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0, width: 10, depth: 10, height: 5, radius: 5)
        XCTAssertTrue(message(DesignProposal(features: [badCorner])).contains("Corner radius"))
        XCTAssertTrue(message(DesignProposal(features: [Feature(id: "tag", body: "B1", kind: .locked)])).contains("cannot be added"))
        XCTAssertEqual(message(DesignProposal(removeIDs: ["B1"])), "applied", "A solid's alias removes the whole solid")
    }

    func testPocketsFromATopFaceGoDownAndJoinedBossesGoUp() throws {
        let proposal = DesignProposal(features: [
            Feature(id: "base", body: "Tray", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0, width: 40, depth: 40, height: 10),
            Feature(id: "pocket", body: "Tray", kind: .block, operation: .cut, axis: .nz, x: 0, y: 0, z: 10, width: 20, depth: 20, height: 4),
            Feature(id: "post", body: "Tray", kind: .cylinder, operation: .add, axis: .pz, x: 15, y: 15, z: 10, height: 6, radius: 2),
            Feature(id: "side", body: "Tray", kind: .polygon, operation: .cut, axis: .py, x: 0, y: -20, z: 0, height: 3,
                    points: [.init(u: -5, v: 0), .init(u: 5, v: 0), .init(u: 0, v: 5)])
        ])
        let body = try applied(proposal).bench.workspace.bodies[0]
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        let expected = 40.0 * 40 * 10 - 20 * 20 * 4 + Double.pi * 4 * 6 - 0.5 * 10 * 5 * 3
        XCTAssertEqual(solid.volume, expected, accuracy: 0.5)
        XCTAssertEqual(solid.bounds.max.z, 16, accuracy: 1e-6)
        // And read back: a −Z pocket and a +Y polygon cut.
        let document = DesignExport.document(of: Workspace(bodies: [body])).document
        XCTAssertEqual(document.features[1].axis, .nz)
        XCTAssertEqual(document.features[1].z, 10)
        XCTAssertEqual(document.features[3].kind, .polygon)
        XCTAssertEqual(document.features[3].axis, .py)
        XCTAssertEqual(document.features[3].points?.count, 3)
    }

    func testFilletsShellsAndHolesResolveOnTheSolidAtThatStep() throws {
        let proposal = DesignProposal(features: [
            Feature(id: "box", body: "Box", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0, width: 60, depth: 40, height: 20),
            Feature(id: "round", body: "Box", kind: .fillet, edges: "vertical", size: 4),
            Feature(id: "hollow", body: "Box", kind: .shell, faces: ["top"], size: 2),
            Feature(id: "screw", body: "Box", kind: .hole, axis: .nz, x: 0, y: 0, z: 0, height: 2, hole: .init(type: .countersink, size: "M3"))
        ])
        let bench = try applied(proposal).bench
        let body = bench.workspace.bodies[0]
        XCTAssertEqual(body.cuts.map(\.operation), [.finish, .shell, .hole])
        XCTAssertEqual(body.cuts[0].finish?.edges.count, 4, "The four vertical corners of the box as it stood")
        let solid = try SolidKernel.solid(for: body)
        XCTAssertTrue(solid.isValidSolid)
        XCTAssertLessThan(solid.volume, 60 * 40 * 20 - 56 * 36 * 18)
        // Exported back: fillet, shell, and a preset hole; a size-only change keeps the edges.
        let (document, aliases) = DesignExport.document(of: bench.workspace)
        XCTAssertEqual(document.features.map(\.kind), [.block, .fillet, .shell, .hole])
        XCTAssertEqual(document.features[3].hole?.size, "M3")
        XCTAssertEqual(document.features[3].hole?.type, .countersink)
        var smaller = document.features[1]
        smaller.size = 3
        var edited = bench
        try edited.applyDesign(DesignProposal(features: [smaller]), aliases: aliases)
        XCTAssertEqual(edited.workspace.bodies[0].cuts[0].finish?.edges, body.cuts[0].finish?.edges)
        XCTAssertEqual(edited.workspace.bodies[0].cuts[0].finish?.size, 3)
        XCTAssertEqual(edited.workspace.bodies[0].cuts[0].id, body.cuts[0].id)
    }

    func testTransformsMoveWholeSolidsAfterTheirFeatures() throws {
        var proposal = plateProposal()
        proposal.solidOps = [.init(op: .move, bodies: ["Plate"], vector: [100, 0, 0])]
        let bench = try applied(proposal).bench
        let bounds = try SolidKernel.solid(for: bench.workspace.bodies[0]).bounds
        XCTAssertEqual(bounds.min.x, 60, accuracy: 1e-6)
        XCTAssertEqual(bench.changes.count, 2)
    }

    func testMirrorsAndPatternsCopyWholeSolidsAfterTheFeatures() throws {
        // A new plate, mirrored across X = 60 beside itself, then that pair in a row of 2 along +Y.
        var proposal = plateProposal()
        proposal.solidOps = [.init(op: .mirror, bodies: ["Plate"], axis: "x", point: [60, 0, 0], keepInput: true)]
        let mirrored = try applied(proposal).bench
        XCTAssertEqual(mirrored.workspace.bodies.count, 2)
        let image = try SolidKernel.solid(for: mirrored.workspace.bodies[1])
        XCTAssertEqual(image.bounds.min.x, 80, accuracy: 1e-6)
        XCTAssertEqual(image.bounds.max.x, 160, accuracy: 1e-6)
        XCTAssertEqual(image.volume, 19_574.613, accuracy: 0.1)
        XCTAssertTrue(mirrored.changes.last?.hasPrefix("Mirrored Plate across the plane X = 60, keeping the originals") ?? false, "\(mirrored.changes)")

        // Replacing instead: still one solid, now on the other side.
        var replace = plateProposal()
        replace.solidOps = [.init(op: .mirror, bodies: ["Plate"], axis: "y", point: [0, 30, 0])]
        let flipped = try applied(replace).bench.workspace
        XCTAssertEqual(flipped.bodies.count, 1)
        XCTAssertEqual(try SolidKernel.solid(for: flipped.bodies[0]).bounds.min.y, 35, accuracy: 1e-6)

        // A linear grid on an existing solid, and a circular pattern of a post.
        let workspace = try applied(plateProposal()).bench.workspace
        let (_, aliases) = DesignExport.document(of: workspace)
        var grid = AssistantWorkbench(workspace: workspace)
        try grid.applyDesign(DesignProposal(solidOps: [.init(op: .linear, bodies: ["B1"], axis: "x", count: 3, spacing: 90),
                                                       .init(op: .linear, bodies: ["B1"], axis: "y", count: 2, spacing: 60)]), aliases: aliases)
        XCTAssertEqual(grid.workspace.bodies.count, 6)
        XCTAssertEqual(try SolidKernel.solid(for: grid.workspace.bodies.last!).bounds.max.x, 220, accuracy: 1e-6)
        var round = AssistantWorkbench(workspace: Workspace())
        let post = Feature(id: "post", body: "Post", kind: .cylinder, operation: .add, axis: .pz, x: 30, y: 0, z: 0, height: 10, radius: 3)
        try round.applyDesign(DesignProposal(features: [post], solidOps: [.init(op: .circular, bodies: ["Post"], axis: "z", point: [0, 0, 0],
                                                                              count: 6, rotateCopies: true)]), aliases: DesignAliases())
        XCTAssertEqual(round.workspace.bodies.count, 6, "Angle 0 spreads them over a whole turn")
        let centers = try round.workspace.bodies.map { body -> SIMD3<Double> in
            let b = try SolidKernel.solid(for: body).bounds
            return (b.min + b.max) / 2
        }
        XCTAssertEqual(centers.map { simd_length(SIMD2($0.x, $0.y)) }.min() ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(centers[3].x, -30, accuracy: 1e-6)

        // Mistakes say why.
        let bench = AssistantWorkbench(workspace: workspace)
        XCTAssertThrowsError(try bench.applying(DesignProposal(solidOps: [.init(op: .mirror, bodies: ["B9"], axis: "x", keepInput: true)]), aliases: aliases)) { error in
            XCTAssertTrue((error as? AssistantWorkbench.Failure)?.message.contains("not a solid in the design") ?? false, "\(error)")
        }
        XCTAssertThrowsError(try bench.applying(DesignProposal(solidOps: [.init(op: .linear, bodies: ["B1"], axis: "x", count: 1, spacing: 10)]), aliases: aliases))
        // A negative spacing runs toward -X.
        var left = AssistantWorkbench(workspace: workspace)
        try left.applyDesign(DesignProposal(solidOps: [.init(op: .linear, bodies: ["B1"], axis: "x", count: 2, spacing: -90)]), aliases: aliases)
        XCTAssertEqual(try SolidKernel.solid(for: left.workspace.bodies[1]).bounds.min.x, -130, accuracy: 1e-6)
    }

    func testUnionSubtractAndIntersectCombineWholeSolids() throws {
        let base = Feature(id: "base", body: "Base", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 0, width: 40, depth: 40, height: 10)
        let tower = Feature(id: "tower", body: "Tower", kind: .block, operation: .add, axis: .pz, x: 0, y: 0, z: 10, width: 10, depth: 10, height: 20)
        let cutter = Feature(id: "cutter", body: "Cutter", kind: .cylinder, operation: .add, axis: .pz, x: 15, y: 15, z: -1, height: 12, radius: 3)

        // A new tower united into a new base, the tower solid used up.
        let united = try applied(DesignProposal(features: [base, tower], solidOps: [.init(op: .union, bodies: ["Base", "Tower"])])).bench
        XCTAssertEqual(united.workspace.bodies.map(\.name), ["Base"])
        XCTAssertEqual(try volume(united.workspace.bodies[0]), 40 * 40 * 10 + 10 * 10 * 20, accuracy: 1e-6)
        XCTAssertTrue(united.changes.last?.hasPrefix("United Tower into Base") ?? false, "\(united.changes)")

        // A cutter made and subtracted in one proposal; then one kept, with 0.2 mm clearance.
        let cut = try applied(DesignProposal(features: [base, cutter], solidOps: [.init(op: .subtract, bodies: ["Base", "Cutter"])])).bench.workspace
        XCTAssertEqual(cut.bodies.count, 1)
        XCTAssertEqual(try volume(cut.bodies[0]), 16_000 - Double.pi * 9 * 10, accuracy: 0.01)
        let kept = try applied(DesignProposal(features: [base, cutter], solidOps: [.init(op: .subtract, bodies: ["Base", "Cutter"], spacing: 0.2, keepInput: true)])).bench.workspace
        XCTAssertEqual(kept.bodies.count, 2)
        XCTAssertEqual(try volume(kept.bodies[0]), 16_000 - Double.pi * 3.2 * 3.2 * 10, accuracy: 0.01)
        // The target reads back with the subtraction as a locked step after its base.
        let document = DesignExport.document(of: cut).document
        XCTAssertEqual(document.features.map(\.kind), [.block, .locked])
        XCTAssertEqual(document.features[1].note, "another solid subtracted")

        // Intersect keeps only the overlap.
        let overlap = Feature(id: "overlap", body: "Overlap", kind: .block, operation: .add, axis: .pz, x: 20, y: 20, z: 0, width: 40, depth: 40, height: 10)
        let common = try applied(DesignProposal(features: [base, overlap], solidOps: [.init(op: .intersect, bodies: ["Base", "Overlap"])])).bench.workspace
        XCTAssertEqual(common.bodies.count, 1)
        XCTAssertEqual(try volume(common.bodies[0]), 20 * 20 * 10, accuracy: 1e-6)

        // Mistakes say why.
        func message(_ proposal: DesignProposal) -> String {
            do { _ = try applied(proposal); return "applied" } catch { return (error as? AssistantWorkbench.Failure)?.message ?? "\(error)" }
        }
        XCTAssertTrue(message(DesignProposal(features: [base], solidOps: [.init(op: .union, bodies: ["Base"])])).contains("target solid first"))
        let far = Feature(id: "far", body: "Far", kind: .block, operation: .add, axis: .pz, x: 200, y: 0, z: 0, width: 10, depth: 10, height: 10)
        XCTAssertTrue(message(DesignProposal(features: [base, far], solidOps: [.init(op: .subtract, bodies: ["Base", "Far"])])).contains("do not overlap"))
        XCTAssertTrue(message(DesignProposal(features: [base, far], solidOps: [.init(op: .union, bodies: ["Base", "Far"])])).contains("do not touch"))
    }

    func testSchemaIsStrict() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: DesignSchema.data) as? [String: Any])
        func check(_ object: [String: Any], _ path: String) {
            if let properties = object["properties"] as? [String: Any] {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
                XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), path)
                for (key, value) in properties { if let value = value as? [String: Any] { check(value, path + "." + key) } }
            }
            if let items = object["items"] as? [String: Any] { check(items, path + "[]") }
            for choice in object["anyOf"] as? [[String: Any]] ?? [] {
                check(choice, path + "|")
                XCTAssertNil((choice["type"] as? [Any]), "One type per choice: \(path)")
            }
            XCTAssertNil(object["type"] as? [Any], "No type lists, which Claude refuses with an enum: \(path)")
        }
        check(schema, "proposal")
        XCTAssertLessThanOrEqual(DesignSchema.unionCount(), 16, "Claude's limit on nullable fields")
        let features = try XCTUnwrap(((schema["properties"] as? [String: Any])?["features"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(Set((features["properties"] as? [String: Any])?.keys.map { $0 } ?? []),
                       ["id", "body", "kind", "operation", "axis", "x", "y", "z", "width", "depth", "height", "radius", "points",
                        "throughAll", "hole", "edges", "faces", "size", "note"])
    }

    // MARK: The loop

    @MainActor func testAPassingProposalIsUsedOnceAndRepliesWithTheAppsChanges() async throws {
        var requests: [DesignPlannerRequest] = []
        let text = json(plateProposal())
        let result = try await DesignHarness.perform(request: "Make an 80 × 50 × 5 mm plate with four holes", workspace: Workspace(), selection: nil) { request in
            requests.append(request)
            return DesignPlannerReply(text: text, model: "fixture")
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].isCorrection)
        XCTAssertTrue(requests[0].input.contains("Design document:\nBlank"), requests[0].input)
        XCTAssertEqual(requests[0].schemaName, "design_proposal")
        XCTAssertFalse(result.handOff)
        XCTAssertEqual(result.attempts.count, 1)
        XCTAssertTrue(result.attempts[0].passed)
        XCTAssertEqual(result.bench.workspace.bodies.count, 1)
        XCTAssertTrue(result.reply.hasPrefix("New Plate:"), result.reply)
    }

    @MainActor func testAFailedProposalGetsOneCorrectionFromTheSameStart() async throws {
        var bad = plateProposal()
        bad.features[3].radius = 8 // breaks out through the corner of the plate
        bad.requirements = [.init(quote: "80 × 50 × 5 mm plate", kind: "bodySize", target: "Plate", expected: [80, 50, 5])]
        var tall = plateProposal()
        tall.features[0].height = 6
        tall.requirements = bad.requirements
        var good = plateProposal()
        good.requirements = bad.requirements
        var replies = [json(tall), json(good)], requests: [DesignPlannerRequest] = []
        let result = try await DesignHarness.perform(request: "Make an 80 × 50 × 5 mm plate with four holes", workspace: Workspace(), selection: nil) { request in
            requests.append(request)
            return DesignPlannerReply(text: replies.removeFirst())
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].isCorrection)
        XCTAssertTrue(requests[1].input.hasPrefix(requests[0].input), "The same start and request")
        XCTAssertTrue(requests[1].input.contains("Your previous attempt is below."), requests[1].input)
        XCTAssertTrue(requests[1].input.contains("Unmet \\\"80 × 50 × 5 mm plate\\\""), requests[1].input)
        XCTAssertTrue(result.corrected)
        XCTAssertEqual(result.bench.workspace.bodies.count, 1, "Applied once, from the original start")
        XCTAssertEqual(try volume(result.bench.workspace.bodies[0]), 19_574.613, accuracy: 0.1)
        XCTAssertEqual(result.requirements.results.map(\.status), [.passed])
        _ = bad
    }

    @MainActor func testTwoFailuresLeaveTheDesignAsItWas() async throws {
        let start = try applied(plateProposal()).bench.workspace
        let broken = DesignProposal(features: [Feature(id: "B1.F2", body: "B1", kind: .cylinder, operation: .cut, axis: .pz, x: -34, y: -19, z: 0, height: 5, radius: -1)])
        var count = 0
        let result = try await DesignHarness.perform(request: "Make the hole bigger", workspace: start, selection: nil) { _ in
            count += 1
            return DesignPlannerReply(text: self.json(broken))
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result.bench.workspace, start)
        XCTAssertFalse(result.bench.hasChanges)
        XCTAssertTrue(result.reply.hasPrefix("That change did not work out"), result.reply)
        XCTAssertTrue(result.reply.contains("radius"), result.reply)
    }

    @MainActor func testAnswersHandOffsAndUnreadableRepliesChangeNothing() async throws {
        let start = try applied(plateProposal()).bench.workspace
        let answer = try await DesignHarness.perform(request: "How thick is it?", workspace: start, selection: nil) { _ in
            DesignPlannerReply(text: self.json(DesignProposal(intent: .answer, message: "5 mm.")))
        }
        XCTAssertEqual(answer.reply, "5 mm.")
        XCTAssertFalse(answer.bench.hasChanges)
        let handOff = try await DesignHarness.perform(request: "Add an M6 thread", workspace: start, selection: nil) { _ in
            DesignPlannerReply(text: self.json(DesignProposal(intent: .handOff)))
        }
        XCTAssertTrue(handOff.handOff)
        var calls = 0
        do {
            _ = try await DesignHarness.perform(request: "Make it bigger", workspace: start, selection: nil) { _ in
                calls += 1
                return DesignPlannerReply(text: "I can't do that")
            }
            XCTFail("An unreadable reply is an error")
        } catch let failure as AssistantWorkbench.Failure {
            XCTAssertTrue(failure.message.contains("could not be read"), failure.message)
        }
        XCTAssertEqual(calls, 1, "Nothing to correct")
    }

    @MainActor func testTheSelectionIsDescribedByAlias() async throws {
        let start = try applied(plateProposal()).bench.workspace
        var input = ""
        _ = try await DesignHarness.perform(request: "Round it", workspace: start, selection: .body(start.bodies[0].id)) { request in
            input = request.input
            return DesignPlannerReply(text: self.json(DesignProposal(intent: .answer, message: "Which edges?")))
        }
        XCTAssertTrue(input.contains("Selected: solid B1 (Plate)"), input)
        XCTAssertTrue(input.contains("\"id\":\"B1.F1\""), input)
    }
}

private extension AssistantWorkbench {
    /// Applies `proposal` to a copy, for checking what it throws.
    func applying(_ proposal: DesignProposal, aliases: DesignAliases) throws -> AssistantWorkbench {
        var copy = self
        try copy.applyDesign(proposal, aliases: aliases)
        return copy
    }
}
