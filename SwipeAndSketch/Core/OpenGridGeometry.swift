import CryptoKit
import Foundation
import SSKernel
import simd

/// openGrid boards (openGrid by David D, CC BY 4.0; see THIRD-PARTY-NOTICES.md), built exactly
/// from the published profile: the openGrid Tile Dimensions drawing and the official STEP boards,
/// which Tests/CoreTests/OpenGridTests.swift compares them with. A board lies in XY on the
/// official files' datum: centered on the origin, z = 0 the face snaps go into (a Lite board's
/// front; a Full board is the same both ways), z = thickness the other.
enum OpenGrid {
    static let pitch = 28.0

    enum BoardType: String, CaseIterable, Sendable {
        case full, lite
        var thickness: Double { self == .full ? 6.8 : 4 }
        var title: String { self == .full ? "Full" : "Lite" }
        /// The edge connector pocket's floor: centered in a Full board, 1 mm off a Lite board's front.
        var pocketFloor: Double { self == .full ? 2.2 : 1 }
    }

    // The cell opening, from the drawing: at the face 1.1 mm of rim, a 0.4 mm 45° chamfer to
    // 1.5 mm, a land to 1.4 mm deep, a 35° ramp out to the 0.8 mm groove from 2.4 mm deep; then
    // the same in reverse on a Full board's other face. At each corner a 2.6 mm block set back
    // 4.2 mm along the diagonal, with a 1.4 mm 45° lead-in.
    static let rim = 1.1, land = 1.5, groove = 0.8, chamfer = 0.4, landEnd = 1.4, grooveStart = 2.4
    static let cornerBlock = 4.2 * 2.squareRoot() / 2 + 2.6, cornerLead = 1.4
    /// The 45° chamfer on a board's outer corners.
    static let boardCornerChamfer = 4.2
    // Lite screw holes, from the official Lite boards: 7.2 mm × 1 mm counterbore at the front, a 90°
    // countersink down to 4.1 mm, through to the back.
    static let screwCounterbore = (radius: 3.6, depth: 1.0), screwHole = 2.05

    /// The connector pocket in an edge, in its own frame: the flat on the edge (y = 0), the round
    /// head 5.1 mm in, 5.2 mm across; arcs exact, as in the official board (and its Negative file).
    static func connectorPocket() -> (points: [Point2], mids: [Point2?]) {
        let main = 2.6, fillet = 0.5, tiny = 0.25, slot = Point2(x: 5.1, y: 0), slotRadius = 5 * 5.squareRoot() / 4
        let filletCenter = Point2(x: main - fillet, y: ((slotRadius + fillet) * (slotRadius + fillet) - pow(slot.x - (main - fillet), 2)).squareRoot())
        let tinyCenter = Point2(x: slot.x - ((slotRadius - tiny) * (slotRadius - tiny) - tiny * tiny).squareRoot(), y: tiny)
        func toward(_ center: Point2, _ radius: Double, _ target: Point2) -> Point2 {
            let d = Point2(x: target.x - center.x, y: target.y - center.y), s = radius / (d.x * d.x + d.y * d.y).squareRoot()
            return Point2(x: center.x + d.x * s, y: center.y + d.y * s)
        }
        // The slot circle sits 2.5 mm below the flat in the construction; shifting it up puts the flat on y = 0.
        let slotCenter = Point2(x: slot.x, y: 0)
        let filletOnSlot = toward(slotCenter, slotRadius, filletCenter), slotOnTiny = toward(slotCenter, slotRadius, tinyCenter)
        func mid(_ center: Point2, _ radius: Double, _ a: Point2, _ b: Point2) -> Point2 {
            toward(center, radius, Point2(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        }
        let top = Point2(x: 0, y: 2.5 + main), shoulder = Point2(x: main, y: 2.5), waist = Point2(x: main, y: filletCenter.y)
        let foot = Point2(x: tinyCenter.x, y: 0)
        // The right half, top to bottom, then its mirror image back up.
        let right: [(Point2, Point2?)] = [
            (top, mid(Point2(x: 0, y: 2.5), main, top, shoulder)),
            (shoulder, nil),
            (waist, mid(filletCenter, fillet, waist, filletOnSlot)),
            (filletOnSlot, mid(slotCenter, slotRadius, filletOnSlot, slotOnTiny)),
            (slotOnTiny, mid(tinyCenter, tiny, slotOnTiny, foot)),
            (foot, nil)
        ]
        var points: [Point2] = [], mids: [Point2?] = []
        for (point, arc) in right { points.append(point); mids.append(arc) }
        // Mirror: the edge after point i of the left half is the mirror of the edge before it on the right.
        for index in stride(from: right.count - 1, through: 1, by: -1) {
            points.append(Point2(x: -right[index].0.x, y: right[index].0.y))
            mids.append(right[index - 1].1.map { Point2(x: -$0.x, y: $0.y) })
        }
        return (points, mids)
    }

    /// A board `columns` × `rows` cells, with connector pockets on the chosen edges (only between
    /// cells, as on the official boards) and, on a Lite board, a screw hole at every inner grid corner.
    static func board(columns: Int, rows: Int, type: BoardType, pockets: Set<Edge> = Set(Edge.allCases), screwHoles: Bool = true) throws -> KernelSolid {
        let t = type.thickness, width = Double(columns) * pitch, depth = Double(rows) * pitch
        let c = boardCornerChamfer
        let outline = [Point2(x: -width / 2 + c, y: -depth / 2), Point2(x: width / 2 - c, y: -depth / 2), Point2(x: width / 2, y: -depth / 2 + c),
                       Point2(x: width / 2, y: depth / 2 - c), Point2(x: width / 2 - c, y: depth / 2), Point2(x: -width / 2 + c, y: depth / 2),
                       Point2(x: -width / 2, y: depth / 2 - c), Point2(x: -width / 2, y: -depth / 2 + c)]
        var plate = try Kernel.prism(outline, on: .top, depth: t)
        let cell = try cellVoid(type)
        var tools: [KernelSolid] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let center = SIMD3((Double(column) - Double(columns - 1) / 2) * pitch, (Double(row) - Double(rows - 1) / 2) * pitch, 0)
                tools.append(try Kernel.moved(cell, by: center))
            }
        }
        let pocket = try connectorTool(type)
        for edge in Edge.allCases where pockets.contains(edge) {
            let along = edge.isHorizontal ? columns : rows
            guard along > 1 else { continue }
            for index in 1..<along {
                let offset = (Double(index) - Double(along) / 2) * pitch
                tools.append(try Kernel.moved(pocket, by: edge.placement(at: offset, width: width, depth: depth)))
            }
        }
        if type == .lite && screwHoles && columns > 1 && rows > 1 {
            let hole = try screwTool()
            for row in 1..<rows {
                for column in 1..<columns {
                    let center = SIMD3((Double(column) - Double(columns) / 2) * pitch, (Double(row) - Double(rows) / 2) * pitch, 0)
                    tools.append(try Kernel.moved(hole, by: center))
                }
            }
        }
        // The tools are apart from each other, so they join into one compound for a single cut.
        plate = try Kernel.boolean(plate, try Kernel.unionAll(tools), .subtract)
        return plate
    }

    /// Which edge of a board: its −y (bottom), +y (top), −x (left), or +x (right) side.
    enum Edge: String, CaseIterable, Sendable {
        case bottom, top, left, right
        var isHorizontal: Bool { self == .bottom || self == .top }
        /// Places a pocket drawn on y = 0 heading +y: on this edge at `offset` along it, heading in.
        func placement(at offset: Double, width: Double, depth: Double) -> Kernel.Placement {
            switch self {
            case .bottom: Kernel.Placement(angle: 0, offset: SIMD3(offset, -depth / 2, 0))
            case .top: Kernel.Placement(angle: .pi, offset: SIMD3(offset, depth / 2, 0))
            case .left: Kernel.Placement(angle: -.pi / 2, offset: SIMD3(-width / 2, offset, 0))
            case .right: Kernel.Placement(angle: .pi / 2, offset: SIMD3(width / 2, offset, 0))
            }
        }
    }

    /// One cell's opening as a solid: the cell's square less its four rims and four corner blocks.
    static func cellVoid(_ type: BoardType) throws -> KernelSolid {
        let t = type.thickness, h = pitch / 2
        var void = try Kernel.prism([Point2(x: -h, y: -h), Point2(x: h, y: -h), Point2(x: h, y: h), Point2(x: -h, y: h)], on: .top, depth: t)
        // The rim along the −y side, drawn across it (u = y, v = z) and run the length of the cell.
        var rim = [Point2(x: -h - 1, y: 0), Point2(x: -h + self.rim, y: 0), Point2(x: -h + land, y: chamfer), Point2(x: -h + land, y: landEnd),
                   Point2(x: -h + groove, y: grooveStart)]
        if type == .full {
            rim += [Point2(x: -h + groove, y: t - grooveStart), Point2(x: -h + land, y: t - landEnd), Point2(x: -h + land, y: t - chamfer),
                    Point2(x: -h + self.rim, y: t)]
        } else {
            rim.append(Point2(x: -h + groove, y: t))
        }
        rim.append(Point2(x: -h - 1, y: t))
        let across = SketchPlane(origin: SIMD3(-h - 1, 0, 0), xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(0, 0, 1))
        let side = try Kernel.prism(rim, on: across, depth: pitch + 2)
        // The corner block at (−h, −h), drawn along the diagonal from the corner (u) and up (v).
        let s0 = cornerBlock - cornerLead
        var block = [Point2(x: -1, y: 0), Point2(x: s0, y: 0), Point2(x: cornerBlock, y: cornerLead)]
        block += type == .full ? [Point2(x: cornerBlock, y: t - cornerLead), Point2(x: s0, y: t)] : [Point2(x: cornerBlock, y: t)]
        block.append(Point2(x: -1, y: t))
        let d = SIMD3(1.0, 1, 0) / 2.squareRoot(), normal = SIMD3(1.0, -1, 0) / 2.squareRoot()
        let diagonal = SketchPlane(origin: SIMD3(-h, -h, 0) - normal * pitch, xAxis: d, yAxis: SIMD3(0, 0, 1))
        let corner = try Kernel.prism(block, on: diagonal, depth: 2 * pitch)
        for quarter in 0..<4 {
            let turn = Kernel.Placement(angle: Double(quarter) * .pi / 2, offset: .zero)
            void = try Kernel.boolean(void, try Kernel.moved(side, by: turn), .subtract)
            void = try Kernel.boolean(void, try Kernel.moved(corner, by: turn), .subtract)
        }
        return void
    }

    static func connectorTool(_ type: BoardType) throws -> KernelSolid {
        let pocket = connectorPocket()
        let floor = SketchPlane(origin: SIMD3(0, 0, type.pocketFloor), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        return try Kernel.profilePrism(pocket.points, mids: pocket.mids, on: floor, depth: 2.4)
    }

    /// A Lite screw hole at the origin, from the front (z = 0) through the 4 mm board.
    static func screwTool() throws -> KernelSolid {
        let r = screwCounterbore.radius, cb = screwCounterbore.depth, sink = cb + (r - screwHole)
        let section = [Point2(x: 0, y: -1), Point2(x: r, y: -1), Point2(x: r, y: cb), Point2(x: screwHole, y: sink),
                       Point2(x: screwHole, y: BoardType.lite.thickness + 1), Point2(x: 0, y: BoardType.lite.thickness + 1)]
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1))
        return try Kernel.revolve(section, on: plane)
    }
}

/// openGrid's official parts, as its files define them (Tests/Fixtures/OpenGrid): each solid moved
/// so it is centered on the origin, and otherwise unchanged. The shapes are stored in
/// OpenGridPartData.swift, which Scripts/update_opengrid_parts.sh writes from the fixtures.
enum OpenGridPart: String, CaseIterable, Sendable {
    case connector, liteConnector, wallMount, liteWallMount, openWallMount, openWallMountCover
    case screwSnap, directionalScrewSnap, liteScrewSnap, liteDirectionalScrewSnap

    /// The official file it comes from, in Tests/Fixtures/OpenGrid.
    var sourceFile: String {
        switch self {
        case .connector: "openGrid Edge Connector.step"
        case .liteConnector: "openGrid Lite Connector.step"
        case .wallMount: "openGrid Wall Mount.step"
        case .liteWallMount: "openGrid Lite Wall Mount.step"
        case .openWallMount: "openGrid Open Wall Mount.step"
        case .openWallMountCover: "openGrid Color_Cover Snap for Open Wall Mount.step"
        case .screwSnap: "openGrid M3 Nut Snap.step"
        case .directionalScrewSnap: "openGrid M3 Nut Directional Snap v2.step"
        case .liteScrewSnap: "openGrid Lite M3 Nut Snap.step"
        case .liteDirectionalScrewSnap: "openGrid Lite M3 Nut Directional Snap.step"
        }
    }

    /// Its name in the project's stored shapes.
    var title: String { "openGrid " + sourceFile.replacingOccurrences(of: ".step", with: "").replacingOccurrences(of: "openGrid ", with: "") }

    /// The stored shape, the same id and bytes in every project.
    var shape: ImportedShape {
        get throws {
            guard let packed = Data(base64Encoded: OpenGridPartData.shapes[self] ?? ""),
                  let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else {
                throw SolidKernel.Failure(message: "The openGrid part could not be read")
            }
            return ImportedShape(id: OpenGrid.stableID("opengrid.part." + rawValue), name: title, data: data)
        }
    }

    static func screwSnap(_ type: OpenGrid.BoardType, directional: Bool) -> OpenGridPart {
        switch (type, directional) {
        case (.full, false): .screwSnap
        case (.full, true): .directionalScrewSnap
        case (.lite, false): .liteScrewSnap
        case (.lite, true): .liteDirectionalScrewSnap
        }
    }
}

extension OpenGrid {
    /// A UUID that always comes out the same for `key`, so a stored shape keeps one id in every
    /// project and preview (ImportedShapes keeps an id's bytes for the session).
    static func stableID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A solid made from a stored shape, placed with its origin at `position`, turned `angle` about z.
    static func body(_ shape: ImportedShape, at position: SIMD3<Double>, angle: Double = 0) throws -> SolidBody {
        let solid = try ImportedShapes.shared.solid(registering: shape)
        var body = SolidBody.fromImport(shape, solid: solid)
        let c = cos(angle), s = sin(angle)
        body.profile.plane = SketchPlane(origin: position, xAxis: SIMD3(c, s, 0), yAxis: SIMD3(-s, c, 0))
        return body
    }

    /// The stored shape of a board, its id following from its options.
    static func boardShape(columns: Int, rows: Int, type: BoardType, pockets: Set<Edge>, screwHoles: Bool) throws -> ImportedShape {
        let edges = Edge.allCases.filter(pockets.contains).map(\.rawValue).joined(separator: ",")
        let key = "opengrid.board.\(type.rawValue).\(columns)x\(rows).\(edges).\(screwHoles && type == .lite)"
        let id = stableID(key)
        if let known = ImportedShapes.shared.storedShape(id) { return known }
        let solid = try board(columns: columns, rows: rows, type: type, pockets: pockets, screwHoles: screwHoles)
        let shape = ImportedShape(id: id, name: "openGrid \(type.title) Board \(columns) × \(rows)", data: try solid.shapeData())
        ImportedShapes.shared.register([shape], solids: [shape.id: solid])
        return shape
    }
}

/// Thin wrappers over the facade for building exact shapes in code.
enum Kernel {
    struct Placement {
        /// A turn about z, then a move.
        var angle: Double
        var offset: SIMD3<Double>
        var matrix: [Double] {
            let c = cos(angle), s = sin(angle)
            return [c, -s, 0, offset.x, s, c, 0, offset.y, 0, 0, 1, offset.z]
        }
    }

    static func make(_ body: () -> OpaquePointer?) throws -> KernelSolid {
        guard let pointer = body() else {
            throw SolidKernel.Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Kernel operation failed")
        }
        return KernelSolid(adopting: pointer)
    }

    static func prism(_ points: [Point2], on plane: SketchPlane, depth: Double) throws -> KernelSolid {
        let xy = points.flatMap { [$0.x, $0.y] }
        return try make { ssk_extrude_polygon(plane.kernelPlane, xy, Int32(points.count), depth) }
    }

    static func profilePrism(_ points: [Point2], mids: [Point2?], on plane: SketchPlane, depth: Double) throws -> KernelSolid {
        let xy = points.flatMap { [$0.x, $0.y] }, arcs = mids.flatMap { $0.map { [$0.x, $0.y] } ?? [.nan, .nan] }
        return try make { ssk_extrude_profile(plane.kernelPlane, xy, arcs, Int32(points.count), depth) }
    }

    /// A full turn of a section drawn with u ≥ 0 about the plane's v axis.
    static func revolve(_ points: [Point2], on plane: SketchPlane) throws -> KernelSolid {
        let xy = points.flatMap { [$0.x, $0.y] }
        return try make { ssk_revolve_profile(plane.kernelPlane, xy, nil, Int32(points.count), 0, 0, 0, 1, 360) }
    }

    static func moved(_ solid: KernelSolid, by placement: Placement) throws -> KernelSolid {
        let m = placement.matrix
        return try make { ssk_moved(solid.handle, m) }
    }

    static func moved(_ solid: KernelSolid, by offset: SIMD3<Double>) throws -> KernelSolid {
        try moved(solid, by: Placement(angle: 0, offset: offset))
    }

    static func transformed(_ solid: KernelSolid, _ matrix: [Double]) throws -> KernelSolid {
        try make { ssk_transform(solid.handle, matrix) }
    }

    static func boolean(_ a: KernelSolid, _ b: KernelSolid, _ operation: SolidKernel.BooleanOperation) throws -> KernelSolid {
        try SolidKernel.boolean(a, b, operation)
    }

    /// Joins solids pairwise, in halves, so each join is between shapes of about the same size.
    static func unionAll(_ solids: [KernelSolid]) throws -> KernelSolid {
        guard !solids.isEmpty else { throw SolidKernel.Failure(message: "Nothing to join") }
        var level = solids
        while level.count > 1 {
            var next: [KernelSolid] = []
            for index in stride(from: 0, to: level.count, by: 2) {
                next.append(index + 1 < level.count ? try boolean(level[index], level[index + 1], .union) : level[index])
            }
            level = next
        }
        return level[0]
    }
}
