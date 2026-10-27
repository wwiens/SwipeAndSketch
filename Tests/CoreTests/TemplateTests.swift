import XCTest
import simd
@testable import SwipeAndSketchCore

final class TemplateTests: XCTestCase {
    /// Builds every solid of a workspace, checking each is one valid solid.
    @discardableResult
    private func build(_ workspace: Workspace, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> [KernelSolid] {
        XCTAssertTrue(workspace.isValid, "\(label): invalid workspace", file: file, line: line)
        return try workspace.bodies.map { body in
            XCTAssertTrue(body.isValid, "\(label): invalid \(body.name ?? "solid")", file: file, line: line)
            let solid = try SolidKernel.solid(for: body)
            XCTAssertTrue(solid.isValidSolid, "\(label): \(body.name ?? "solid") is not one valid solid", file: file, line: line)
            return solid
        }
    }

    /// The area of `solid`'s cross-section between heights `z` and `z + 0.1` (straight walls there).
    private func area(_ solid: KernelSolid, at z: Double) throws -> Double {
        let plane = TemplateGeometry.horizontal(z)
        let slab = try SolidKernel.extrude(TemplateGeometry.roundedRectangle(width: 2_000, depth: 2_000, radius: 0, on: plane), depth: 0.1)
        return try SolidKernel.boolean(solid, slab, .intersect).volume / 0.1
    }

    private func roundedSquareArea(_ width: Double, _ depth: Double, radius r: Double) -> Double { width * depth - (4 - .pi) * r * r }

    func testCatalogIsWellFormed() {
        let templates = TemplateCatalog.all
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count, "template ids repeat")
        for category in ProjectTemplate.Category.allCases {
            XCTAssertFalse(templates.filter { $0.category == category }.isEmpty, "\(category) has no templates")
        }
        for template in templates {
            XCTAssertEqual(Set(template.parameters.map(\.id)).count, template.parameters.count, "\(template.id): parameter ids repeat")
            for parameter in template.parameters {
                XCTAssertEqual(parameter.clamped(parameter.defaultValue), parameter.defaultValue, "\(template.id).\(parameter.id): default out of range")
            }
            XCTAssertFalse(template.summary.isEmpty)
        }
    }

    func testEveryTemplateMakesNamedSolidsInAGroupThatSave() throws {
        for template in TemplateCatalog.all {
            let workspace = try template.workspace(template.defaults)
            try build(workspace, template.id)
            XCTAssertEqual(workspace.groups.count, 1)
            XCTAssertEqual(workspace.groups.first?.name, template.name(template.defaults))
            XCTAssertTrue(workspace.bodies.allSatisfy { $0.group == workspace.groups[0].id && $0.name != nil })
            let project = Project(workspace: workspace)
            XCTAssertEqual(try ProjectCodec.decode(try ProjectCodec.encode(project)).workspace, workspace, template.id)
        }
    }

    /// Each size and choice at its ends, the others at their defaults.
    func testEveryTemplateBuildsAcrossItsRanges() throws {
        for template in TemplateCatalog.all {
            for parameter in template.parameters {
                let ends: [Double]
                switch parameter.kind {
                case .count(let range): ends = [Double(range.lowerBound), Double(range.upperBound)]
                case .length(let range, _): ends = [range.lowerBound, range.upperBound]
                case .choice(let options): ends = options.indices.map(Double.init)
                case .toggle: ends = [0, 1]
                }
                for end in ends where end != parameter.defaultValue {
                    var values = template.defaults
                    values[parameter.id] = end
                    // Gridfinity's largest grids are covered by testLargestGridfinityBuildsQuickly.
                    if template.category == .gridfinity, ["columns", "rows"].contains(parameter.id), end > 4 { continue }
                    let label = "\(template.id) \(parameter.id)=\(end)"
                    do { try build(try template.workspace(values), label) } catch let error as TemplateError {
                        // Too many dividers for the default bin's size is reported, not built.
                        if case .tooSmall = error, template.category == .gridfinity, parameter.id.hasPrefix("dividers") { continue }
                        XCTFail("\(label): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// The gallery's pictures show what each template makes now. When this fails, a template was
    /// added or changed: run Scripts/render_template_pictures.sh to draw its picture again.
    func testGalleryPicturesAreCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recorded = try JSONDecoder().decode([String: String].self,
                                                from: Data(contentsOf: root.appending(path: "Tests/Fixtures/TemplatePictures.json")))
        for template in TemplateCatalog.all {
            let picture = root.appending(path: "SwipeAndSketch/Assets.xcassets/Templates/\(template.pictureName).imageset/picture.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path()), "\(template.id) has no gallery picture; run Scripts/render_template_pictures.sh")
            XCTAssertEqual(recorded[template.id], try template.pictureFingerprint(),
                           "\(template.id) has changed since its gallery picture was drawn; run Scripts/render_template_pictures.sh")
        }
        XCTAssertEqual(Set(recorded.keys), Set(TemplateCatalog.all.map(\.id)), "Pictures of removed templates; run Scripts/render_template_pictures.sh")
    }

    func testValuesAreClampedIntoRange() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("gridfinity.bin"))
        var values = template.defaults
        values["columns"] = 40
        values["height"] = -3
        values["magnets"] = 9
        values["lip"] = 0.2
        let clamped = template.clamped(values)
        XCTAssertEqual(clamped.count("columns"), 8)
        XCTAssertEqual(clamped.count("height"), 2)
        XCTAssertEqual(clamped.choice("magnets"), 2)
        XCTAssertFalse(clamped.flag("lip"))
    }

    // MARK: Gridfinity

    func testGridfinityBinFollowsTheSpecification() throws {
        let solid = try SolidKernel.solid(for: try Gridfinity.bin(columns: 1, rows: 1, height: 3, dividers: (0, 0), lip: true, magnets: 0))
        XCTAssertTrue(solid.isValidSolid)
        let b = solid.bounds
        XCTAssertEqual(b.max.x - b.min.x, 41.5, accuracy: 1e-6)
        XCTAssertEqual(b.max.y - b.min.y, 41.5, accuracy: 1e-6)
        XCTAssertEqual(b.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(b.max.z, 21 + 4.2, accuracy: 1e-6)
        // The foot: 35.6 mm square (0.8 mm corners) at the bottom, 37.2 mm (1.6 mm corners) up its straight part.
        XCTAssertEqual(try area(solid, at: 0), roundedSquareArea(35.7, 35.7, radius: 0.85), accuracy: 0.05)
        XCTAssertEqual(try area(solid, at: 1.5), roundedSquareArea(37.2, 37.2, radius: 1.6), accuracy: 0.05)
        // Above the foot the full outline, and a floor at 6 mm.
        XCTAssertEqual(try area(solid, at: 5), roundedSquareArea(41.5, 41.5, radius: 3.75), accuracy: 0.05)
        // The walls, 1.2 mm thick.
        let walls = roundedSquareArea(41.5, 41.5, radius: 3.75) - roundedSquareArea(39.1, 39.1, radius: 2.55)
        XCTAssertEqual(try area(solid, at: 10), walls, accuracy: 0.05)
        // The lip's straight part: open to 37.7 mm (1.85 mm corners), so a foot above seats in it.
        XCTAssertEqual(try area(solid, at: 21 + 1), roundedSquareArea(41.5, 41.5, radius: 3.75) - roundedSquareArea(37.7, 37.7, radius: 1.85), accuracy: 0.05)
    }

    func testGridfinityBinsSitSideBySideOnTheGrid() throws {
        let solid = try SolidKernel.solid(for: try Gridfinity.bin(columns: 3, rows: 2, height: 4, dividers: (0, 0), lip: false, magnets: 0))
        XCTAssertEqual(solid.bounds.max.x - solid.bounds.min.x, 3 * 42 - 0.5, accuracy: 1e-6)
        XCTAssertEqual(solid.bounds.max.y - solid.bounds.min.y, 2 * 42 - 0.5, accuracy: 1e-6)
        XCTAssertEqual(solid.bounds.max.z, 28, accuracy: 1e-6)
        // Six separate feet.
        XCTAssertEqual(try area(solid, at: 1.5), 6 * roundedSquareArea(37.2, 37.2, radius: 1.6), accuracy: 0.2)
    }

    func testGridfinityMagnetPockets() throws {
        let plain = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 2, height: 3, dividers: (0, 0), lip: false, magnets: 0))
        let pocket = Double.pi * 3.25 * 3.25 * 2.4
        let every = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 2, height: 3, dividers: (0, 0), lip: false, magnets: 2))
        XCTAssertEqual(plain.volume - every.volume, 16 * pocket, accuracy: 0.5)
        let corners = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 2, height: 3, dividers: (0, 0), lip: false, magnets: 1))
        XCTAssertEqual(plain.volume - corners.volume, 4 * pocket, accuracy: 0.5)
        // Pockets open on the bottom, 13 mm from each cell's center.
        XCTAssertNotNil(corners.face(near: SIMD3(-21 - 13 - 3.25, -21 - 13, 1)))
    }

    func testGridfinityDividersMakeCompartments() throws {
        let open = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 1, height: 4, dividers: (0, 0), lip: false, magnets: 0))
        let divided = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 1, height: 4, dividers: (2, 1), lip: false, magnets: 0))
        XCTAssertTrue(divided.isValidSolid)
        // Two walls across and one along, 1.2 mm thick, standing 22 mm on the floor (less their
        // crossings), with 0.8 mm rounds in the corners where they cross (those where they meet a
        // wall are mostly inside it).
        let inner = (width: 2 * 42 - 0.5 - 2.4, depth: 42 - 0.5 - 2.4)
        let walls = (2 * inner.depth + inner.width - 2 * 1.2) * 1.2 * 22 + 8 * (4 - .pi) / 4 * 0.64 * 22
        XCTAssertEqual(divided.volume - open.volume, walls, accuracy: 10)
    }

    func testGridfinityBaseplateFollowsTheSpecification() throws {
        let solid = try SolidKernel.solid(for: try Gridfinity.plate(columns: 3, rows: 2, magnets: false))
        XCTAssertTrue(solid.isValidSolid)
        let b = solid.bounds
        XCTAssertEqual(b.max.x - b.min.x, 126, accuracy: 1e-6)
        XCTAssertEqual(b.max.y - b.min.y, 84, accuracy: 1e-6)
        XCTAssertEqual(b.max.z, 4.45, accuracy: 1e-6)
        // Pockets 37.7 mm across (1.85 mm corners) up their straight part.
        let plate = roundedSquareArea(126, 84, radius: 4)
        XCTAssertEqual(try area(solid, at: 1.5), plate - 6 * roundedSquareArea(37.7, 37.7, radius: 1.85), accuracy: 0.2)
        // Open underneath: 36.3 mm (1.15 mm corners) at the bottom.
        XCTAssertEqual(try area(solid, at: 0), plate - 6 * roundedSquareArea(36.4, 36.4, radius: 1.2), accuracy: 0.2)

        let magnets = try SolidKernel.solid(for: try Gridfinity.plate(columns: 2, rows: 1, magnets: true))
        XCTAssertTrue(magnets.isValidSolid)
        XCTAssertEqual(magnets.bounds.max.z, 3.2 + 4.45, accuracy: 1e-6)
        // A floor under the pockets, with eight magnet pockets in it.
        let floor = roundedSquareArea(84, 42, radius: 4)
        XCTAssertEqual(try area(magnets, at: 0.3), floor, accuracy: 0.05)
        XCTAssertEqual(try area(magnets, at: 2), floor - 8 * .pi * 3.25 * 3.25, accuracy: 0.2)
    }

    func testLargestGridfinityBuildsQuickly() throws {
        let start = Date()
        try build(try XCTUnwrap(TemplateCatalog.template("gridfinity.bin")).workspace(
            TemplateValues(values: ["columns": 8, "rows": 8, "height": 6, "dividersX": 7, "dividersY": 7, "lip": 1, "magnets": 2])), "8 × 8 bin")
        try build(try XCTUnwrap(TemplateCatalog.template("gridfinity.magnet-baseplate")).workspace(
            TemplateValues(values: ["columns": 8, "rows": 8, "magnets": 1])), "8 × 8 plate")
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    // MARK: Electronics

    /// The axis of the round hole at world (x, y) near height z, and its radius.
    private func hole(in solid: KernelSolid, at point: Point2, z: Double, radius: Double) -> Double? {
        guard let face = solid.face(near: SIMD3(point.x + radius, point.y, z), tolerance: 1e-3),
              let cylinder = solid.faceCylinder(face) else { return nil }
        let offset = SIMD2(cylinder.point.x - point.x, cylinder.point.y - point.y)
        XCTAssertLessThan(simd_length(offset), 1e-6, "hole is off its board hole")
        return cylinder.radius
    }

    func testRaspberryPiMountHasStandoffsOnTheBoardsHoles() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("electronics.pi-mount"))
        let workspace = try template.workspace(template.defaults)
        let solid = try XCTUnwrap(try build(workspace, "pi mount").first)
        // 58 × 49 mm pattern, 3.5 mm in from the board's corners away from its USB and Ethernet end (the
        // board centered); M2.5 pilot holes (2.1 mm) in standoffs 5 mm tall on a 3 mm plate.
        for x in [-39.0, 19] { for y in [-24.5, 24.5] {
            XCTAssertEqual(hole(in: solid, at: Point2(x: x, y: y), z: 6, radius: 1.05) ?? 0, 1.05, accuracy: 1e-6)
        } }
        XCTAssertEqual(solid.bounds.max.z, 8, accuracy: 1e-6)
        XCTAssertEqual(solid.bounds.max.x - solid.bounds.min.x, 85 + 16, accuracy: 1e-6)
        XCTAssertEqual(workspace.groups.first?.name, "Mount for Raspberry Pi")
    }

    /// Other makers' boards are named only after "for" (Raspberry Pi's and Arduino's trademark
    /// rules), with their notices beside the templates; Gridfinity's creator is credited.
    func testBoardNamesFollowTheirMakersTrademarkRules() throws {
        let marks = ["Raspberry", "Pi ", "Pico", "Arduino"]
        for template in TemplateCatalog.all where template.category == .electronics {
            XCTAssertFalse(marks.contains { template.title.hasPrefix($0) }, template.title)
            for board in 0...BoardFootprint.catalog.count {
                var values = template.defaults
                values["board"] = Double(board)
                let name = template.name(values)
                XCTAssertFalse(marks.contains { name.hasPrefix($0) }, name)
                if board < BoardFootprint.catalog.count { XCTAssertTrue(name.contains(" for "), name) }
            }
        }
        XCTAssertEqual(BoardFootprint.piZero.named("Case"), "Case for Raspberry Pi Zero")
        XCTAssertEqual(BoardFootprint.custom(width: 70, length: 50, inset: 3.5, screw: "M3").named("Case"), "Board Case")
        let notice = try XCTUnwrap(ProjectTemplate.Category.electronics.notice)
        XCTAssertTrue(notice.contains("Raspberry Pi is a trademark of Raspberry Pi Ltd.") && notice.contains("Arduino® is a trademark of Arduino S.r.l."))
        XCTAssertTrue(ProjectTemplate.Category.gridfinity.notice?.contains("Zack Freedman") == true)
    }

    func testPicoAndArduinoHolePatterns() throws {
        let pico = try TemplateDefaults.solid("electronics.pico-mount")
        for (x, y) in [(-23.5, -5.7), (23.5, -5.7), (23.5, 5.7), (-23.5, 5.7)] {
            XCTAssertEqual(hole(in: pico, at: Point2(x: x, y: y), z: 6, radius: 0.85) ?? 0, 0.85, accuracy: 1e-6)
        }
        let uno = try TemplateDefaults.solid("electronics.arduino-mount")
        let board = BoardFootprint.arduinoUno
        for point in board.holes {
            let world = point - Point2(x: board.width / 2, y: board.length / 2)
            XCTAssertEqual(hole(in: uno, at: world, z: 6, radius: 1.3) ?? 0, 1.3, accuracy: 1e-6)
        }
    }

    func testCustomBoardCaseUsesItsSizes() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("electronics.custom-case"))
        var values = template.defaults
        values["boardWidth"] = 100
        values["boardLength"] = 60
        values["holeInset"] = 4
        values["screw"] = 2
        values["fixing"] = Double(Screws.Fixing.insert.rawValue)
        let workspace = try template.workspace(values)
        let solids = try build(workspace, "custom case")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Case", "Lid"])
        // Inside: the board plus 2 mm all round; 2 mm walls.
        let caseBounds = solids[0].bounds
        XCTAssertEqual(caseBounds.max.x - caseBounds.min.x, 100 + 4 + 4, accuracy: 1e-6)
        XCTAssertEqual(caseBounds.max.y - caseBounds.min.y, 60 + 4 + 4, accuracy: 1e-6)
        // M3 heat-set insert holes, 4 mm from the board's corners.
        let center = BoxTemplates.layout(outerWidth: 108).box
        XCTAssertEqual(hole(in: solids[0], at: center + Point2(x: -46, y: -26), z: 5, radius: 2) ?? 0, 2, accuracy: 1e-6)
    }

    func testCaseLidRimLeavesTheFitGap() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("enclosures.slip-lid-box"))
        var values = template.defaults
        values["fit"] = 0.25
        let solids = try build(try template.workspace(values), "slip box")
        let rim = solids[1].bounds
        // The rim stands inside the 80 × 60 opening, 0.25 mm in on each side.
        let lid = BoxTemplates.layout(outerWidth: 84).lid
        let rimSlab = try area(solids[1], at: 3)
        let outer = roundedSquareArea(80 - 0.5, 60 - 0.5, radius: 1.75), inner = roundedSquareArea(80 - 0.5 - 3.2, 60 - 0.5 - 3.2, radius: 0.3)
        XCTAssertEqual(rimSlab, outer - inner, accuracy: 0.1)
        XCTAssertEqual(rim.max.z, 6, accuracy: 1e-6)
        XCTAssertEqual((rim.min.x + rim.max.x) / 2, lid.x, accuracy: 1e-6)
    }

    /// Jar with Screw Lid (October 26, 2026): the jar's outside threaded by Screw Lid, the lid top
    /// down on the plate beside it.
    func testScrewLidJarIsThreadedWithItsLidBesideIt() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("enclosures.screw-lid-jar"))
        XCTAssertEqual(template.name(template.defaults), "Jar Ø60 × 60 mm")
        let workspace = try template.workspace(template.defaults)
        let solids = try build(workspace, "jar")
        XCTAssertEqual(solids.count, 2)
        XCTAssertTrue(solids.allSatisfy(\.isValidSolid))
        let thread = try XCTUnwrap(workspace.bodies[0].cuts.last?.thread)
        XCTAssertTrue(thread.isRaised && thread.shape == .printable)
        XCTAssertEqual(thread.startCount, 2)
        XCTAssertEqual(workspace.bodyNames[workspace.bodies[1].id], "Lid")
        // The jar stands on the plate, open side up; the lid lies top down beside it, not touching.
        XCTAssertEqual(solids[0].bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(solids[0].bounds.max.z, 62, accuracy: 1e-6)
        XCTAssertEqual(solids[1].bounds.min.z, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(solids[1].bounds.min.x, solids[0].bounds.max.x)
        XCTAssertEqual(try SolidKernel.solid(for: workspace.bodies[1]).volume, solids[1].volume, accuracy: 1e-6)
    }

    func testScrewLidLinesUpWithThePosts() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("enclosures.screw-lid-box"))
        let workspace = try template.workspace(template.defaults)
        let solids = try build(workspace, "screw box")
        let place = BoxTemplates.layout(outerWidth: 90 + 4.8)
        let posts = workspace.bodies[0].cuts.filter { $0.hole != nil }.map { $0.profile.center }
        let lidHoles = workspace.bodies[1].cuts.filter { $0.hole != nil }
        XCTAssertEqual(posts.count, 4)
        XCTAssertEqual(lidHoles.count, 4)
        // The lid prints outer face down, so its holes are drilled from underneath, over the posts.
        let worldPosts = Set(posts.map { Point2(x: ($0.x - place.box.x).rounded(), y: $0.y.rounded()) })
        let worldHoles = Set(lidHoles.map { cut -> Point2 in
            let p = cut.profile.plane.point(cut.profile.circle!.center)
            return Point2(x: (p.x - place.lid.x).rounded(), y: p.y.rounded())
        })
        XCTAssertEqual(worldPosts, worldHoles)
        XCTAssertTrue(solids.allSatisfy(\.isValidSolid))
    }
}

/// Templates built at their defaults, by id.
private enum TemplateDefaults {
    static func solid(_ id: String) throws -> KernelSolid {
        let template = try XCTUnwrap(TemplateCatalog.template(id))
        return try SolidKernel.solid(for: try XCTUnwrap(try template.workspace(template.defaults).bodies.first))
    }
}
