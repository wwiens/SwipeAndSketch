import Foundation
import MachO

/// Whether this build is signed with the Private Cloud Compute entitlement. The framework reports
/// the cloud model as available either way, but a request from a build without the entitlement
/// (unsigned test builds, another team's signing) stops the app with a fatal error, so the
/// assistant checks its own code signature first.
enum PrivateCloudEntitlement {
    static let key = "com.apple.developer.private-cloud-compute"

    static let isPresent: Bool = {
        guard let entitlements = signedEntitlements() else { return false }
        return entitlements[key] as? Bool == true
    }()

    /// The entitlements in the main executable's code signature (nil when it has none).
    static func signedEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return entitlements(inExecutable: data)
    }

    static func entitlements(inExecutable data: Data) -> [String: Any]? {
        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : value
        }
        // A thin 64-bit Mach-O, or the matching slice of a universal binary.
        var base = 0
        if u32(0, bigEndian: true) == FAT_MAGIC, let count = u32(4, bigEndian: true) {
            base = -1
            for index in 0..<Int(count) {
                let entry = 8 + index * 20
                guard let cpu = u32(entry, bigEndian: true), let offset = u32(entry + 8, bigEndian: true) else { return nil }
                if cpu == UInt32(CPU_TYPE_ARM64) { base = Int(offset); break }
            }
            guard base >= 0 else { return nil }
        }
        guard u32(base) == MH_MAGIC_64, let commandCount = u32(base + 16) else { return nil }
        var command = base + 32, signed: [String: Any]?
        for _ in 0..<commandCount {
            guard let kind = u32(command), let size = u32(command + 4), size >= 8 else { return nil }
            if kind == UInt32(LC_CODE_SIGNATURE), let offset = u32(command + 8) {
                signed = entitlements(inSignatureAt: base + Int(offset), of: data, read: u32)
            } else if kind == UInt32(LC_SEGMENT_64), let simulated = simulatorEntitlements(segmentAt: command, base: base, of: data, read: u32) {
                // Simulator builds carry their entitlements in a __TEXT,__entitlements section.
                return simulated
            }
            command += Int(size)
        }
        return signed
    }

    private static func simulatorEntitlements(segmentAt command: Int, base: Int, of data: Data, read u32: (Int, Bool) -> UInt32?) -> [String: Any]? {
        func name(_ offset: Int) -> String {
            guard offset + 16 <= data.count else { return "" }
            return String(decoding: data[offset..<(offset + 16)].prefix { $0 != 0 }, as: UTF8.self)
        }
        guard name(command + 8) == "__TEXT", let sections = u32(command + 64, false) else { return nil }
        for index in 0..<Int(sections) {
            let section = command + 72 + index * 80
            guard name(section) == "__entitlements", let size = u32(section + 40, false), let offset = u32(section + 48, false),
                  size > 0, base + Int(offset) + Int(size) <= data.count else { continue }
            let xml = data.subdata(in: (base + Int(offset))..<(base + Int(offset) + Int(size)))
            return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
        }
        return nil
    }

    /// Finds the XML entitlements blob (slot 5) in a code signature superblob.
    private static func entitlements(inSignatureAt start: Int, of data: Data, read u32: (Int, Bool) -> UInt32?) -> [String: Any]? {
        guard u32(start, true) == 0xFADE0CC0, let count = u32(start + 8, true) else { return nil }
        for index in 0..<Int(count) {
            let entry = start + 12 + index * 8
            guard let slot = u32(entry, true), let offset = u32(entry + 4, true) else { return nil }
            let blob = start + Int(offset)
            guard slot == 5, u32(blob, true) == 0xFADE7171, let length = u32(blob + 4, true), length > 8,
                  blob + Int(length) <= data.count else { continue }
            let xml = data.subdata(in: (blob + 8)..<(blob + Int(length)))
            return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
        }
        return nil
    }
}
