import Foundation
import Compression
import SSKernel
import simd

// Mesh import (October 24, 2026): STL and 3MF files, the formats downloaded models come in, so they
// can be remixed. Each closed (watertight) mesh is sewn into an ordinary solid, its flat areas
// merged into single faces, and stored in the project like an imported STEP solid; meshes that do
// not close up are left out and counted.

enum MeshImport {
    /// Triangles as nine numbers each (three corners), in millimeters.
    struct Mesh: Equatable {
        var name: String
        var triangles: [Double]
        var count: Int { triangles.count / 9 }
    }

    static let maximumTriangles = 200_000

    /// Reads an STL or 3MF file (by its extension) into solids: as for STEP, one per closed mesh.
    static func read(_ url: URL, name: String) throws -> STEPImport.Result {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > STEPImport.maximumFileBytes {
            throw SolidKernel.Failure(message: "This file is too large to import (over \(STEPImport.maximumFileBytes / 1_048_576) MB).")
        }
        let data = try Data(contentsOf: url)
        let meshes = url.pathExtension.lowercased() == "3mf" ? try threeMF(data, name: name) : [try stl(data, name: name)]
        var result = STEPImport.Result(shapes: [], bodies: [], skipped: 0, name: name)
        for mesh in meshes {
            guard let solid = solid(from: mesh) else { result.skipped += 1; continue }
            let shape = ImportedShape(id: UUID(), name: meshes.count > 1 ? mesh.name : name, data: try solid.shapeData())
            result.shapes.append(shape)
            result.bodies.append(.fromImport(shape, solid: solid))
        }
        ImportedShapes.shared.register(result.shapes)
        guard !result.bodies.isEmpty else {
            throw SolidKernel.Failure(message: "The mesh does not close up into a solid (it has holes or loose edges). Repair it in a mesh tool, then import it again.")
        }
        return result
    }

    /// The solid a closed mesh bounds, or nil.
    static func solid(from mesh: Mesh) -> KernelSolid? {
        guard mesh.count >= 4, mesh.count <= maximumTriangles else { return nil }
        // Sewing tolerance: a little more than the rounding of the file's coordinates.
        let points = stride(from: 0, to: mesh.triangles.count, by: 3).map { SIMD3(mesh.triangles[$0], mesh.triangles[$0 + 1], mesh.triangles[$0 + 2]) }
        guard let first = points.first else { return nil }
        let span = simd_length(points.reduce(first, simd_max) - points.reduce(first, simd_min))
        let tolerance = max(1e-4, span * 1e-6)
        guard let pointer = mesh.triangles.withUnsafeBufferPointer({ ssk_solid_from_triangles($0.baseAddress, Int32(mesh.count), tolerance) }) else { return nil }
        let solid = KernelSolid(adopting: pointer)
        return solid.isValidSolid && solid.volume > 1e-9 ? solid : nil
    }

    // MARK: STL

    /// A binary or text STL file's triangles (STL has no units; millimeters, as slicers assume).
    static func stl(_ data: Data, name: String) throws -> Mesh {
        let bytes = [UInt8](data)
        // Binary: an 80-byte header, a count, then 50 bytes a triangle. Some binary files start with
        // "solid" too, so the size decides.
        if bytes.count >= 84 {
            let count = Int(UInt32(bytes[80]) | UInt32(bytes[81]) << 8 | UInt32(bytes[82]) << 16 | UInt32(bytes[83]) << 24)
            if count > 0, 84 + count * 50 == bytes.count {
                guard count <= maximumTriangles else { throw SolidKernel.Failure(message: "The mesh has \(count) triangles; at most \(maximumTriangles) can be imported.") }
                var triangles: [Double] = []
                triangles.reserveCapacity(count * 9)
                for t in 0..<count {
                    let base = 84 + t * 50 + 12
                    for v in 0..<9 {
                        let i = base + v * 4
                        let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                        triangles.append(Double(Float(bitPattern: bits)))
                    }
                }
                return Mesh(name: name, triangles: triangles)
            }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii), text.contains("vertex") else {
            throw SolidKernel.Failure(message: "This is not an STL file.")
        }
        var triangles: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first == "vertex", words.count >= 4 else { continue }
            for word in words[1...3] {
                guard let value = Double(word) else { throw SolidKernel.Failure(message: "The STL file has a bad vertex.") }
                triangles.append(value)
            }
            guard triangles.count <= maximumTriangles * 9 else { throw SolidKernel.Failure(message: "The mesh has more than \(maximumTriangles) triangles.") }
        }
        guard triangles.count >= 36, triangles.count % 9 == 0 else { throw SolidKernel.Failure(message: "The STL file has no closed mesh.") }
        return Mesh(name: name, triangles: triangles)
    }

    // MARK: 3MF

    /// The meshes of a 3MF file's build, placed by its build items, in millimeters.
    static func threeMF(_ data: Data, name: String) throws -> [Mesh] {
        let files = try Zip.entries(data)
        guard let model = files.first(where: { $0.key.lowercased().hasSuffix(".model") && $0.key.lowercased().contains("3d/") })?.value ??
                files.first(where: { $0.key.lowercased().hasSuffix(".model") })?.value else {
            throw SolidKernel.Failure(message: "This 3MF file has no model in it.")
        }
        let parser = ThreeMFParser()
        let xml = XMLParser(data: model)
        xml.delegate = parser
        guard xml.parse() else { throw SolidKernel.Failure(message: "The 3MF model could not be read.") }
        let scale: Double = ["micron": 0.001, "millimeter": 1, "centimeter": 10, "inch": 25.4, "foot": 304.8, "meter": 1000][parser.unit] ?? 1
        // Each build item places an object (or the objects it is made of); with no build, every object as it is.
        let items = parser.items.isEmpty ? parser.objects.keys.sorted().map { ($0, matrix_identity_double4x4) } : parser.items
        var meshes: [Mesh] = []
        func add(_ id: String, _ transform: simd_double4x4, depth: Int) {
            guard depth < 16, let object = parser.objects[id] else { return }
            if !object.triangles.isEmpty {
                var triangles: [Double] = []
                triangles.reserveCapacity(object.triangles.count * 9)
                for index in object.triangles {
                    guard object.vertices.indices.contains(index) else { continue }
                    let p = transform * SIMD4(object.vertices[index], 1)
                    triangles += [p.x * scale, p.y * scale, p.z * scale]
                }
                let label = object.name.isEmpty ? "\(name) \(meshes.count + 1)" : object.name
                meshes.append(Mesh(name: label, triangles: triangles))
            }
            for component in object.components { add(component.id, transform * component.transform, depth: depth + 1) }
        }
        for (id, transform) in items { add(id, transform, depth: 0) }
        guard !meshes.isEmpty else { throw SolidKernel.Failure(message: "This 3MF file has no meshes in it.") }
        guard meshes.reduce(0, { $0 + $1.count }) <= maximumTriangles else {
            throw SolidKernel.Failure(message: "The model has more than \(maximumTriangles) triangles.")
        }
        return meshes
    }

    private final class ThreeMFParser: NSObject, XMLParserDelegate {
        struct Object { var name = ""; var vertices: [SIMD3<Double>] = []; var triangles: [Int] = []; var components: [(id: String, transform: simd_double4x4)] = [] }
        var unit = "millimeter"
        var objects: [String: Object] = [:]
        var items: [(String, simd_double4x4)] = []
        private var current: String?

        static func transform(_ text: String?) -> simd_double4x4 {
            // Twelve numbers: a 3 × 3 matrix by rows, then the translation (3MF's affine form).
            let m = (text ?? "").split(separator: " ").compactMap { Double($0) }
            guard m.count == 12 else { return matrix_identity_double4x4 }
            return simd_double4x4(columns: (SIMD4(m[0], m[1], m[2], 0), SIMD4(m[3], m[4], m[5], 0), SIMD4(m[6], m[7], m[8], 0), SIMD4(m[9], m[10], m[11], 1)))
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element.split(separator: ":").last.map(String.init) ?? element {
            case "model": unit = attributes["unit"] ?? "millimeter"
            case "object":
                current = attributes["id"]
                if let id = current { objects[id] = Object(name: attributes["name"] ?? "") }
            case "vertex":
                guard let id = current, let x = attributes["x"].flatMap(Double.init), let y = attributes["y"].flatMap(Double.init),
                      let z = attributes["z"].flatMap(Double.init) else { return }
                objects[id]?.vertices.append(SIMD3(x, y, z))
            case "triangle":
                guard let id = current, let a = attributes["v1"].flatMap(Int.init), let b = attributes["v2"].flatMap(Int.init),
                      let c = attributes["v3"].flatMap(Int.init) else { return }
                objects[id]?.triangles += [a, b, c]
            case "component":
                guard let id = current, let object = attributes["objectid"] else { return }
                objects[id]?.components.append((object, Self.transform(attributes["transform"])))
            case "item":
                if let object = attributes["objectid"] { items.append((object, Self.transform(attributes["transform"]))) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if (element.split(separator: ":").last.map(String.init) ?? element) == "object" { current = nil }
        }
    }
}

/// The few parts of a ZIP archive a 3MF file needs: its entries, stored or deflated.
enum Zip {
    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // The end of central directory record, within the last 64 KB.
        guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw SolidKernel.Failure(message: "This is not a 3MF (ZIP) file.") }
        var offset = u32(end + 16)
        var result: [String: Data] = [:]
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4b50 else { break }
            let method = u16(offset + 10), compressed = u32(offset + 20), size = u32(offset + 24)
            let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32), local = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<min(bytes.count, offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extra + comment
            guard local + 30 <= bytes.count, u32(local) == 0x0403_4b50, size <= 512 * 1_048_576 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            let raw = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: result[name] = raw
            case 8:
                var output = Data(count: size)
                let written = output.withUnsafeMutableBytes { out in
                    raw.withUnsafeBytes { input in
                        compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size, input.bindMemory(to: UInt8.self).baseAddress!, compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                if written == size { result[name] = output }
            default: continue
            }
        }
        return result
    }
}
