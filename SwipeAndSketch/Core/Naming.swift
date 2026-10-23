import Foundation

// Names and colors in the Model Tree. Bodies, sketches,
// and construction planes can be renamed; unnamed ones are numbered in document order ("Body 01",
// "Sketch 02", "Plane 01") and imported solids take their file's name. A name already used gets
// " (2)", " (3)", … so every row reads differently. Solids can also be given a color, which the
// canvas shows and 3MF files carry (slicers use it for multicolor prints).

enum ItemNames {
    static let maximumLength = 60

    /// A typed name made fit to keep: trimmed and on one line, or nil when nothing is left.
    static func cleaned(_ text: String) -> String? {
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maximumLength))
    }

    static func isValid(_ name: String?) -> Bool { name.map { cleaned($0) == $0 } ?? true }

    /// Names for items in order: numbered ones first (so a chosen name never takes "Body 02"), then
    /// chosen ones, with " (n)" added where a name repeats.
    static func names(_ items: [(id: UUID, chosen: String?)], numbered prefix: String) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for (index, item) in items.enumerated() where item.chosen == nil { names[item.id] = String(format: "\(prefix) %02d", index + 1) }
        var used = Set(names.values.map { $0.lowercased() })
        for item in items {
            guard let base = item.chosen else { continue }
            var name = base, count = 1
            while used.contains(name.lowercased()) { count += 1; name = "\(base) (\(count))" }
            used.insert(name.lowercased())
            names[item.id] = name
        }
        return names
    }
}

extension Workspace {
    /// "Body 01", a solid's chosen name, or the file an imported solid came from.
    var bodyNames: [UUID: String] {
        let imported = Dictionary(importedShapes.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return ItemNames.names(bodies.map { ($0.id, $0.name ?? $0.imported.flatMap { imported[$0.shape] }) }, numbered: "Body")
    }
    var sketchNames: [UUID: String] { ItemNames.names(sketches.map { ($0.id, $0.name) }, numbered: "Sketch") }
    var planeNames: [UUID: String] { ItemNames.names(constructionPlanes.map { ($0.id, $0.name) }, numbered: "Plane") }

    /// Renames a solid, sketch, or construction plane (an empty name goes back to its number).
    func renaming(body id: UUID, to name: String) -> Workspace? {
        guard let index = bodies.firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        result.bodies[index].name = ItemNames.cleaned(name)
        return result
    }
    func renaming(sketch id: UUID, to name: String) -> Workspace? {
        guard let index = sketches.firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        result.sketches[index].name = ItemNames.cleaned(name)
        return result
    }
    func renaming(plane id: UUID, to name: String) -> Workspace? {
        guard let index = constructionPlanes.firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        result.constructionPlanes[index].name = ItemNames.cleaned(name)
        return result
    }
}

/// A solid's color: the familiar filament colors, so a model can be planned for a multicolor print.
/// Gray, the default, is not saved.
enum BodyColor: String, Codable, CaseIterable, Sendable {
    case gray, white, black, red, orange, yellow, green, blue, purple, pink
    var title: String { rawValue.capitalized }
    /// sRGB, 0…1, as the canvas shades it and 3MF files carry it.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .gray: (0.62, 0.62, 0.62)
        case .white: (0.93, 0.93, 0.91)
        case .black: (0.18, 0.18, 0.2)
        case .red: (0.86, 0.22, 0.2)
        case .orange: (0.96, 0.52, 0.16)
        case .yellow: (0.97, 0.8, 0.2)
        case .green: (0.27, 0.66, 0.33)
        case .blue: (0.2, 0.42, 0.85)
        case .purple: (0.52, 0.32, 0.8)
        case .pink: (0.95, 0.55, 0.72)
        }
    }
    /// "#RRGGBB", as 3MF writes colors.
    var hex: String {
        let (r, g, b) = rgb
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
