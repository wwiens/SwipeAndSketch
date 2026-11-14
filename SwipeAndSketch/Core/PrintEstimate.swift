import Foundation
import simd

// Print estimates: about how much filament a part takes, how much it weighs, and what it costs.
// A slicer knows the exact figure; this is the quick answer while modeling, from the solid's volume
// and surface area. A printed part is solid walls on every face around a part-filled middle, so the
// plastic is the walls (surface area × wall thickness, at most the whole volume) plus the infill's
// share of what is left. The filament settings are an app preference, like Fit Clearance, because
// they depend on the spool and the printer; projects store nothing about them.

/// The filament and slicer settings estimates use.
struct FilamentSettings: Equatable, Sendable {
    enum Material: String, CaseIterable, Sendable {
        case pla, petg, abs, asa, tpu, nylon, pc, custom
        var title: String {
            switch self {
            case .pla: "PLA"
            case .petg: "PETG"
            case .abs: "ABS"
            case .asa: "ASA"
            case .tpu: "TPU"
            case .nylon: "Nylon"
            case .pc: "PC"
            case .custom: "Custom"
            }
        }
        /// Typical density in g/cm³ (manufacturers' data sheets); Custom uses the typed density.
        var density: Double? {
            switch self {
            case .pla: 1.24
            case .petg: 1.27
            case .abs: 1.04
            case .asa: 1.07
            case .tpu: 1.21
            case .nylon: 1.14
            case .pc: 1.20
            case .custom: nil
            }
        }
    }

    var material = Material.pla
    /// g/cm³, used when the material is Custom.
    var customDensity = 1.24
    /// Spool price per kilogram, in the user's own currency.
    var pricePerKilogram = 20.0
    /// Filament diameter in millimeters (1.75 or 2.85).
    var diameter = 1.75
    /// Infill, 0…1.
    var infill = 0.15
    /// Solid plastic under every face, in millimeters (perimeters and top and bottom layers).
    var wallThickness = 0.8

    static let densityRange = 0.5...3.0
    static let priceRange = 0.0...10_000.0
    static let diameters = [1.75, 2.85]
    static let infillRange = 0.0...1.0
    static let wallRange = 0.2...5.0

    /// g/cm³.
    var density: Double { material.density ?? customDensity }

    /// "PLA, 15% infill": what an estimate assumed.
    var summary: String {
        "\(material == .custom ? "\(Self.number(density, digits: 2)) g/cm³" : material.title), \(Int((infill * 100).rounded()))% infill"
    }

    // Stored as app preferences (UserDefaults), each checked on reading.
    static let materialKey = "filament.material", densityKey = "filament.density", priceKey = "filament.price",
               diameterKey = "filament.diameter", infillKey = "filament.infill", wallKey = "filament.walls"
    static let keys = [materialKey, densityKey, priceKey, diameterKey, infillKey, wallKey]

    static var stored: FilamentSettings { stored(in: .standard) }
    static func stored(in defaults: UserDefaults) -> FilamentSettings {
        var settings = FilamentSettings()
        if let material = defaults.string(forKey: materialKey).flatMap(Material.init) { settings.material = material }
        func value(_ key: String, in range: ClosedRange<Double>) -> Double? {
            guard defaults.object(forKey: key) != nil else { return nil }
            let stored = defaults.double(forKey: key)
            return stored.isFinite && range.contains(stored) ? stored : nil
        }
        if let density = value(densityKey, in: densityRange) { settings.customDensity = density }
        if let price = value(priceKey, in: priceRange) { settings.pricePerKilogram = price }
        if let diameter = value(diameterKey, in: 1...3), diameters.contains(diameter) { settings.diameter = diameter }
        if let infill = value(infillKey, in: infillRange) { settings.infill = infill }
        if let walls = value(wallKey, in: wallRange) { settings.wallThickness = walls }
        return settings
    }
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(material.rawValue, forKey: Self.materialKey)
        defaults.set(customDensity, forKey: Self.densityKey)
        defaults.set(pricePerKilogram, forKey: Self.priceKey)
        defaults.set(diameter, forKey: Self.diameterKey)
        defaults.set(infill, forKey: Self.infillKey)
        defaults.set(wallThickness, forKey: Self.wallKey)
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...digits)))
    }
}

/// About how much plastic a part (or several) takes to print.
struct PrintEstimate: Equatable, Sendable {
    /// The model's own volume, mm³.
    var volume = 0.0
    /// The plastic printed, mm³: the walls plus the infill's share of the middle.
    var printedVolume = 0.0
    /// Grams of filament.
    var grams = 0.0
    /// Meters of filament off the spool.
    var meters = 0.0
    /// In the currency the price per kilogram was typed in.
    var cost = 0.0

    static let zero = PrintEstimate()

    /// One solid's estimate from its volume and surface area (mm³ and mm²).
    init(volume: Double, surfaceArea: Double, settings: FilamentSettings) {
        let volume = max(0, volume)
        let walls = min(volume, max(0, surfaceArea) * settings.wallThickness)
        let printed = walls + settings.infill * (volume - walls)
        let grams = printed / 1000 * settings.density
        let crossSection = Double.pi * settings.diameter * settings.diameter / 4
        self.init(volume: volume, printedVolume: printed, grams: grams, meters: printed / crossSection / 1000,
                  cost: grams / 1000 * settings.pricePerKilogram)
    }

    init(volume: Double = 0, printedVolume: Double = 0, grams: Double = 0, meters: Double = 0, cost: Double = 0) {
        self.volume = volume
        self.printedVolume = printedVolume
        self.grams = grams
        self.meters = meters
        self.cost = cost
    }

    static func + (a: PrintEstimate, b: PrintEstimate) -> PrintEstimate {
        PrintEstimate(volume: a.volume + b.volume, printedVolume: a.printedVolume + b.printedVolume, grams: a.grams + b.grams,
                      meters: a.meters + b.meters, cost: a.cost + b.cost)
    }

    /// "42 g" (one decimal under 10 g).
    var weightText: String { FilamentSettings.number(grams, digits: grams < 10 ? 1 : 0) + " g" }
    /// "14.1 m".
    var lengthText: String { FilamentSettings.number(meters, digits: meters < 10 ? 2 : 1) + " m" }
    /// The cost in a currency ("$0.84").
    func costText(currency: String) -> String {
        cost.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}

/// The parts list: each solid with its size and print estimate, for a cut list or a shopping list.
enum PartsList {
    struct Entry: Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        /// Across x, y, and z (the solid's box), mm.
        var size: SIMD3<Double>
        var estimate: PrintEstimate
    }

    /// Entries for named solids; a solid that does not build is left out.
    static func entries(_ parts: [(body: SolidBody, name: String)], settings: FilamentSettings) -> [Entry] {
        parts.compactMap { part in
            guard let solid = try? SolidKernel.solid(for: part.body) else { return nil }
            let box = solid.bounds
            return Entry(id: part.body.id, name: part.name, size: box.max - box.min,
                         estimate: PrintEstimate(volume: solid.volume, surfaceArea: solid.surfaceArea, settings: settings))
        }
    }

    static func total(_ entries: [Entry]) -> PrintEstimate { entries.reduce(.zero) { $0 + $1.estimate } }

    /// The list as CSV (millimeters, grams, meters, and the cost), for a spreadsheet.
    static func csv(_ entries: [Entry], currency: String) -> String {
        func cell(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func number(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
        var lines = ["Part,X (mm),Y (mm),Z (mm),Volume (mm³),Filament (g),Filament (m),Cost (\(currency))"]
        for entry in entries {
            lines.append([cell(entry.name), number(entry.size.x, 2), number(entry.size.y, 2), number(entry.size.z, 2),
                          number(entry.estimate.volume, 1), number(entry.estimate.grams, 1), number(entry.estimate.meters, 2),
                          number(entry.estimate.cost, 2)].joined(separator: ","))
        }
        let total = total(entries)
        lines.append(["Total", "", "", "", number(total.volume, 1), number(total.grams, 1), number(total.meters, 2), number(total.cost, 2)]
            .joined(separator: ","))
        return lines.joined(separator: "\n") + "\n"
    }
}
