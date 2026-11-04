import Compression
import Foundation
import simd

/// Print-ready exports of the document's solids, in millimeters, built from the kernel's exact
/// solids (never from display meshes). STL is one binary file of all solids; 3MF keeps each
/// solid as its own object. Meshes are welded so shared edges use shared vertices (manifold).
enum ModelExport {
    enum Format: String, CaseIterable, Sendable {
        case threeMF = "3mf", stl
        var title: String { self == .threeMF ? "3MF" : "STL" }
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Finer than display: 0.01 mm chordal and 5° angular keep small holes round.
    static let linearDeflection = 0.01
    static let angularDeflection = 5 * Double.pi / 180

    struct Mesh: Equatable {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<UInt32>] = []
    }

    static func data(_ format: Format, bodies: [SolidBody], title: String) throws -> Data {
        switch format {
        case .stl: try stl(bodies)
        case .threeMF: try threeMF(bodies, title: title)
        }
    }

    /// A solid to print and the name it is shown with.
    struct PrintPart: Sendable {
        var body: SolidBody
        var name: String
    }

    /// One welded, outward-wound triangle mesh per solid.
    static func meshes(_ bodies: [SolidBody]) throws -> [Mesh] {
        guard !bodies.isEmpty else { throw Failure(message: "There are no solids to export.") }
        return try bodies.enumerated().map { index, body in
            let solid: KernelSolid
            do { solid = try SolidKernel.solid(for: body) } catch {
                throw Failure(message: "Solid \(index + 1) could not be built: \(error.localizedDescription)")
            }
            return weld(try solid.tessellate(linearDeflection: linearDeflection, angularDeflection: angularDeflection))
        }
    }

    static func weld(_ source: KernelMesh) -> Mesh {
        struct Key: Hashable { var x, y, z: Int64 }
        var mesh = Mesh()
        var index: [Key: UInt32] = [:]
        func id(_ p: SIMD3<Float>) -> UInt32 {
            let key = Key(x: Int64((Double(p.x) * 1e5).rounded()), y: Int64((Double(p.y) * 1e5).rounded()), z: Int64((Double(p.z) * 1e5).rounded()))
            if let existing = index[key] { return existing }
            let new = UInt32(mesh.vertices.count)
            mesh.vertices.append(p)
            index[key] = new
            return new
        }
        let ids = source.positions.map(id)
        for t in 0..<source.triangleCount {
            let tri = SIMD3(ids[Int(source.indices[3 * t])], ids[Int(source.indices[3 * t + 1])], ids[Int(source.indices[3 * t + 2])])
            // Drop slivers that collapse when welded.
            if tri.x != tri.y && tri.y != tri.z && tri.x != tri.z { mesh.triangles.append(tri) }
        }
        return mesh
    }

    /// Binary STL: 80-byte header, triangle count, then normal + 3 vertices + attribute per triangle.
    static func stl(_ bodies: [SolidBody]) throws -> Data {
        let meshes = try meshes(bodies)
        var data = Data(capacity: 84 + meshes.reduce(0) { $0 + $1.triangles.count } * 50)
        var header = Array("Swipe & Sketch binary STL, millimeters".utf8)
        header += [UInt8](repeating: 0x20, count: 80 - header.count)
        data.append(contentsOf: header)
        append(UInt32(meshes.reduce(0) { $0 + $1.triangles.count }), to: &data)
        for mesh in meshes {
            for tri in mesh.triangles {
                let a = mesh.vertices[Int(tri.x)], b = mesh.vertices[Int(tri.y)], c = mesh.vertices[Int(tri.z)]
                let n = simd_cross(b - a, c - a)
                let normal = simd_length(n) > 0 ? simd_normalize(n) : .zero
                for v in [normal, a, b, c] { for component in [v.x, v.y, v.z] { append(component.bitPattern, to: &data) } }
                data.append(contentsOf: [0, 0])
            }
        }
        return data
    }

    /// 3MF core package (OPC zip): one mesh object per solid, unit millimeter, named "Solid n" and
    /// left where it was modeled.
    static func threeMF(_ bodies: [SolidBody], title: String) throws -> Data {
        try threeMF(bodies.enumerated().map { PrintPart(body: $1, name: "Solid \($0 + 1)") }, title: title, layout: nil, thumbnail: nil)
    }

    /// A print-ready 3MF: each part a named object (named as in the Model Tree, which slicers show
    /// in their object lists), placed on the plate by `layout`, with a preview picture when given.
    static func threeMF(_ parts: [PrintPart], title: String, layout: PrintLayout?, thumbnail: Data?, date: Date = Date()) throws -> Data {
        let meshes = try meshes(parts.map(\.body))
        let offsets = layout.map { PrintLayout.Placement.offsets(for: meshes.map(bounds), layout: $0).offsets } ?? meshes.map { _ in .zero }
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">"#,
            " <metadata name=\"Title\">\(escape(title))</metadata>",
            " <metadata name=\"Application\">Swipe &amp; Sketch</metadata>",
            " <metadata name=\"CreationDate\">\(day)</metadata>",
            " <metadata name=\"ModificationDate\">\(day)</metadata>",
            " <metadata name=\"Description\">\(parts.count == 1 ? "1 part" : "\(parts.count) parts"), millimeters</metadata>",
            " <resources>"]
        lines.reserveCapacity(meshes.reduce(16) { $0 + $1.vertices.count + $1.triangles.count + 8 })
        // Colored solids (Naming.swift) carry their color as a base material, which slicers read
        // for multicolor prints. The materials resource takes the id after the objects'.
        let colors = parts.map { $0.body.color ?? .gray }
        let palette = parts.contains { $0.body.color != nil } ? BodyColor.allCases.filter(colors.contains) : []
        let materials = parts.count + 1
        if !palette.isEmpty {
            lines.append("  <basematerials id=\"\(materials)\">")
            for color in palette { lines.append("   <base name=\"\(color.title)\" displaycolor=\"\(color.hex)FF\"/>") }
            lines.append("  </basematerials>")
        }
        for (offset, mesh) in meshes.enumerated() {
            let material = palette.firstIndex(of: colors[offset]).map { " pid=\"\(materials)\" pindex=\"\($0)\"" } ?? ""
            lines.append("  <object id=\"\(offset + 1)\" type=\"model\" name=\"\(escape(parts[offset].name))\"\(material)>")
            lines.append("   <mesh>")
            lines.append("    <vertices>")
            for v in mesh.vertices { lines.append("     <vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>") }
            lines.append("    </vertices>")
            lines.append("    <triangles>")
            for t in mesh.triangles { lines.append("     <triangle v1=\"\(t.x)\" v2=\"\(t.y)\" v3=\"\(t.z)\"/>") }
            lines.append("    </triangles>")
            lines.append("   </mesh>")
            lines.append("  </object>")
        }
        lines.append(" </resources>")
        lines.append(" <build>")
        for (index, move) in offsets.enumerated() {
            // Placed by the item's transform (3MF rows: the last three numbers are the translation).
            let transform = move == .zero ? "" : " transform=\"1 0 0 0 1 0 0 0 1 \(number(move.x)) \(number(move.y)) \(number(move.z))\""
            lines.append("  <item objectid=\"\(index + 1)\"\(transform) printable=\"1\"/>")
        }
        lines.append(" </build>")
        lines.append("</model>")
        let model = lines.joined(separator: "\n") + "\n"
        let pngType = thumbnail == nil ? "" : #"<Default Extension="png" ContentType="image/png"/>"#
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\(pngType)</Types>
        """
        let thumbnailRelationship = thumbnail == nil ? "" :
            #"<Relationship Target="/Metadata/thumbnail.png" Id="rel1" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>"#
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\(thumbnailRelationship)</Relationships>
        """
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(relationships.utf8))
        zip.add("3D/3dmodel.model", Data(model.utf8))
        if let thumbnail { zip.add("Metadata/thumbnail.png", thumbnail) }
        return zip.finish()
    }

    /// The box around a mesh.
    static func bounds(_ mesh: Mesh) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
        for v in mesh.vertices {
            let p = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            low = simd_min(low, p); high = simd_max(high, p)
        }
        return mesh.vertices.isEmpty ? (.zero, .zero) : (low, high)
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == 0 ? "0" : String(rounded)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    fileprivate static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Minimal zip archive writer (deflate via Apple's Compression, stored if that would not shrink).
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        let deflated = Self.deflate(content)
        let (method, payload): (UInt16, Data) = deflated.map { $0.count < content.count ? (8, $0) : (0, content) } ?? (0, content)
        let offset = UInt32(data.count)
        func header(_ out: inout Data, central: Bool) {
            ModelExport.append(UInt32(central ? 0x0201_4b50 : 0x0403_4b50), to: &out)
            if central { ModelExport.append(UInt16(20), to: &out) }       // version made by
            ModelExport.append(UInt16(20), to: &out)                       // version needed
            ModelExport.append(UInt16(0x0800), to: &out)                   // UTF-8 names
            ModelExport.append(method, to: &out)
            ModelExport.append(UInt16(0), to: &out); ModelExport.append(UInt16(0x21), to: &out)   // time, date (1980-01-01)
            ModelExport.append(crc, to: &out)
            ModelExport.append(UInt32(payload.count), to: &out)
            ModelExport.append(UInt32(content.count), to: &out)
            ModelExport.append(UInt16(name.count), to: &out)
            ModelExport.append(UInt16(0), to: &out)                        // extra length
            if central {
                ModelExport.append(UInt16(0), to: &out)                    // comment length
                ModelExport.append(UInt16(0), to: &out)                    // disk number
                ModelExport.append(UInt16(0), to: &out)                    // internal attributes
                ModelExport.append(UInt32(0), to: &out)                    // external attributes
                ModelExport.append(offset, to: &out)
            }
            out.append(name)
        }
        header(&data, central: false)
        data.append(payload)
        header(&central, central: true)
        count += 1
    }

    func finish() -> Data {
        var out = data
        let directoryOffset = UInt32(out.count)
        out.append(central)
        ModelExport.append(UInt32(0x0605_4b50), to: &out)
        ModelExport.append(UInt16(0), to: &out); ModelExport.append(UInt16(0), to: &out)
        ModelExport.append(count, to: &out); ModelExport.append(count, to: &out)
        ModelExport.append(UInt32(central.count), to: &out)
        ModelExport.append(directoryOffset, to: &out)
        ModelExport.append(UInt16(0), to: &out)
        return out
    }

    /// Raw DEFLATE (Compression's ZLIB algorithm writes no zlib header, as zip expects).
    private static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? output.prefix(written) : nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

/// Where exported parts sit on the printer's plate (in the slicer's plate coordinates: the origin
/// at a front corner, the plate's center at half its size). Slicers drop parts onto the plate, but
/// parts off it or overlapping get in the way, so a print-ready file places them.
struct PrintLayout: Equatable, Sendable {
    enum Placement: String, CaseIterable, Sendable {
        /// Side by side, each resting on the plate, the group centered.
        case arranged
        /// As modeled, the whole group lifted onto the plate and centered.
        case asModeled
        var title: String { self == .arranged ? "Arrange on Plate" : "As Modeled" }
    }
    var placement = Placement.arranged
    /// Plate width (x) and depth (y), in millimeters.
    var bed = SIMD2<Double>(256, 256)
    var spacing = 5.0

    /// Common plates. Names say which printers use them; any size can be typed instead.
    static let beds: [(title: String, size: SIMD2<Double>)] = [
        ("256 × 256 mm (Bambu Lab X1, P1, A1)", [256, 256]), ("180 × 180 mm (Bambu Lab A1 mini, Prusa MINI)", [180, 180]),
        ("250 × 210 mm (Prusa MK4, MK3)", [250, 210]), ("220 × 220 mm (Creality Ender-3)", [220, 220]),
        ("300 × 300 mm", [300, 300]), ("350 × 350 mm", [350, 350])]
}

extension PrintLayout.Placement {
    /// How far to move each part (by its box), and whether they all fit on the plate.
    static func offsets(for boxes: [(min: SIMD3<Double>, max: SIMD3<Double>)], layout: PrintLayout) -> (offsets: [SIMD3<Double>], fits: Bool) {
        guard !boxes.isEmpty else { return ([], true) }
        let center = SIMD2(layout.bed.x / 2, layout.bed.y / 2)
        switch layout.placement {
        case .asModeled:
            let low = boxes.map(\.min).reduce(SIMD3(repeating: .infinity), simd_min)
            let high = boxes.map(\.max).reduce(SIMD3(repeating: -.infinity), simd_max)
            let move = SIMD3(center.x - (low.x + high.x) / 2, center.y - (low.y + high.y) / 2, -low.z)
            return (boxes.map { _ in move }, high.x - low.x <= layout.bed.x && high.y - low.y <= layout.bed.y)
        case .arranged:
            // Shelves: deepest parts first, left to right, a new row when the plate is full.
            let order = boxes.indices.sorted { (boxes[$0].max.y - boxes[$0].min.y) > (boxes[$1].max.y - boxes[$1].min.y) }
            var spots = [SIMD2<Double>](repeating: .zero, count: boxes.count)
            var x = 0.0, y = 0.0, rowDepth = 0.0, width = 0.0
            for index in order {
                let size = SIMD2(boxes[index].max.x - boxes[index].min.x, boxes[index].max.y - boxes[index].min.y)
                if x > 0 && x + size.x > layout.bed.x { x = 0; y += rowDepth + layout.spacing; rowDepth = 0 }
                spots[index] = SIMD2(x, y)
                x += size.x + layout.spacing
                width = max(width, x - layout.spacing)
                rowDepth = max(rowDepth, size.y)
            }
            let depth = y + rowDepth
            let start = SIMD2(center.x - width / 2, center.y - depth / 2)
            let offsets = boxes.indices.map { index in
                SIMD3(start.x + spots[index].x - boxes[index].min.x, start.y + spots[index].y - boxes[index].min.y, -boxes[index].min.z)
            }
            return (offsets, width <= layout.bed.x && depth <= layout.bed.y)
        }
    }
}
