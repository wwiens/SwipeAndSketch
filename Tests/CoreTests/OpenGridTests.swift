import XCTest
import simd
@testable import SwipeAndSketchCore

/// openGrid against its official files (Tests/Fixtures/OpenGrid): the boards rebuilt in code are
/// the same solids, and the stored parts are the files' own.
final class OpenGridTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/OpenGrid")

    static func official(_ file: String) throws -> KernelSolid {
        let solids = try SolidKernel.importSTEP(at: fixtures.appending(path: file)).solids
        XCTAssertEqual(solids.count, 1, file)
        return solids[0]
    }

    /// A part's file solid, centered as stored: a screw snap on its screw axis, the rest on their bounds.
    static func centered(_ part: OpenGridPart) throws -> KernelSolid {
        let solid = try official(part.sourceFile)
        let axis: SIMD3<Double>? = switch part {
        case .screwSnap: .zero
        case .directionalScrewSnap: SIMD3(0, 56, 0)
        case .liteScrewSnap: SIMD3(0, 84, 0)
        case .liteDirectionalScrewSnap: SIMD3(0, 112, 0)
        default: nil
        }
        let b = solid.bounds, center = axis ?? SIMD3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, 0)
        return try Kernel.moved(solid, by: -SIMD3(center.x, center.y, 0))
    }

    /// Volume in one and not the other, both ways, in mm³.
    static func difference(_ a: KernelSolid, _ b: KernelSolid) throws -> (extra: Double, missing: Double) {
        (try Kernel.boolean(a, b, .subtract).volume, try Kernel.boolean(b, a, .subtract).volume)
    }

    func testBoardsMatchTheOfficialFiles() throws {
        for (file, columns, rows, type) in [("openGrid 2x2.step", 2, 2, OpenGrid.BoardType.full), ("openGrid 3x2.step", 2, 3, .full),
                                            ("openGrid Lite 2x2.step", 2, 2, .lite), ("openGrid Lite 3x2.step", 2, 3, .lite)] {
            let file = try Self.official(file)
            let b = file.bounds, center = (b.min + b.max) / 2
            let official = try Kernel.moved(file, by: SIMD3(-center.x, -center.y, 0))
            let board = try OpenGrid.board(columns: columns, rows: rows, type: type)
            XCTAssertTrue(board.isValidSolid)
            XCTAssertEqual(board.volume, official.volume, accuracy: 1e-4, "\(file)")
            let difference = try Self.difference(board, official)
            XCTAssertEqual(difference.extra, 0, accuracy: 1e-4, "\(file)")
            XCTAssertEqual(difference.missing, 0, accuracy: 1e-4, "\(file)")
        }
    }

    func testPartsMatchTheOfficialFiles() throws {
        for part in OpenGridPart.allCases {
            let stored = try SolidKernel.shape(from: try part.shape.data)
            let official = try Self.centered(part)
            XCTAssertTrue(stored.isValidSolid, "\(part)")
            XCTAssertEqual(stored.volume, official.volume, accuracy: 1e-6, "\(part)")
            let difference = try Self.difference(stored, official)
            XCTAssertEqual(difference.extra, 0, accuracy: 1e-6, "\(part)")
            XCTAssertEqual(difference.missing, 0, accuracy: 1e-6, "\(part)")
        }
    }

    static func template(_ id: String, _ changes: [String: Double] = [:]) throws -> (ProjectTemplate, Workspace) {
        let template = try XCTUnwrap(TemplateCatalog.template(id))
        var values = template.defaults
        for (key, value) in changes { values[key] = value }
        return (template, try template.workspace(values))
    }

    /// The free templates hand out openGrid's own parts, each shape stored once in the project.
    func testTheTemplatesShipTheOfficialParts() throws {
        let cases: [(String, [String: Double], [OpenGridPart])] = [
            ("opengrid.connector-pegs", [:], [.connector]), ("opengrid.connector-pegs", ["board": 1], [.liteConnector]),
            ("opengrid.mounting-snaps", [:], [.wallMount]), ("opengrid.mounting-snaps", ["board": 1], [.liteWallMount]),
            ("opengrid.mounting-snaps", ["style": 1], [.openWallMount, .openWallMountCover]),
            ("opengrid.screw-snaps", ["family": 0], [.screwSnap]), ("opengrid.screw-snaps", [:], [.directionalScrewSnap]),
            ("opengrid.screw-snaps", ["board": 1, "family": 0], [.liteScrewSnap]), ("opengrid.screw-snaps", ["board": 1], [.liteDirectionalScrewSnap])
        ]
        for (id, changes, parts) in cases {
            let (template, workspace) = try Self.template(id, changes)
            let label = "\(id) \(changes)"
            XCTAssertEqual(Set(workspace.importedShapes.map(\.id)), Set(try parts.map { try $0.shape.id }), label)
            let volumes = try parts.map { try SolidKernel.shape(from: try $0.shape.data).volume }
            let count = template.defaults.count("count")
            XCTAssertEqual(workspace.bodies.count, count * parts.count, label)
            var solids: [KernelSolid] = []
            for body in workspace.bodies {
                let solid = try SolidKernel.solid(for: body)
                XCTAssertTrue(volumes.contains { abs($0 - solid.volume) < 1e-6 }, label)
                // Laid out apart on the bed.
                for other in solids { XCTAssertEqual(try Kernel.boolean(solid, other, .intersect).volume, 0, accuracy: 1e-9, label) }
                XCTAssertEqual(solid.bounds.min.z, 0, accuracy: 0.81, label)
                solids.append(solid)
            }
            let project = Project(workspace: workspace)
            let reopened = try ProjectCodec.decode(try ProjectCodec.encode(project)).workspace
            XCTAssertEqual(reopened.importedShapes.count, parts.count, label)
        }
    }

    func testBoardOptions() throws {
        let full = try SolidKernel.solid(for: try Self.template("opengrid.board", ["columns": 2, "rows": 2]).1.bodies[0])
        let official = try Self.official("openGrid 2x2.step")
        XCTAssertEqual(full.volume, official.volume, accuracy: 1e-4)
        // Each edge's pockets go with its toggle: a 2 × 2 board has one per edge.
        let pocket = try OpenGrid.connectorTool(.full).volume
        let closed = try SolidKernel.solid(for: try Self.template("opengrid.board", ["columns": 2, "rows": 2, "pocketsTop": 0, "pocketsLeft": 0]).1.bodies[0])
        XCTAssertEqual(closed.volume - full.volume, 2 * pocket, accuracy: 1e-3)
        // Lite screw holes: one per inner grid corner, none on a board one cell wide.
        let lite = try Self.template("opengrid.board", ["board": 1])
        var values = lite.0.defaults
        values["board"] = 1
        XCTAssertEqual(OpenGridTemplates.BoardLayout(values).holeCount, 25)
        let plain = try SolidKernel.solid(for: try Self.template("opengrid.board", ["board": 1, "screwHoles": 0]).1.bodies[0])
        let holes = try SolidKernel.solid(for: lite.1.bodies[0])
        XCTAssertEqual(plain.volume - holes.volume, 25 * (try OpenGrid.screwTool().volume - .pi * 3.6 * 3.6 - .pi * 2.05 * 2.05), accuracy: 1)
        values["columns"] = 1
        XCTAssertEqual(OpenGridTemplates.BoardLayout(values).holeCount, 0)
        // The shapes keep one id for one set of options, so previews and projects share them.
        XCTAssertEqual(try Self.template("opengrid.board").1.importedShapes[0].id, try Self.template("opengrid.board").1.importedShapes[0].id)
        XCTAssertNotEqual(try Self.template("opengrid.board").1.importedShapes[0].id, try Self.template("opengrid.board", ["pocketsTop": 0]).1.importedShapes[0].id)
    }

    func testFitTestPairsABoardCellWithAFinishedSnap() throws {
        for type in [0.0, 1] {
            let workspace = try Self.template("opengrid.fit-test", ["board": type]).1
            XCTAssertEqual(workspace.bodies.map(\.name), ["Board Sample", "Test Snap"])
            let sample = try SolidKernel.solid(for: workspace.bodies[0]), snap = try SolidKernel.solid(for: workspace.bodies[1])
            let thickness = type == 0 ? 6.8 : 4.0
            XCTAssertEqual(sample.volume, try OpenGrid.board(columns: 1, rows: 1, type: type == 0 ? .full : .lite).volume, accuracy: 1e-6)
            XCTAssertEqual(sample.bounds.max.z - sample.bounds.min.z, thickness, accuracy: 1e-6)
            XCTAssertEqual(try Kernel.boolean(sample, snap, .intersect).volume, 0, accuracy: 1e-9)
        }
    }

    /// The screws reach into the snap's nut and stay inside the snap, with 2 mm under the head.
    func testScrewLengthsReachTheNut() throws {
        for type in OpenGrid.BoardType.allCases {
            for plate in stride(from: 3.0, through: 8, by: 0.5) {
                let screws = SnapScrews(type: type, plate: plate)
                let (length, recess) = try screws.screw()
                let tip = length - (plate - recess)
                XCTAssertGreaterThanOrEqual(tip, screws.snapDepth - 0.8 - 1e-9, "\(type) \(plate)")
                XCTAssertLessThanOrEqual(tip, screws.snapDepth + 1e-9, "\(type) \(plate)")
                XCTAssertGreaterThanOrEqual(plate - recess, 2 - 1e-9, "\(type) \(plate)")
                XCTAssertTrue(SnapScrews.lengths.contains(length))
            }
        }
        XCTAssertEqual(try SnapScrews(type: .full, plate: 5).screw().length, 10)
        XCTAssertEqual(try SnapScrews(type: .full, plate: 5).screw().recess, 1, accuracy: 1e-9)
        XCTAssertEqual(try SnapScrews(type: .lite, plate: 5).screw().length, 8)
    }

    /// Every accessory's screws are whole cells apart, open right through, and reachable from the
    /// front: nothing of the accessory in front of a screw for 60 mm.
    func testAccessoryScrewsSitOnTheGridWithRoomForADriver() throws {
        let ids = ["opengrid.mounting-plate", "opengrid.hook", "opengrid.shelf", "opengrid.bin", "opengrid.cable-guide", "opengrid.cable-tray",
                   "opengrid.tool-rack", "opengrid.gridfinity-shelf"]
        for id in ids {
            for changes in [[:], ["board": 1.0]] {
                let (template, workspace) = try Self.template(id, changes)
                XCTAssertTrue(template.needsPro, id)
                XCTAssertTrue(workspace.importedShapes.isEmpty, "\(id) leaves the snaps to the free set")
                let body = try XCTUnwrap(workspace.bodies.first)
                let solid = try SolidKernel.solid(for: body)
                let holes = body.cuts.filter { $0.hole != nil }
                XCTAssertGreaterThanOrEqual(holes.count, 2, id)
                let normal = holes[0].profile.plane.normalAxis
                let centers = holes.map { $0.profile.plane.point($0.profile.circle!.center) }
                for center in centers {
                    for other in centers {
                        var offset = other - center
                        offset -= simd_dot(offset, normal) * normal
                        for axis in [offset.x, offset.y, offset.z] {
                            XCTAssertEqual(axis / OpenGrid.pitch, (axis / OpenGrid.pitch).rounded(), accuracy: 1e-9, "\(id): screws off the grid")
                        }
                    }
                    for step in stride(from: 0.5, through: 60, by: 0.5) {
                        XCTAssertFalse(solid.contains(center + step * normal), "\(id): in front of a screw at \(step) mm")
                    }
                    XCTAssertFalse(solid.contains(center - 1 * normal), "\(id): the hole is closed")
                }
            }
        }
    }

    /// The tool rack's openings and the cable tray's tie slots go right through.
    func testRackOpeningsAndTieSlotsAreCut() throws {
        let (rackTemplate, rackWorkspace) = try Self.template("opengrid.tool-rack")
        let rack = try SolidKernel.solid(for: rackWorkspace.bodies[0]), values = rackTemplate.defaults
        let tools = values.count("tools"), y = OpenGridTemplates.backing + values["projection"] / 2
        for index in 0..<tools {
            let x = (Double(index) - Double(tools - 1) / 2) * values["pitch"]
            XCTAssertFalse(rack.contains(SIMD3(x, y, values["support"] / 2)), "opening \(index)")
            XCTAssertTrue(rack.contains(SIMD3(x + values["shaft"] / 2 + values["fit"] + 1, y, values["support"] / 2)), "rim \(index)")
        }
        let (trayTemplate, trayWorkspace) = try Self.template("opengrid.cable-tray")
        let tray = try SolidKernel.solid(for: trayWorkspace.bodies[0]), t = trayTemplate.defaults
        let spacing = t["length"] / Double(t.count("slots"))
        for index in 0..<t.count("slots") {
            let x = -t["length"] / 2 + (Double(index) + 0.5) * spacing
            for slot in [0.3, 0.7] {
                XCTAssertFalse(tray.contains(SIMD3(x, OpenGridTemplates.backing + t["projection"] * slot, t["wall"] / 2)), "slot \(index)")
            }
            XCTAssertTrue(tray.contains(SIMD3(x, OpenGridTemplates.backing + t["projection"] * 0.5, t["wall"] / 2)), "the bar a tie wraps \(index)")
        }
    }

    /// The Gridfinity Shelf holds the free Baseplate's pockets exactly, on a floor, with nothing
    /// else in them, so bins seat and lift out as on the baseplate.
    func testGridfinityShelfHasTheBaseplatesPockets() throws {
        let (template, workspace) = try Self.template("opengrid.gridfinity-shelf")
        let values = template.defaults
        let shelf = try SolidKernel.solid(for: workspace.bodies[0])
        let deck = values["deck"], columns = values.count("columns"), rows = values.count("rows")
        let plate = try XCTUnwrap(try Gridfinity.plate(columns: columns, rows: rows, magnets: false)
            .transformed(by: .move(SIMD3(0, OpenGridTemplates.backing + Double(rows) * Gridfinity.pitch / 2, deck))))
        let baseplate = try SolidKernel.solid(for: plate)
        XCTAssertEqual(try Kernel.boolean(baseplate, shelf, .subtract).volume, 0, accuracy: 1e-6)
        let region = try SolidKernel.extrude(TemplateGeometry.roundedRectangle(center: Point2(x: 0, y: OpenGridTemplates.backing + Double(rows) * Gridfinity.pitch / 2),
                                                                               width: Double(columns) * Gridfinity.pitch - 1, depth: Double(rows) * Gridfinity.pitch - 1, radius: 0,
                                                                               on: TemplateGeometry.horizontal(deck)), depth: 30)
        let inShelf = try Kernel.boolean(shelf, region, .intersect).volume, inPlate = try Kernel.boolean(baseplate, region, .intersect).volume
        XCTAssertEqual(inShelf, inPlate, accuracy: 1e-6)
        // A supported floor under every pocket.
        for cell in Gridfinity.cellCenters(columns: columns, rows: rows) {
            XCTAssertTrue(shelf.contains(SIMD3(cell.x, cell.y + OpenGridTemplates.backing + Double(rows) * Gridfinity.pitch / 2, deck / 2)))
        }
    }

    /// Scripts/update_opengrid_parts.sh runs this to write OpenGridPartData.swift.
    func testWritePartData() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENGRID_WRITE_PARTS"] else { throw XCTSkip("Run Scripts/update_opengrid_parts.sh") }
        var source = """
        // Written by Scripts/update_opengrid_parts.sh from Tests/Fixtures/OpenGrid. Do not edit.
        // openGrid by David D, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/): the official
        // parts' solids, each moved to center it on the origin and otherwise unchanged, as LZFSE-compressed
        // OCCT binary B-rep, base64.
        enum OpenGridPartData {
            static let shapes: [OpenGridPart: String] = [

        """
        for part in OpenGridPart.allCases {
            let data = try Self.centered(part).shapeData()
            let packed = try (data as NSData).compressed(using: .lzfse) as Data
            source += "        .\(part.rawValue): \"\(packed.base64EncodedString())\",\n"
        }
        source += "    ]\n}\n"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
