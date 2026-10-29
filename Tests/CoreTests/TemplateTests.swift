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

    /// The plain Gridfinity Baseplate and Bin are free, and carry none of the Pro pair's magnet or
    /// divider options; so are the Spacer Set and the Fit & Print Tests (October 28, 2026).
    func testOnlyTheStarterTemplatesAreFree() throws {
        let free = TemplateCatalog.all.filter { !$0.needsPro }
        XCTAssertEqual(Set(free.map(\.id)), ["gridfinity.baseplate", "gridfinity.bin", "parts.spacers",
                                             "tests.peg-fit", "tests.slide-fit", "tests.hole-ladder", "tests.insert-block",
                                             "gridfinity.label-bin", "desk.stylus-rest", "signs.key-tag"])
        for template in free where template.category == .gridfinity {
            XCTAssertTrue(Set(template.parameters.map(\.id)).isDisjoint(with: ["magnets", "dividersX", "dividersY"]), template.id)
        }
        let magnet = try XCTUnwrap(TemplateCatalog.all.first { $0.id == "gridfinity.magnet-baseplate" })
        XCTAssertTrue(magnet.parameters.contains { $0.id == "magnets" })
        let divided = try XCTUnwrap(TemplateCatalog.all.first { $0.id == "gridfinity.divided-bin" })
        XCTAssertEqual(Set(divided.parameters.map(\.id)), ["columns", "rows", "height", "dividersX", "dividersY", "lip", "magnets"])
    }

    /// The library's expansions (October 28, 2026): 54 templates in twelve categories.
    func testTheLibraryHasItsCategories() {
        XCTAssertEqual(TemplateCatalog.all.count, 54)
        XCTAssertEqual(ProjectTemplate.Category.allCases.map(\.title),
                       ["Gridfinity", "Electronics", "Boxes & Enclosures", "Drawer & Storage Organizers", "Brackets & Mounts",
                        "Cable Management", "Replacement Parts", "Fit & Print Tests", "Desk & Device Stands", "Workshop & Jigs",
                        "Signs & Labels", "Home & Garden"])
        let counts = Dictionary(grouping: TemplateCatalog.all, by: \.category).mapValues(\.count)
        XCTAssertEqual(counts, [.gridfinity: 8, .electronics: 8, .enclosures: 4, .organizers: 4, .mounts: 4, .cables: 4, .parts: 4,
                                .tests: 4, .desk: 4, .workshop: 4, .signs: 4, .home: 2])
        // Each new template lists what decides its fit and how it prints.
        let original: Set = ["gridfinity.baseplate", "gridfinity.magnet-baseplate", "gridfinity.bin", "gridfinity.divided-bin"]
        let originalBoxesAndBoards = ["electronics.prototype-tray", "enclosures.sliding-lid-box"]
        for template in TemplateCatalog.all where (!["electronics", "enclosures"].contains(template.category.rawValue) || originalBoxesAndBoards.contains(template.id))
            && !original.contains(template.id) {
            let notes = template.notes(template.defaults)
            XCTAssertFalse(notes.measurements.isEmpty, template.id)
            XCTAssertNotNil(notes.printing, template.id)
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
                    let conflicts = Self.conflictingEnds[template.id]?.contains("\(parameter.id)=\(end)") == true
                    do {
                        try build(try template.workspace(values), label)
                        XCTAssertFalse(conflicts, "\(label) was expected to be refused")
                    } catch let error as TemplateError {
                        // Too many dividers for the default bin's size is reported, not built.
                        if case .tooSmall = error, template.category == .gridfinity, parameter.id.hasPrefix("dividers") { continue }
                        if case .tooSmall = error, conflicts { continue }
                        XCTFail("\(label): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Single sizes at their ends that conflict with the other sizes' defaults: setup explains each
    /// (TemplateError.tooSmall) instead of making something, as the specification asks.
    private static let conflictingEnds: [String: Set<String>] = [
        "tests.insert-block": ["insertLength=15.0", "depth=2.0"],
        "parts.knob": ["height=8.0", "shaftSize=20.0", "flat=3.0", "boreDepth=35.0"],
        "parts.handle": ["centers=40.0", "gripWidth=160.0", "sectionWidth=8.0", "sectionThickness=16.0", "hole=8.0"],
        "parts.spacers": ["outside=5.0", "bore=20.0"],
        "organizers.pocket-insert": ["width=40.0", "depth=30.0", "height=6.0", "object=60.0", "pocketDepth=50.0", "columns=12.0", "rows=8.0"],
        "mounts.u-bracket": ["component=10.0", "spacing=120.0"],
        "mounts.slotted-plate": ["width=20.0", "columns=4.0", "rows=4.0", "columnPitch=5.0", "columnPitch=150.0", "slotLength=50.0"],
        "mounts.keyhole-plate": ["width=25.0", "height=15.0", "count=4.0", "spacing=150.0", "entry=16.0", "neck=8.0", "travel=3.0", "travel=25.0"],
        "cables.saddle": ["cable=25.0", "width=6.0", "arch=5.0", "hole=6.0", "spacing=10.0"],
        "cables.winder": ["waist=40.0"],
        "gridfinity.label-bin": ["height=3.0", "shelfDepth=18.0"],
        "gridfinity.tool-insert": ["columns=1.0", "height=2.0", "size=35.0", "pocketColumns=12.0", "pocketRows=8.0", "columnPitch=5.0", "columnPitch=80.0",
                                   "rowPitch=5.0", "rowPitch=80.0", "pocketDepth=50.0"],
        "gridfinity.bottle-holder": ["columns=1.0", "rows=1.0", "height=3.0", "bottle=70.0", "bottleColumns=6.0", "bottleRows=6.0", "pocketDepth=60.0"],
        "gridfinity.adapter-base": ["columns=1.0", "rows=1.0", "holeColumns=4.0", "holeRows=1.0", "holeRows=4.0", "columnPitch=5.0", "columnPitch=150.0",
                                    "rowPitch=5.0", "rowPitch=150.0"],
        "desk.stylus-rest": ["troughDepth=8.0"],
        "desk.card-holder": ["cardHeight=25.0", "back=70.0"],
        "electronics.prototype-tray": ["width=80.0", "columns=3.0", "rows=3.0", "boardWidth=120.0", "boardDepth=100.0", "holeInset=2.0", "columnPitch=25.0",
                                       "columnPitch=150.0", "standoffDiameter=12.0", "fixing=1.0"],
        "workshop.screwdriver-rack": ["handle=8.0", "handle=45.0", "pitch=10.0", "railDepth=20.0"],
        "workshop.paint-rack": ["pocketDepth=20.0", "front=8.0"],
        "signs.nameplate": ["faceHeight=20.0"],
        "signs.mounting-sign": ["width=40.0", "height=20.0", "inset=4.0", "inset=25.0", "letterHeight=40.0", "margin=12.0", "font=4.0", "font=5.0", "font=7.0"],
        "signs.key-tag": ["width=30.0", "height=15.0", "inset=4.0", "letterHeight=18.0"],
        "signs.plant-marker": ["width=30.0", "letterHeight=18.0"],
        "home.draining-tray": ["fit=2.0", "gap=15.0", "slotWidth=8.0", "slotPitch=5.0"],
        "enclosures.sliding-lid-box": ["wall=2.0", "engagement=2.0", "fit=2.0"],
        "workshop.drilling-jig": ["spacing=8.0", "offset=5.0", "thickness=8.0", "drill=12.0", "bushingOutside=3.0", "bushingOutside=20.0", "bushingLength=25.0"],
        "home.planter": ["diameter=35.0"]
    ]

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
        // The Divided Bin has every bin option; the free Bin has no magnet holes.
        let template = try XCTUnwrap(TemplateCatalog.template("gridfinity.divided-bin"))
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
        try build(try XCTUnwrap(TemplateCatalog.template("gridfinity.divided-bin")).workspace(
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
                // The prototyping tray takes any board, so its name names no maker's.
                if board < BoardFootprint.catalog.count, template.parameters.contains(where: { $0.id == "board" }) { XCTAssertTrue(name.contains(" for "), name) }
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

    // MARK: Fit & Print Tests

    private func workspace(_ id: String, _ changes: [String: Double] = [:]) throws -> Workspace {
        let template = try XCTUnwrap(TemplateCatalog.template(id))
        var values = template.defaults
        for (key, value) in changes { values[key] = value }
        return try template.workspace(values)
    }

    private func assertRefused(_ id: String, _ changes: [String: Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try workspace(id, changes), file: file, line: line) { error in
            guard case .tooSmall = error as? TemplateError else { return XCTFail("\(id): \(error)", file: file, line: line) }
        }
    }

    private func holeDiameters(_ body: SolidBody) -> [Double] { body.cuts.compactMap { $0.hole?.diameter } }
    private func labels(_ body: SolidBody) -> [String] { body.cuts.compactMap { $0.text?.text } }

    func testPegFitTestHolesAreThePegPlusTwiceEachClearance() throws {
        let workspace = try workspace("tests.peg-fit")
        let solids = try build(workspace, "peg fit")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Hole Plate", "Peg"])
        // The Fit Test's sequence: 0.10 to 0.40 mm a side round a 6 mm peg.
        XCTAssertEqual(labels(workspace.bodies[0]), ["0.10", "0.15", "0.20", "0.25", "0.30", "0.35", "0.40"])
        for (diameter, clearance) in zip(holeDiameters(workspace.bodies[0]), FitTest.clearances) { XCTAssertEqual(diameter, 6 + 2 * clearance, accuracy: 1e-9) }
        XCTAssertEqual(holeDiameters(workspace.bodies[0]).count, 7)
        // The peg is exactly its diameter, 8 mm tall on a 3 mm tab.
        XCTAssertEqual(solids[1].bounds.max.z, 11, accuracy: 1e-6)
        XCTAssertEqual(try area(solids[1], at: 6), .pi * 9, accuracy: 0.05)
        XCTAssertLessThan(solids[1].bounds.max.y, solids[0].bounds.min.y)
        // The last clearance stays within Fit's 2 mm.
        assertRefused("tests.peg-fit", ["start": 1, "increment": 0.2, "samples": 10])
    }

    func testSlidingFitChannelsAreTheSliderPlusTwiceEachClearance() throws {
        let workspace = try workspace("tests.slide-fit")
        let solids = try build(workspace, "slide fit")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Carrier", "Slider"])
        let fit = PrintTestTemplates.SlideFit(try XCTUnwrap(TemplateCatalog.template("tests.slide-fit")).defaults)
        let layout = fit.layout(try fit.clearances.get())
        XCTAssertEqual(layout.channels.count, 5)
        for (channel, expected) in zip(layout.channels, [10.2, 10.3, 10.4, 10.5, 10.6]) { XCTAssertEqual(channel, expected, accuracy: 1e-9) }
        // 2 mm walls between and outside the channels, a 2 mm floor, and 30 mm of engagement in each.
        XCTAssertEqual(layout.carrierWidth, 52 + 12, accuracy: 1e-9)
        let depth = 30 + layout.band
        XCTAssertEqual(try area(solids[0], at: 1), layout.carrierWidth * depth - 4.5, accuracy: 0.05)
        XCTAssertEqual(try area(solids[0], at: 3.5), layout.carrierWidth * depth - 4.5 - 30 * 52, accuracy: 0.05)
        XCTAssertEqual(labels(workspace.bodies[0]), ["0.10", "0.15", "0.20", "0.25", "0.30"])
        XCTAssertEqual(solids[1].bounds.max.y - solids[1].bounds.min.y, 30 + 15, accuracy: 1e-6)
    }

    func testHoleLadderEngravesWholeDiameters() throws {
        let workspace = try workspace("tests.hole-ladder")
        try build(workspace, "ladder")
        let diameters = holeDiameters(workspace.bodies[0])
        XCTAssertEqual(diameters.count, 7)
        XCTAssertEqual(diameters.first ?? 0, 2.9, accuracy: 1e-9)
        XCTAssertEqual(diameters.last ?? 0, 3.2, accuracy: 1e-9)
        XCTAssertEqual(labels(workspace.bodies[0]), ["2.90", "2.95", "3.00", "3.05", "3.10", "3.15", "3.20"])
    }

    func testInsertBlockBoresAreBlindOverATwoMillimeterFloor() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("tests.insert-block"))
        let solids = try build(try template.workspace(template.defaults), "insert block")
        let block = PrintTestTemplates.InsertBlock(template.defaults)
        let plate = block.plate(try block.diameters.get())
        XCTAssertEqual(solids[0].bounds.max.z, 7, accuracy: 1e-6)
        let full = plate.width * plate.depthAcross - 4.5
        XCTAssertEqual(try area(solids[0], at: 1), full, accuracy: 0.05)
        let bores = [4.1, 4.15, 4.2, 4.25, 4.3].reduce(0) { $0 + .pi * $1 * $1 / 4 }
        XCTAssertEqual(try area(solids[0], at: 4), full - bores, accuracy: 0.05)
        // At least 3 mm between bores; and deeper than the insert by 0.5 mm.
        XCTAssertGreaterThanOrEqual(plate.pitch - plate.widest, 3 - 1e-9)
        assertRefused("tests.insert-block", ["insertLength": 6])
    }

    // MARK: Replacement Parts

    func testSpacersStepUpOrRepeat() throws {
        let solids = try build(try workspace("parts.spacers"), "spacers")
        XCTAssertEqual(solids.map { ($0.bounds.max.z * 10).rounded() / 10 }, [2, 3, 4, 5, 6])
        for (solid, length) in zip(solids, [2.0, 3, 4, 5, 6]) { XCTAssertEqual(solid.volume, .pi * (25 - 1.7 * 1.7) * length, accuracy: 0.01) }
        let same = try workspace("parts.spacers", ["increment": 0, "count": 3])
        XCTAssertEqual(same.bodies.map(\.name), ["Spacer 1", "Spacer 2", "Spacer 3"])
        XCTAssertTrue(try build(same, "same").allSatisfy { abs($0.bounds.max.z - 2) < 1e-6 })
    }

    func testTubePlugInsertIsTheOpeningPlusInterference() throws {
        let plug = try XCTUnwrap(try build(try workspace("parts.tube-plug"), "round plug").first)
        // A 26 mm cap 2 mm thick, then a 20.2 mm sleeve with 2 mm walls, 15 mm long with a lead-in.
        XCTAssertEqual(try area(plug, at: 1), .pi * 13 * 13, accuracy: 0.05)
        XCTAssertEqual(try area(plug, at: 8), .pi * (10.1 * 10.1 - 8.1 * 8.1), accuracy: 0.05)
        XCTAssertEqual(plug.bounds.max.z, 17, accuracy: 1e-6)
        XCTAssertLessThan(try area(plug, at: 16.8), .pi * (10.1 * 10.1 - 8.1 * 8.1))
        let square = try XCTUnwrap(try build(try workspace("parts.tube-plug", ["shape": 1, "width": 30, "depth": 20, "interference": -0.2]), "square plug").first)
        XCTAssertEqual(square.bounds.max.x - square.bounds.min.x, 36, accuracy: 1e-6)
        XCTAssertEqual(try area(square, at: 8), roundedSquareArea(29.6, 19.6, radius: 1) - roundedSquareArea(25.6, 15.6, radius: 0.3), accuracy: 0.05)
    }

    func testKnobBoreFollowsTheShaftWithClearance() throws {
        let knob = try XCTUnwrap(try build(try workspace("parts.knob", ["grip": 0]), "D knob").first)
        // 4 mm of knob over a 12 mm deep bore: 6 mm D shaft, 0.5 mm flat, 0.2 mm clearance.
        let outside = Double.pi * 12 * 12
        XCTAssertEqual(try area(knob, at: 2), outside, accuracy: 0.05)
        let r = 3.2, flat = 2.7
        let d = Double.pi * r * r - (r * r * acos(flat / r) - flat * (r * r - flat * flat).squareRoot())
        XCTAssertEqual(try area(knob, at: 10), outside - d, accuracy: 0.05)
        let hex = try XCTUnwrap(try build(try workspace("parts.knob", ["grip": 0, "shaft": 1]), "hex knob").first)
        XCTAssertEqual(try area(hex, at: 10), outside - 3.squareRoot() / 2 * 6.4 * 6.4, accuracy: 0.05)
        let fluted = try XCTUnwrap(try build(try workspace("parts.knob"), "fluted knob").first)
        XCTAssertLessThan(fluted.volume, knob.volume)
    }

    func testPullHandleKeepsTheScrewsOutsideTheGrip() throws {
        let handle = try XCTUnwrap(try build(try workspace("parts.handle"), "handle").first)
        // Lying on its side: 96 mm centers, tabs 3 mm past the holes, 12 mm wide, 28 mm tall.
        XCTAssertEqual(handle.bounds.max.x - handle.bounds.min.x, 96 + 4.5 + 6, accuracy: 1e-6)
        XCTAssertEqual(handle.bounds.max.y, 28, accuracy: 1e-6)
        for x in [-48.0, 48] {
            let face = try XCTUnwrap(handle.face(near: SIMD3(x + 2.25, 2, 6)))
            XCTAssertEqual(handle.faceCylinder(face)?.radius ?? 0, 2.25, accuracy: 1e-6)
        }
        // Room for the hand under the grip.
        XCTAssertFalse(handle.contains(SIMD3(0, 19, 6)))
        XCTAssertTrue(handle.contains(SIMD3(0, 21, 6)))
        assertRefused("parts.handle", ["centers": 80])
    }

    // MARK: Drawer & Storage Organizers

    func testFittedTrayLeavesTheClearanceAndEqualCompartments() throws {
        let tray = try XCTUnwrap(try build(try workspace("organizers.fitted-tray"), "tray").first)
        let b = tray.bounds
        XCTAssertEqual(b.max.x - b.min.x, 199, accuracy: 1e-6)
        XCTAssertEqual(b.max.y - b.min.y, 149, accuracy: 1e-6)
        XCTAssertEqual(b.max.z, 38, accuracy: 1e-6)
        let outline = roundedSquareArea(199, 149, radius: 3)
        XCTAssertEqual(try area(tray, at: 0.5), outline, accuracy: 0.05)
        let cell = roundedSquareArea((199 - 4 * 1.6) / 3, (149 - 3 * 1.6) / 2, radius: 1)
        XCTAssertEqual(try area(tray, at: 20), outline - 6 * cell, accuracy: 0.05)
        // More compartments keep the outside.
        let more = try XCTUnwrap(try build(try workspace("organizers.fitted-tray", ["columns": 5, "rows": 4]), "tray 5 × 4").first)
        XCTAssertEqual(more.bounds.max.x - more.bounds.min.x, 199, accuracy: 1e-6)
        assertRefused("organizers.fitted-tray", ["width": 50, "columns": 8])
    }

    func testBinSetFillsTheDrawerWithSeparateBins() throws {
        let workspace = try workspace("organizers.bin-set")
        let solids = try build(workspace, "bins")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Bin A1", "Bin A2", "Bin A3", "Bin B1", "Bin B2", "Bin B3"])
        let low = SIMD3(solids.map(\.bounds.min.x).min()!, solids.map(\.bounds.min.y).min()!, 0)
        let high = SIMD3(solids.map(\.bounds.max.x).max()!, solids.map(\.bounds.max.y).max()!, solids.map(\.bounds.max.z).max()!)
        XCTAssertEqual(high.x - low.x, 199, accuracy: 1e-6)
        XCTAssertEqual(high.y - low.y, 149, accuracy: 1e-6)
        XCTAssertEqual(high.z, 38, accuracy: 1e-6)
        // Neighbors 1 mm apart.
        XCTAssertEqual(solids[1].bounds.min.x - solids[0].bounds.max.x, 1, accuracy: 1e-6)
        XCTAssertEqual(solids[3].bounds.min.y - solids[0].bounds.max.y, 1, accuracy: 1e-6)
    }

    func testDividerSlotsInterlockWithTheJointClearance() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("organizers.dividers"))
        let workspace = try template.workspace(template.defaults)
        let solids = try build(workspace, "dividers")
        XCTAssertEqual(solids.count, 3)
        let dividers = OrganizerTemplates.Dividers(template.defaults)
        XCTAssertEqual(dividers.slotWidth, 2.4, accuracy: 1e-9)
        // The two halves of each crossing leave the joint clearance between them.
        XCTAssertEqual(2 * dividers.slotDepth - 30, 0.2, accuracy: 1e-9)
        XCTAssertEqual(solids[0].volume, 199 * 30 * 2 - 1 * 2.4 * 15.1 * 2, accuracy: 0.01)
        XCTAssertEqual(solids[2].volume, 149 * 30 * 2 - 2 * 2.4 * 15.1 * 2, accuracy: 0.01)
        // Side-to-side strips are slotted from the top, front-to-back ones from the bottom.
        XCTAssertFalse(solids[0].contains(SIMD3(0, 29, 1)))
        XCTAssertTrue(solids[0].contains(SIMD3(0, 1, 1)))
        let strip = solids[2].bounds.min.y
        XCTAssertFalse(solids[2].contains(SIMD3(-149 / 2 + 149.0 / 3, strip + 1, 1)))
        assertRefused("organizers.dividers", ["across": 0, "along": 0])
    }

    func testPocketInsertSpreadsItsPocketsEvenly() throws {
        let insert = try XCTUnwrap(try build(try workspace("organizers.pocket-insert"), "insert").first)
        let outline = roundedSquareArea(150, 100, radius: 3)
        XCTAssertEqual(insert.volume, outline * 18 - 15 * .pi * 6.2 * 6.2 * 14, accuracy: 0.5)
        XCTAssertNotNil(insert.face(near: SIMD3(-60 + 6.2, -100.0 / 3, 10)))
        let one = try XCTUnwrap(try build(try workspace("organizers.pocket-insert", ["columns": 1, "rows": 1]), "one pocket").first)
        XCTAssertNotNil(one.face(near: SIMD3(6.2, 0, 10)), "a single pocket is centered")
    }

    // MARK: Brackets & Mounts

    func testLBracketHolesAndRibs() throws {
        let plain = try XCTUnwrap(try build(try workspace("mounts.l-bracket"), "bracket").first)
        XCTAssertEqual(plain.bounds.max.x, 40, accuracy: 1e-6)
        XCTAssertEqual(plain.bounds.max.y, 40, accuracy: 1e-6)
        XCTAssertEqual(plain.bounds.max.z, 30, accuracy: 1e-6)
        XCTAssertEqual(try area(plain, at: 2), 40 * 4 + 36 * 4, accuracy: 0.05)
        // A hole in the middle of each leg's exposed length.
        for point in [SIMD3(22 + 1.7, 2, 15), SIMD3(2, 22 + 1.7, 15)] {
            let face = try XCTUnwrap(plain.face(near: point))
            XCTAssertEqual(plain.faceCylinder(face)?.radius ?? 0, 1.7, accuracy: 1e-6)
        }
        let ribbed = try XCTUnwrap(try build(try workspace("mounts.l-bracket", ["ribs": 1]), "ribbed").first)
        XCTAssertEqual(ribbed.bounds.max.x, 40, accuracy: 1e-6)
        XCTAssertEqual(ribbed.bounds.max.z, 30, accuracy: 1e-6)
        XCTAssertGreaterThan(try area(ribbed, at: 2), try area(plain, at: 2) + 100)
        XCTAssertEqual(try area(ribbed, at: 15), try area(plain, at: 15), accuracy: 0.05, "the ribs stay at the sides")
        assertRefused("mounts.l-bracket", ["ribs": 1, "width": 12])
    }

    func testUBracketOpeningIsTheComponentPlusClearance() throws {
        let bracket = try XCTUnwrap(try build(try workspace("mounts.u-bracket"), "u bracket").first)
        XCTAssertEqual(try area(bracket, at: 2), 48.4 * 4 + 2 * 4 * 30, accuracy: 0.05)
        XCTAssertTrue(bracket.contains(SIMD3(20.3, 20, 2)))
        XCTAssertFalse(bracket.contains(SIMD3(20.1, 20, 2)))
        for x in [-10.0, 10] { XCTAssertFalse(bracket.contains(SIMD3(x, 2, 12.5))) }
    }

    func testSlottedPlateSlots() throws {
        let plate = try XCTUnwrap(try build(try workspace("mounts.slotted-plate"), "slotted").first)
        let slot = (14 - 3.4) * 3.4 + .pi * 1.7 * 1.7
        XCTAssertEqual(plate.volume, (roundedSquareArea(80, 30, radius: 3) - 2 * slot) * 4, accuracy: 0.5)
        XCTAssertFalse(plate.contains(SIMD3(-22.5 + 5, 0, 2)))
        XCTAssertTrue(plate.contains(SIMD3(-22.5 + 7.5, 0, 2)))
    }

    func testKeyholesHaveTheirEntriesBelowTheirNecks() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("mounts.keyhole-plate"))
        let plate = try XCTUnwrap(try build(try template.workspace(template.defaults), "keyholes").first)
        let keyhole = MountTemplates.KeyholePlate(template.defaults)
        for x in [-22.5, 22.5] {
            let entry = try XCTUnwrap(plate.face(near: SIMD3(x, keyhole.entryY - 3.5, 2.5)))
            XCTAssertEqual(plate.faceCylinder(entry)?.radius ?? 0, 3.5, accuracy: 1e-3)
            let top = try XCTUnwrap(plate.face(near: SIMD3(x, keyhole.entryY + 8 + 1.75, 2.5)))
            XCTAssertEqual(plate.faceCylinder(top)?.radius ?? 0, 1.75, accuracy: 1e-2)
            // The neck holds a head wider than it, beside the slot.
            XCTAssertTrue(plate.contains(SIMD3(x + 2.5, keyhole.entryY + 8, 2.5)))
        }
    }

    // MARK: Cable Management

    func testCableSaddleIsOpenUnderneath() throws {
        let saddle = try XCTUnwrap(try build(try workspace("cables.saddle"), "saddle").first)
        // The cable (6.4 mm with clearance) lies on the wall at y = 0, under the arch.
        XCTAssertEqual(saddle.bounds.min.y, 0, accuracy: 1e-6)
        XCTAssertFalse(saddle.contains(SIMD3(0, 0.5, 5)))
        XCTAssertFalse(saddle.contains(SIMD3(3.1, 1, 5)))
        XCTAssertTrue(saddle.contains(SIMD3(0, 7.4, 5)))
        let arch = try XCTUnwrap(saddle.face(near: SIMD3(0, 6.4, 1)))
        XCTAssertEqual(saddle.faceCylinder(arch)?.radius ?? 0, 3.2, accuracy: 1e-6)
        for x in [-11.0, 11] { XCTAssertFalse(saddle.contains(SIMD3(x, 1.5, 5))) }
    }

    func testCableCombGroovesAreSeparatedAndConnected() throws {
        let comb = try XCTUnwrap(try build(try workspace("cables.comb"), "comb").first)
        XCTAssertEqual(comb.bounds.max.x - comb.bounds.min.x, 4 * 4.4 + 3 * 2 + 4, accuracy: 1e-6)
        XCTAssertEqual(comb.bounds.max.z, 3 + 2.2, accuracy: 1e-6)
        let groove = try XCTUnwrap(comb.face(near: SIMD3(-13.8 + 2 + 2.2, 0, 3)))
        XCTAssertEqual(comb.faceCylinder(groove)?.radius ?? 0, 2.2, accuracy: 1e-6)
        XCTAssertTrue(comb.contains(SIMD3(-13.8 + 2 + 4.4 + 1, 0, 5)), "material between grooves")
    }

    func testGrommetSleeveFitsTheHoleWithItsSideOpening() throws {
        let grommet = try XCTUnwrap(try build(try workspace("cables.grommet"), "grommet").first)
        let sleeve = try XCTUnwrap(grommet.face(near: SIMD3(-19.8, 0, 10)))
        XCTAssertEqual(grommet.faceCylinder(sleeve)?.radius ?? 0, 19.8, accuracy: 1e-6)
        let bore = try XCTUnwrap(grommet.face(near: SIMD3(-17.8, 0, 10)))
        XCTAssertEqual(grommet.faceCylinder(bore)?.radius ?? 0, 17.8, accuracy: 1e-6)
        XCTAssertEqual(grommet.bounds.max.z, 20, accuracy: 1e-6)
        // The opening runs through the sleeve and the flange.
        XCTAssertFalse(grommet.contains(SIMD3(18.8, 0, 10)))
        XCTAssertFalse(grommet.contains(SIMD3(22, 0, 1)))
        let ring = try XCTUnwrap(try build(try workspace("cables.grommet", ["opening": 0]), "ring").first)
        XCTAssertTrue(ring.contains(SIMD3(18.8, 0, 10)))
    }

    func testCableWinderWaistAndNotches() throws {
        let winder = try XCTUnwrap(try build(try workspace("cables.winder"), "winder").first)
        XCTAssertTrue(winder.contains(SIMD3(0, 6.5, 2)))
        XCTAssertFalse(winder.contains(SIMD3(0, 7.5, 2)))
        XCTAssertFalse(winder.contains(SIMD3(39, 0, 2)))
        XCTAssertTrue(winder.contains(SIMD3(29, 0, 2)))
        XCTAssertTrue(winder.contains(SIMD3(39, 5, 2)), "material beside the notch")
    }

    // MARK: Second expansion: Gridfinity accessories

    func testLabelBinAddsAShelfAndStillStacks() throws {
        let bin = try XCTUnwrap(try build(try workspace("gridfinity.label-bin"), "label bin").first)
        let plain = try SolidKernel.solid(for: try Gridfinity.bin(columns: 3, rows: 2, height: 4, dividers: (0, 0), lip: true, magnets: 0))
        // The same outside, feet, and lip as a plain bin, so it seats and takes a bin on top.
        XCTAssertEqual(bin.bounds.min.x, plain.bounds.min.x, accuracy: 1e-6)
        XCTAssertEqual(bin.bounds.max.z, plain.bounds.max.z, accuracy: 1e-6)
        for z in [1.5, 29.0] { XCTAssertEqual(try area(bin, at: z), try area(plain, at: z), accuracy: 0.05) }
        // A 10 mm shelf along the front wall, its top 2 mm under the walls' top.
        let front = -(83.5 - 2.4) / 2
        XCTAssertTrue(bin.contains(SIMD3(0, front + 5, 25.2)))
        XCTAssertFalse(bin.contains(SIMD3(0, front + 5, 26.5)))
        XCTAssertFalse(bin.contains(SIMD3(0, front + 12, 25.2)))
        XCTAssertGreaterThan(bin.volume, plain.volume)
    }

    func testToolInsertPocketsTakeEachShapeWithClearance() throws {
        let base = ["columns": 3.0, "rows": 2]
        let round = try XCTUnwrap(try build(try workspace("gridfinity.tool-insert", base), "round").first)
        // Eight pockets 14 mm deep from the 28 mm top, over 14 mm of block.
        let solid = try area(round, at: 12)
        XCTAssertEqual(solid - (try area(round, at: 20)), 8 * .pi * 4.2 * 4.2, accuracy: 0.05)
        let hex = try XCTUnwrap(try build(try workspace("gridfinity.tool-insert", ["shape": 1]), "hex").first)
        XCTAssertEqual(solid - (try area(hex, at: 20)), 8 * 3.squareRoot() / 2 * 8.4 * 8.4, accuracy: 0.05)
        let box = try XCTUnwrap(try build(try workspace("gridfinity.tool-insert", ["shape": 2]), "rectangular").first)
        XCTAssertEqual(solid - (try area(box, at: 20)), 8 * 8.4 * 16.4, accuracy: 0.05)
        // Feet like any bin's.
        let plain = try SolidKernel.solid(for: try Gridfinity.bin(columns: 3, rows: 2, height: 4, dividers: (0, 0), lip: false, magnets: 0))
        XCTAssertEqual(try area(round, at: 1.5), try area(plain, at: 1.5), accuracy: 0.05)
    }

    func testBottleHolderSpreadsItsWells() throws {
        let holder = try XCTUnwrap(try build(try workspace("gridfinity.bottle-holder"), "bottles").first)
        XCTAssertEqual(holder.bounds.max.z, 35, accuracy: 1e-6)
        XCTAssertEqual(try area(holder, at: 12) - (try area(holder, at: 25)), 4 * .pi * 14.2 * 14.2, accuracy: 0.05)
        let well = try XCTUnwrap(holder.face(near: SIMD3(83.5 / 4 + 14.2, 83.5 / 4, 25)))
        XCTAssertEqual(holder.faceCylinder(well)?.radius ?? 0, 14.2, accuracy: 1e-6)
    }

    func testAdapterBaseHolesGoThroughTheFeet() throws {
        let base = try XCTUnwrap(try build(try workspace("gridfinity.adapter-base"), "adapter").first)
        XCTAssertEqual(base.bounds.max.z, 6 + 4, accuracy: 1e-6)
        let plain = try SolidKernel.solid(for: try Gridfinity.bin(columns: 2, rows: 2, height: 2, dividers: (0, 0), lip: false, magnets: 0))
        XCTAssertEqual(try area(base, at: 1.5), try area(plain, at: 1.5) - 4 * .pi * 1.7 * 1.7, accuracy: 0.05)
        for z in [1.0, 9] { XCTAssertFalse(base.contains(SIMD3(21, 21, z))) }
        XCTAssertEqual(try area(base, at: 9), roundedSquareArea(83.5, 83.5, radius: 3.75) - 4 * .pi * 1.7 * 1.7, accuracy: 0.05)
        let none = try workspace("gridfinity.adapter-base", ["holeColumns": 0])
        try build(none, "no holes")
        XCTAssertTrue(none.bodies[0].cuts.allSatisfy { $0.hole == nil })
        assertRefused("gridfinity.adapter-base", ["holeRows": 1])
    }

    // MARK: Second expansion: desk and workshop

    func testDeviceStandPresetsFillInTheirSizes() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("desk.device-stand"))
        var values = template.defaults
        values["fit"] = 0.3
        values["preset"] = 1
        values = template.adjust(values, "preset")
        XCTAssertEqual(values["width"], 140)
        XCTAssertEqual(values["supportHeight"], 150)
        XCTAssertEqual(values["fit"], 0.3, "a preset keeps the clearance")
        values["width"] = 150
        values = template.adjust(values, "width")
        XCTAssertEqual(values.choice("preset"), 2, "changing a preset size makes it Custom")
        XCTAssertEqual(values["supportHeight"], 150)
        for (label, preset) in [("phone", 0.0), ("tablet", 1)] {
            var chosen = template.defaults
            chosen["preset"] = preset
            let stand = try XCTUnwrap(try build(try template.workspace(template.adjust(chosen, "preset")), label).first)
            let size = DeskTemplates.DeviceStand(template.adjust(chosen, "preset"))
            // The seat is clear, the base solid, and the notch cuts the lip in the middle only.
            XCTAssertFalse(stand.contains(SIMD3(size.thickness + size.seatRun / 2, size.thickness + 1, 5)), label)
            XCTAssertTrue(stand.contains(SIMD3(size.thickness + size.seatRun / 2, size.thickness / 2, 5)), label)
            XCTAssertFalse(stand.contains(SIMD3(size.thickness / 2, size.thickness + 1, size.width / 2)), label)
            XCTAssertTrue(stand.contains(SIMD3(size.thickness / 2, size.thickness + 1, 5)), label)
            XCTAssertEqual(stand.bounds.max.y, size.supportHeight, accuracy: 1e-6, label)
        }
    }

    func testStylusRestTroughHasEndStops() throws {
        let rest = try XCTUnwrap(try build(try workspace("desk.stylus-rest"), "rest").first)
        XCTAssertEqual(rest.bounds.max.z, 6, accuracy: 1e-6)
        XCTAssertFalse(rest.contains(SIMD3(0, 0, 5.5)))
        XCTAssertTrue(rest.contains(SIMD3(0, 0, 2.5)), "3 mm under the trough")
        XCTAssertTrue(rest.contains(SIMD3(48, 0, 5.5)), "closed ends")
        let trough = try XCTUnwrap(rest.face(near: SIMD3(0, 0, 3)))
        XCTAssertEqual(rest.faceCylinder(trough)?.radius ?? 0, 4.7, accuracy: 1e-6)
    }

    func testCardHolderFitsTheStack() throws {
        let holder = try XCTUnwrap(try build(try workspace("desk.card-holder"), "cards").first)
        XCTAssertEqual(holder.bounds.max.x - holder.bounds.min.x, 90.4 + 4, accuracy: 1e-6)
        XCTAssertEqual(holder.bounds.max.z, 33, accuracy: 1e-6)
        XCTAssertEqual(try area(holder, at: 6), 94.4 * 16.4 - 90.4 * 12.4, accuracy: 0.05)
        XCTAssertEqual(try area(holder, at: 20), 94.4 * 2, accuracy: 0.05, "only the back rises past the front")
    }

    func testHexKeyHolderPocketsAndLabels() throws {
        let workspace = try workspace("workshop.hex-key-holder")
        let holder = try XCTUnwrap(try build(workspace, "hex keys").first)
        XCTAssertEqual(labels(workspace.bodies[0]), ["1.5", "2", "2.5", "3", "4", "5", "6", "8"])
        let pockets = [1.5, 2, 2.5, 3, 4, 5, 6, 8].reduce(0) { $0 + 3.squareRoot() / 2 * ($1 + 0.4) * ($1 + 0.4) }
        XCTAssertEqual(try area(holder, at: 3) - (try area(holder, at: 10)), pockets, accuracy: 0.05)
        XCTAssertEqual(holder.bounds.max.z, 19, accuracy: 1e-6)
    }

    // MARK: Second expansion: text and signs

    private func text(_ id: String, _ text: String, _ changes: [String: Double] = [:]) throws -> Workspace {
        let template = try XCTUnwrap(TemplateCatalog.template(id))
        var values = template.defaults
        values.texts["text"] = text
        for (key, value) in changes { values[key] = value }
        return try template.workspace(values)
    }

    private func refusal(_ id: String, _ value: String, _ changes: [String: Double] = [:], file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { let workspace = try text(id, value, changes); _ = try build(workspace, id); return nil } catch let error as TemplateError {
            guard case .tooSmall(let message) = error else { XCTFail("\(error)", file: file, line: line); return nil }
            return message
        } catch { XCTFail("\(error)", file: file, line: line); return nil }
    }

    func testTemplateTextIsKeptAsTypedAndRefusedWhenItCantBeUsed() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("signs.key-tag"))
        XCTAssertEqual(template.defaults.text("text"), "Keys")
        var values = template.defaults
        values.texts["text"] = "  Shed 2"
        XCTAssertEqual(template.clamped(values).text("text"), "  Shed 2", "spaces are kept")
        XCTAssertTrue(TemplateCatalog.template("parts.knob")!.defaults.texts.isEmpty)
        XCTAssertEqual(template.name(template.clamped(values)), "Key Tag   Shed 2")
        XCTAssertNotNil(refusal("signs.key-tag", "   "))
        XCTAssertNotNil(refusal("signs.key-tag", "Two\nlines"))
        XCTAssertNotNil(refusal("signs.key-tag", "Tab\there"))
        XCTAssertEqual(refusal("signs.key-tag", String(repeating: "W", count: 19)), "The text is 19 characters long; it can be at most 18.")
        XCTAssertTrue(refusal("signs.key-tag", "Ab🌿")?.contains("🌿") == true, "a character the font can't draw is named")
        XCTAssertTrue(refusal("signs.key-tag", "WWWWWWWWWWWW")?.hasPrefix("The text is") == true, "text too wide for the tag")
        // Accents, descenders, and a combining mark fit and build.
        for word in ["Café", "Jüpg", "Cafe\u{301}"] { XCTAssertNil(refusal("signs.key-tag", word), word) }
    }

    func testRaisedAndRecessedLettersJoinTheirPart() throws {
        let plain = 60.0 * 25 - (4 - .pi) * 16, ring = Double.pi * 2.5 * 2.5
        let raised = try XCTUnwrap(try build(try text("signs.key-tag", "Keys"), "raised").first)
        let recessed = try XCTUnwrap(try build(try text("signs.key-tag", "Keys", ["relief": 1]), "recessed").first)
        XCTAssertGreaterThan(raised.volume, (plain - ring) * 3 + 1)
        XCTAssertLessThan(recessed.volume, (plain - ring) * 3 - 1)
        XCTAssertEqual(raised.bounds.max.z, 3.6, accuracy: 1e-6)
        // Fonts that kern letters into each other ("Al" in Georgia and American Typewriter) still make one solid.
        for font in [7.0, 8] {
            for relief in [0.0, 1] { try build(try text("signs.nameplate", "Alex", ["font": font, "relief": relief]), "kerned \(font)") }
        }
    }

    func testSignTextIsCenteredInItsRoom() throws {
        let workspace = try text("signs.mounting-sign", "Workshop")
        let sign = try XCTUnwrap(try build(workspace, "sign").first)
        let spec = try XCTUnwrap(workspace.bodies[0].cuts.compactMap(\.text).first)
        let points = spec.loops.flatMap { [$0.start] + $0.segments.flatMap(\.points) }
        XCTAssertEqual((points.map(\.x).min()! + points.map(\.x).max()!) / 2, 0, accuracy: 1e-6)
        XCTAssertEqual((points.map(\.y).min()! + points.map(\.y).max()!) / 2, 0, accuracy: 1e-6)
        for x in [-52.0, 52] { XCTAssertFalse(sign.contains(SIMD3(x, 0, 1.5))) }
        XCTAssertTrue(refusal("signs.mounting-sign", "Hi", ["radius": 15, "height": 25])?.contains("corner radius") == true)
        XCTAssertNil(refusal("signs.mounting-sign", "Hi", ["mounting": 0, "width": 40]))
    }

    func testNameplateFaceSlopesAtItsAngle() throws {
        let workspace = try text("signs.nameplate", "Alex")
        let plate = try XCTUnwrap(try build(workspace, "nameplate").first)
        XCTAssertEqual(plate.bounds.max.z, 3 + 35 * sin(.pi / 3), accuracy: 1e-6)
        let cut = try XCTUnwrap(workspace.bodies[0].cuts.first { $0.text != nil })
        let normal = cut.profile.plane.normalAxis
        XCTAssertEqual(acos(normal.z) * 180 / .pi, 60, accuracy: 1e-6, "the face is 60° from the desk, so its normal is 60° from upright")
        XCTAssertLessThan(normal.y, 0, "facing the front")
        XCTAssertTrue(refusal("signs.nameplate", "Alex", ["angle": 45, "faceHeight": 60])?.contains("base") == true)
    }

    func testKeyTagAndPlantMarker() throws {
        let tag = try XCTUnwrap(try build(try text("signs.key-tag", "Keys"), "tag").first)
        XCTAssertFalse(tag.contains(SIMD3(-23, 0, 1.5)), "the ring hole")
        XCTAssertNotNil(refusal("signs.key-tag", "Keys", ["inset": 4]))
        let marker = try XCTUnwrap(try build(try text("signs.plant-marker", "Basil"), "marker").first)
        XCTAssertEqual(marker.bounds.max.y - marker.bounds.min.y, 125, accuracy: 1e-6)
        XCTAssertTrue(marker.contains(SIMD3(5.5, -12.5 - 50, 1)))
        XCTAssertFalse(marker.contains(SIMD3(6.5, -12.5 - 50, 1)), "a 12 mm spike")
        XCTAssertNotNil(refusal("signs.plant-marker", "Basil", ["tip": 40, "spike": 40]))
    }

    // MARK: Second expansion: racks, trays

    func testScrewdriverRackHolesAndMounting() throws {
        let rack = try XCTUnwrap(try build(try workspace("workshop.screwdriver-rack"), "rack").first)
        let rail = SIMD3(0.0, 4, 0)
        for index in 0..<6 { XCTAssertFalse(rack.contains(SIMD3((Double(index) - 2.5) * 26, rail.y, 15)), "shaft hole \(index)") }
        XCTAssertTrue(rack.contains(SIMD3(0, 4, 15)), "rail between holes")
        XCTAssertEqual(rack.bounds.max.x - rack.bounds.min.x, 5 * 26 + 20 + 2 * 12.5, accuracy: 1e-6)
        for x in [-(87.5 - 6.25), 87.5 - 6.25] { XCTAssertFalse(rack.contains(SIMD3(x, 19, 2))) }
    }

    func testPaintRackSteps() throws {
        let rack = try XCTUnwrap(try build(try workspace("workshop.paint-rack"), "paint").first)
        XCTAssertEqual(rack.bounds.max.z, 32, accuracy: 1e-6)
        let front = try area(rack, at: 9), back = try area(rack, at: 25)
        XCTAssertEqual(front - (try area(rack, at: 2)), -4 * .pi * 13.2 * 13.2, accuracy: 0.05)
        XCTAssertEqual(back, (30.4 + 3) * 120.6 - 4 * .pi * 13.2 * 13.2, accuracy: 0.05)
    }

    func testPrototypeTrayStandoffsKeepAMillimeterUnderTheirBores() throws {
        let workspace = try workspace("electronics.prototype-tray")
        let tray = try XCTUnwrap(try build(workspace, "tray").first)
        let bores = workspace.bodies[0].cuts.filter { $0.hole != nil }
        XCTAssertEqual(bores.count, 8)
        XCTAssertTrue(bores.allSatisfy { $0.depth == 5 })
        // Board centers ±40, holes 3.5 in from a 70 × 45 board's corners.
        XCTAssertFalse(tray.contains(SIMD3(-40 - 31.5, -19, 8)))
        XCTAssertTrue(tray.contains(SIMD3(-40 - 31.5, -19, 3.5)))
        XCTAssertNotNil(refusalOfNumbers("electronics.prototype-tray", ["fixing": 1]))
        try build(try self.workspace("electronics.prototype-tray", ["fixing": 1, "standoff": 8]), "inserts")
    }

    private func refusalOfNumbers(_ id: String, _ changes: [String: Double]) -> String? {
        do { _ = try build(try workspace(id, changes), id); return nil } catch { return error.localizedDescription }
    }

    func testDrainingTrayInsertRestsOnTheLedges() throws {
        let workspace = try workspace("home.draining-tray")
        let solids = try build(workspace, "draining")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Catch Tray", "Slotted Insert"])
        let insert = solids[1].bounds
        XCTAssertEqual(insert.max.x - insert.min.x, 140 - 0.4, accuracy: 1e-6)
        XCTAssertEqual(insert.max.y - insert.min.y, 90 - 0.4, accuracy: 1e-6)
        // An unbroken floor, the ledges up to the gap, and room above for the insert under the rim.
        XCTAssertEqual(try area(solids[0], at: 1), roundedSquareArea(144.8, 94.8, radius: 4), accuracy: 0.05)
        XCTAssertTrue(solids[0].contains(SIMD3(-70 + 1.5, 0, 2.4 + 5)))
        XCTAssertFalse(solids[0].contains(SIMD3(-70 + 1.5, 0, 2.4 + 7)))
        XCTAssertGreaterThan(workspace.bodies[1].cuts.count, 10)
    }

    // MARK: Second expansion: assemblies

    func testHeadphoneStandPartsFitTogether() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("desk.headphone-stand"))
        let workspace = try template.workspace(template.defaults)
        let solids = try build(workspace, "headphones")
        XCTAssertEqual(workspace.bodies.map(\.name), ["Base", "Post", "Cradle"])
        let stand = DeskTemplates.HeadphoneStand(template.defaults)
        // Assembled: base, post between its shoulders, and the cradle's crown reach the height.
        XCTAssertEqual(10 + stand.postLength + solids[2].bounds.max.z, 220, accuracy: 1e-6)
        XCTAssertEqual(solids[1].bounds.max.x - solids[1].bounds.min.x, stand.postLength + 10, accuracy: 1e-6)
        // Tenons 14 mm square in 14.4 mm sockets 5 mm deep, over 5 mm of base.
        let plate: Double = 160 * 100 - (4 - .pi) * 64
        XCTAssertEqual(try area(solids[0], at: 7), plate - 14.4 * 14.4, accuracy: 0.05)
        XCTAssertEqual(try area(solids[0], at: 3), plate, accuracy: 0.05)
        XCTAssertEqual(try area(solids[1], at: 9), stand.postLength * 18 + 2 * 5 * 14, accuracy: 0.05)
        // The crown: 10 mm thick at the ends, rising to the middle on an 80 mm radius.
        let crown = try XCTUnwrap(solids[2].face(near: SIMD3(0, 100 / 2 + 10 + 17.5, solids[2].bounds.max.z)))
        XCTAssertEqual(solids[2].faceCylinder(crown)?.radius ?? 0, 80, accuracy: 1e-6)
        XCTAssertFalse(solids[2].contains(SIMD3(0, 100 / 2 + 10 + 17.5, 2)), "the socket underneath")
    }

    func testDrillingJigGuidesSitTheirDistanceFromTheEdge() throws {
        let jig = try XCTUnwrap(try build(try workspace("workshop.drilling-jig"), "jig").first)
        // Upside down: bushing seats 8.1 mm across, 10 deep from the face the drill enters, then a 6 mm bore.
        for x in [-16.0, 16] {
            XCTAssertFalse(jig.contains(SIMD3(x + 3.9, 10, 5)))
            XCTAssertTrue(jig.contains(SIMD3(x + 3.9, 10, 12)), "the shoulder under the seat")
            XCTAssertFalse(jig.contains(SIMD3(x + 2.9, 10, 12)), "the bore through it")
        }
        XCTAssertTrue(jig.contains(SIMD3(0, -1.5, 15 + 7)), "the fence along the edge")
        XCTAssertFalse(jig.contains(SIMD3(0, 1, 15 + 7)), "the workpiece goes under")
        let printed = try workspace("workshop.drilling-jig", ["mode": 1])
        try build(printed, "printed")
        XCTAssertEqual(printed.bodies[0].cuts.compactMap { $0.hole?.diameter }, [5.4, 5.4])
    }

    func testSlidingLidEngagesItsGroovesAndSlidesOut() throws {
        let template = try XCTUnwrap(TemplateCatalog.template("enclosures.sliding-lid-box"))
        let workspace = try template.workspace(template.defaults)
        let solids = try build(workspace, "sliding")
        let box = BoxTemplates.SlidingLidBox(template.defaults)
        let center = BoxTemplates.layout(outerWidth: 94.8).box
        XCTAssertEqual(solids[0].bounds.max.z, box.top, accuracy: 1e-6)
        XCTAssertEqual(solids[1].bounds.max.y - solids[1].bounds.min.y, 60 + 2 - 0.4, accuracy: 1e-6)
        // The lid in place, at any point of its travel, sits in the grooves without touching the box.
        for travel in [0.0, 30, 80] {
            // The lid's entry end at the box's outside, slid back by `travel`.
            let entry: Double = center.x - 45 - 2.4
            let lidMiddle = (solids[1].bounds.min.x + solids[1].bounds.max.x) / 2, lidSide = (solids[1].bounds.min.y + solids[1].bounds.max.y) / 2
            let move = RigidTransform(translation: SIMD3(entry + 92.2 / 2 - travel - lidMiddle, -lidSide, box.lidUnderside))
            let lid = try SolidKernel.solid(for: try XCTUnwrap(workspace.bodies[1].transformed(by: move)))
            XCTAssertLessThan(try SolidKernel.boolean(solids[0], lid, .intersect).volume, 1e-6, "travel \(travel)")
        }
        // Each lid edge reaches 0.8 mm into its wall; the wall behind the groove is 1.4 mm.
        XCTAssertFalse(solids[0].contains(SIMD3(center.x, 30.5, box.lidUnderside + 1)), "the groove")
        XCTAssertTrue(solids[0].contains(SIMD3(center.x, 31.7, box.lidUnderside + 1)), "the wall behind it")
        XCTAssertTrue(solids[0].contains(SIMD3(center.x, 30.5, box.grooveTop + 0.5)), "the lip over the lid")
        XCTAssertFalse(solids[0].contains(SIMD3(center.x - 46.2, 0, box.lidUnderside + 1)), "open at the entry end")
        XCTAssertTrue(solids[0].contains(SIMD3(center.x + 46.2, 0, box.lidUnderside + 1)), "closed at the far end")
    }

    func testPlanterSaucerClearsThePlanter() throws {
        for shape in [0.0, 1] {
            let template = try XCTUnwrap(TemplateCatalog.template("home.planter"))
            var values = template.defaults
            values["shape"] = shape
            let workspace = try template.workspace(values)
            let solids = try build(workspace, "planter \(shape)")
            let planter = HomeTemplates.Planter(values)
            XCTAssertEqual(solids[0].bounds.max.z, 83, accuracy: 1e-6)
            // Assembled on the saucer's ribs, the planter touches only the ribs.
            let saucer = solids[1].bounds, foot = solids[0].bounds
            let move = RigidTransform(translation: SIMD3((saucer.min.x + saucer.max.x) / 2 - (foot.min.x + foot.max.x) / 2, 0, 4))
            let placed = try SolidKernel.solid(for: try XCTUnwrap(workspace.bodies[0].transformed(by: move)))
            XCTAssertLessThan(try SolidKernel.boolean(solids[1], placed, .intersect).volume, 1e-6)
            XCTAssertEqual(workspace.bodies[0].cuts.filter { $0.hole != nil }.count, 5)
            // The ribs stay inside the saucer's wall.
            XCTAssertEqual(saucer.max.x - saucer.min.x, planter.saucerInside.width + 4, accuracy: 1e-6)
            XCTAssertEqual(saucer.max.y - saucer.min.y, planter.saucerInside.depth + 4, accuracy: 1e-6)
            XCTAssertEqual(planter.bottom.width, 80 - 2 * 80 * tan(5 * Double.pi / 180), accuracy: 1e-9)
        }
        let straight = try workspace("home.planter", ["draft": 0, "drains": 0])
        let solid = try XCTUnwrap(try build(straight, "straight").first)
        XCTAssertEqual(try area(solid, at: 1), .pi * 42.4 * 42.4, accuracy: 0.05, "an undrilled floor")
        XCTAssertEqual(try area(solid, at: 50), .pi * (42.4 * 42.4 - 40 * 40), accuracy: 0.05)
    }
}

/// Templates built at their defaults, by id.
private enum TemplateDefaults {
    static func solid(_ id: String) throws -> KernelSolid {
        let template = try XCTUnwrap(TemplateCatalog.template(id))
        return try SolidKernel.solid(for: try XCTUnwrap(try template.workspace(template.defaults).bodies.first))
    }
}
