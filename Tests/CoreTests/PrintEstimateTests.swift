import XCTest
import simd
@testable import SwipeAndSketchCore

/// Print estimates (filament weight, length, and cost) and the parts list.
final class PrintEstimateTests: XCTestCase {
    func testWallsAndInfillMakeUpThePlastic() {
        var settings = FilamentSettings()
        settings.infill = 0.2
        settings.wallThickness = 1
        settings.pricePerKilogram = 25
        // A 20 mm cube: 8000 mm³, 2400 mm² of faces, so 2400 mm³ of walls and 20% of the other 5600.
        let estimate = PrintEstimate(volume: 8000, surfaceArea: 2400, settings: settings)
        XCTAssertEqual(estimate.printedVolume, 2400 + 0.2 * 5600, accuracy: 1e-9)
        XCTAssertEqual(estimate.grams, 3.52 * 1.24, accuracy: 1e-9, "PLA, 1.24 g/cm³")
        XCTAssertEqual(estimate.cost, estimate.grams / 1000 * 25, accuracy: 1e-12)
        let crossSection = Double.pi * 1.75 * 1.75 / 4
        XCTAssertEqual(estimate.meters, 3520 / crossSection / 1000, accuracy: 1e-9)
    }

    func testThinPartsAreAllWallAndFullInfillIsTheWholeVolume() {
        var settings = FilamentSettings()
        settings.infill = 0
        // A 1 mm plate is walls right through: never more plastic than the part.
        let plate = PrintEstimate(volume: 100, surfaceArea: 240, settings: settings)
        XCTAssertEqual(plate.printedVolume, 100, accuracy: 1e-9)
        settings.infill = 1
        let solid = PrintEstimate(volume: 8000, surfaceArea: 2400, settings: settings)
        XCTAssertEqual(solid.printedVolume, 8000, accuracy: 1e-9)
    }

    func testMaterialsAndCustomDensity() {
        var settings = FilamentSettings()
        settings.material = .petg
        XCTAssertEqual(settings.density, 1.27)
        settings.material = .custom
        settings.customDensity = 1.5
        XCTAssertEqual(settings.density, 1.5)
        XCTAssertEqual(settings.summary, "1.5 g/cm³, 15% infill")
        settings.material = .abs
        XCTAssertEqual(settings.summary, "ABS, 15% infill")
        XCTAssertTrue(FilamentSettings.Material.allCases.allSatisfy { $0 == .custom || $0.density != nil })
    }

    func testSettingsAreStoredAndCheckedOnReading() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PrintEstimateTests-\(UUID().uuidString)"))
        XCTAssertEqual(FilamentSettings.stored(in: defaults), FilamentSettings(), "Defaults when nothing is stored")
        var settings = FilamentSettings()
        settings.material = .tpu
        settings.pricePerKilogram = 32.5
        settings.diameter = 2.85
        settings.infill = 0.4
        settings.wallThickness = 1.2
        settings.store(in: defaults)
        XCTAssertEqual(FilamentSettings.stored(in: defaults), settings)
        // Values out of range fall back to the defaults rather than giving nonsense.
        defaults.set(-4.0, forKey: FilamentSettings.priceKey)
        defaults.set(1.0, forKey: FilamentSettings.diameterKey)
        defaults.set(3.0, forKey: FilamentSettings.infillKey)
        defaults.set("wood", forKey: FilamentSettings.materialKey)
        let read = FilamentSettings.stored(in: defaults)
        XCTAssertEqual(read.pricePerKilogram, 20)
        XCTAssertEqual(read.diameter, 1.75)
        XCTAssertEqual(read.infill, 0.15)
        XCTAssertEqual(read.material, .pla)
        XCTAssertEqual(read.wallThickness, 1.2)
    }

    func testPartsListMeasuresEachSolidAndTotalsThem() throws {
        let big = try box(0, 0, 40, 20, depth: 10)
        let small = try box(50, 0, 60, 10, depth: 5)
        let settings = FilamentSettings()
        let entries = PartsList.entries([(big, "Base"), (small, "Lid, small")], settings: settings)
        XCTAssertEqual(entries.map(\.name), ["Base", "Lid, small"])
        XCTAssertEqual(entries[0].size.x, 40, accuracy: 1e-6)
        XCTAssertEqual(entries[0].size.y, 20, accuracy: 1e-6)
        XCTAssertEqual(entries[0].size.z, 10, accuracy: 1e-6)
        XCTAssertEqual(entries[0].estimate.volume, 8000, accuracy: 1e-3)
        let expected = PrintEstimate(volume: 8000, surfaceArea: 2 * (800 + 400 + 200), settings: settings)
        XCTAssertEqual(entries[0].estimate.grams, expected.grams, accuracy: 1e-6, "From the solid's volume and surface area")
        XCTAssertEqual(entries[0].estimate.meters, expected.meters, accuracy: 1e-6)
        let total = PartsList.total(entries)
        XCTAssertEqual(total.volume, 8000 + 500, accuracy: 1e-3)
        XCTAssertEqual(total.grams, entries[0].estimate.grams + entries[1].estimate.grams, accuracy: 1e-9)

        let csv = PartsList.csv(entries, currency: "USD").split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.count, 4)
        XCTAssertEqual(csv[0], "Part,X (mm),Y (mm),Z (mm),Volume (mm³),Filament (g),Filament (m),Cost (USD)")
        XCTAssertTrue(csv[1].hasPrefix("Base,40.00,20.00,10.00,8000.0,"))
        XCTAssertTrue(csv[2].hasPrefix("\"Lid, small\",10.00,10.00,5.00,500.0,"), "A comma in a name is quoted")
        XCTAssertTrue(csv[3].hasPrefix("Total,,,,8500.0,"))
    }

    func testEstimateText() {
        let small = PrintEstimate(volume: 0, printedVolume: 0, grams: 4.26, meters: 1.428, cost: 0.0852)
        XCTAssertEqual(small.weightText, "4.3 g")
        XCTAssertEqual(small.lengthText, "1.43 m")
        let large = PrintEstimate(volume: 0, printedVolume: 0, grams: 142.4, meters: 47.75, cost: 2.848)
        XCTAssertEqual(large.weightText, "142 g")
        XCTAssertEqual(large.lengthText, "47.8 m")
    }
}
