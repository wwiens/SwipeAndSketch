import Foundation
import SSKernel
import simd

// Modeled screw threads: a hole's wall becomes a nut's
// thread and a round boss becomes a bolt's, with a real helical ISO 60° profile that prints. Saved
// as a `thread` entry in a solid's ordered `cuts` list, with its axis in the solid's own frame so it
// moves with the solid.

/// A thread's cross-section. ISO 60° is the standard for screws and nuts; Printable 45° has 90°
/// between its flanks, so each overhangs 45° whether the part prints upright or upside down (a
/// jar's base and its lid), and is shallower (October 26, 2026).
enum ThreadProfile: String, Codable, CaseIterable, Sendable {
    case iso, printable

    /// Each flank's lean from a plane square to the axis.
    var flankDegrees: Double { self == .iso ? 30 : 45 }
    /// The major diameter less the minor, in pitches (twice the thread's depth).
    var diameterLoss: Double { self == .iso ? 1.082532 : 0.6 }
    var title: String { self == .iso ? "ISO 60°" : "Printable 45°" }

    /// Raised threads, and custom threads of 20 mm and more (jar lids, caps), print best with 45°
    /// flanks; standard sizes stay ISO to fit hardware. Nil is ISO, as files store it.
    static func defaultFor(raised: Bool, majorDiameter: Double, standard: Bool) -> ThreadProfile? {
        raised || !standard && majorDiameter >= 20 ? .printable : nil
    }
}

/// A screw thread on a cylindrical face. Internal threads (a hole) open up by the clearance and
/// external ones (a boss) slim down by it, so printed threads turn freely.
struct ThreadSpec: Codable, Equatable, Sendable {
    /// A hole's thread (a nut) rather than a boss's (a bolt).
    var isInternal: Bool
    /// "M8", or empty for a custom diameter and pitch.
    var size: String
    /// Nominal major diameter and pitch, in millimeters (an ISO metric profile).
    var majorDiameter: Double
    var pitch: Double
    var clearance: Double
    /// Turns the other way (a mirror image). Omitted for ordinary right-hand threads.
    var leftHanded: Bool?
    /// The axis in the solid's own frame: the thread starts at `origin` and runs `length` along `axis`;
    /// `reference` (across the axis) fixes where the helix starts, so the thread keeps its place.
    var origin: SIMD3<Double>
    var axis: SIMD3<Double>
    var reference: SIMD3<Double>
    var length: Double
    /// The face's diameter when the thread was made: a hole is opened up to the thread, a boss turned down.
    var surfaceDiameter: Double
    /// Where the threaded face itself ends, and which ends open to air. Absent on threads made
    /// before October 21, 2026, which then take no lead-in or matching part.
    var ends: ThreadEnds?
    /// A 45° chamfer at each open end, so the thread starts without cross-threading. Omitted when off.
    var leadIn: Bool?
    /// Ridges winding side by side a pitch apart (2–4 for jar lids that close in less than a turn).
    /// Omitted for an ordinary single-start thread.
    var starts: Int?
    /// The ridges are added onto the face instead of grooves cut into it (October 22, 2026), so a
    /// thin wall keeps its thickness: a boss's face is the thread's minor diameter, a hole's its
    /// major. Omitted for a cut thread.
    var raised: Bool?
    /// The cross-section; omitted for ISO 60° (and on every thread made before October 26, 2026).
    var profile: ThreadProfile?
    /// A raised thread's ridges fade out over a quarter turn where they meet the solid (and at an
    /// open end with no lead-in) instead of stopping square. Omitted when off.
    var taperedEnds: Bool?

    private enum CodingKeys: String, CodingKey {
        case isInternal = "internal", size, majorDiameter, pitch, clearance, leftHanded, origin, axis, reference, length, surfaceDiameter, ends, leadIn, starts, raised,
             profile, taperedEnds
    }

    static let pitchRange = 0.2...20.0
    static let diameterRange = 1.0...500.0
    static let startsRange = 1...4

    var startCount: Int { starts ?? 1 }
    /// How far one turn screws it in: the pitch times the starts.
    var lead: Double { pitch * Double(startCount) }
    var isRaised: Bool { raised == true }
    var shape: ThreadProfile { profile ?? .iso }

    /// The basic minor diameter: for ISO, the major less 5/8 of the fundamental triangle's height,
    /// twice; for the printable profile, 0.3 pitch deep.
    var minorDiameter: Double { majorDiameter - shape.diameterLoss * pitch }
    /// The ridge of the thread as cut: a nut's ridge is the groove in its wall, opened up by the clearance.
    var crestRadius: Double { majorDiameter / 2 + (isInternal ? clearance : -clearance) }
    var rootRadius: Double { minorDiameter / 2 + (isInternal ? clearance : -clearance) }
    /// "M8 × 1.25", "1/4-20 UNC", or "Ø30 × 3", with the starts and hand when they are not the usual.
    var title: String {
        let base = standardSize.map { $0.title(pitch: pitch) } ?? "Ø\(Self.mm(majorDiameter)) × \(Self.mm(pitch))"
        return base + (startCount > 1 ? ", \(startCount)-start" : "") + (shape == .printable ? ", 45°" : "") + (leftHanded == true ? " LH" : "")
    }

    /// The standard size this thread is, when its name, diameter, and pitch all agree.
    var standardSize: ThreadSize? {
        guard let size = ThreadPresets.size(named: self.size), abs(size.diameter - majorDiameter) < 1e-6, size.has(pitch: pitch) else { return nil }
        return size
    }

    /// The thread's length on its face, from where the threaded face starts to where it ends.
    var threadedLength: Double { ends.map { $0.end - $0.start } ?? length }

    var isValid: Bool {
        let vectors = [origin, axis, reference]
        guard vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }), simd_length(origin) <= 200_000,
              abs(simd_length(axis) - 1) < 1e-6, simd_length(reference) > 1e-6, abs(simd_dot(simd_normalize(reference), axis)) < 0.999,
              Self.pitchRange.contains(pitch), Self.diameterRange.contains(majorDiameter), Fit.clearanceRange.contains(clearance) || clearance == 0,
              length.isFinite, length >= pitch / 2, length / pitch <= 400, surfaceDiameter.isFinite, surfaceDiameter > 0,
              starts.map(Self.startsRange.contains) ?? true else { return false }
        if let ends, !(ends.start.isFinite && ends.end.isFinite && ends.start >= 0 && ends.start < ends.end && ends.end <= length + 1e-6) { return false }
        // The profile must fit its pitch, and leave a core.
        return rootRadius > 0.1 && crestRadius - rootRadius < 0.7 * pitch
    }

    static func mm(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }

    /// Air lies beyond at least one end, so the thread can take a lead-in and a matching part.
    var hasOpenEnd: Bool { ends.map { $0.startOpen || $0.endOpen } ?? false }
}

/// The threaded face's own extent along a thread's axis, measured from the spec's `origin` (the
/// thread itself runs a little past it), and whether air lies beyond each end: a hole opening onto
/// a face, a boss's tip. A closed end is a blind hole's floor or the face a boss stands on.
struct ThreadEnds: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var startOpen: Bool
    var endOpen: Bool
}

/// A standard thread size: ISO metric (ISO 261, coarse pitch first, then the fine ones) or Unified
/// inch (UNC, then UNF). Both use the same 60° profile, so the same tool cuts either.
struct ThreadSize: Equatable, Sendable {
    enum Standard: String, Sendable { case metric, inch }
    /// "M8", or "1/4" and "#10" for inch sizes. Saved as the thread's `size`.
    var name: String
    var standard: Standard
    /// Nominal major diameter in millimeters.
    var diameter: Double
    /// Pitches in millimeters, the coarse (usual) one first.
    var pitches: [Double]

    var coarse: Double { pitches[0] }
    func has(pitch: Double) -> Bool { pitches.contains { abs($0 - pitch) < 1e-6 } }

    /// Threads per inch for an inch pitch.
    static func tpi(_ pitch: Double) -> Int { Int((25.4 / pitch).rounded()) }

    /// "M8 × 1.25", or "1/4-20 UNC" (UNF for the fine pitch).
    func title(pitch: Double) -> String {
        switch standard {
        case .metric: "\(name) × \(ThreadSpec.mm(pitch))"
        case .inch: "\(name)-\(Self.tpi(pitch)) \(abs(pitch - coarse) < 1e-6 ? "UNC" : "UNF")"
        }
    }

    /// "Coarse" or "Fine", "UNC" or "UNF", for a pitch of this size.
    func pitchKind(_ pitch: Double) -> String {
        let isCoarse = abs(pitch - coarse) < 1e-6
        return standard == .metric ? (isCoarse ? "Coarse" : "Fine") : (isCoarse ? "UNC" : "UNF")
    }
}

/// The standard sizes: starting points for holes and bosses that match them (October 21, 2026: fine
/// pitches, M2 to M36, and Unified inch sizes added).
enum ThreadPresets {
    static let metric: [ThreadSize] = [
        ("M2", 2, [0.4, 0.25]), ("M2.5", 2.5, [0.45, 0.35]), ("M3", 3, [0.5, 0.35]), ("M4", 4, [0.7, 0.5]), ("M5", 5, [0.8, 0.5]),
        ("M6", 6, [1, 0.75]), ("M8", 8, [1.25, 1, 0.75]), ("M10", 10, [1.5, 1.25, 1, 0.75]), ("M12", 12, [1.75, 1.5, 1.25, 1]),
        ("M14", 14, [2, 1.5, 1.25, 1]), ("M16", 16, [2, 1.5, 1]), ("M20", 20, [2.5, 2, 1.5, 1]), ("M24", 24, [3, 2, 1.5, 1]),
        ("M30", 30, [3.5, 3, 2, 1.5]), ("M36", 36, [4, 3, 2, 1.5])
    ].map { ThreadSize(name: $0.0, standard: .metric, diameter: $0.1, pitches: $0.2) }

    /// UNC and UNF, by threads per inch.
    static let inch: [ThreadSize] = [
        ("#4", 0.112, [40, 48]), ("#6", 0.138, [32, 40]), ("#8", 0.164, [32, 36]), ("#10", 0.19, [24, 32]), ("1/4", 0.25, [20, 28]),
        ("5/16", 0.3125, [18, 24]), ("3/8", 0.375, [16, 24]), ("1/2", 0.5, [13, 20]), ("5/8", 0.625, [11, 18]), ("3/4", 0.75, [10, 16])
    ].map { ThreadSize(name: $0.0, standard: .inch, diameter: $0.1 * 25.4, pitches: $0.2.map { 25.4 / Double($0) }) }

    static let all = metric + inch
    static var names: [String] { all.map(\.name) }

    /// A size by name ("M8", "m8", "1/4", "1/4\"", "#10"), or nil.
    static func size(named name: String) -> ThreadSize? {
        let key = name.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
        guard !key.isEmpty else { return nil }
        return all.first { $0.name.uppercased() == key }
    }

    /// The standard size with this diameter and pitch, or nil.
    static func size(diameter: Double, pitch: Double) -> ThreadSize? {
        all.first { abs($0.diameter - diameter) < 1e-6 && $0.has(pitch: pitch) }
    }

    /// Pitches offered for a custom diameter: the usual series, up to a quarter of the diameter.
    static func customPitches(for diameter: Double) -> [Double] {
        [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6].filter { $0 <= max(0.5, diameter / 4) }
    }

    /// A pitch that prints well for a custom diameter: the nearest metric size's, and 3 mm for jars and lids.
    static func pitch(for diameter: Double) -> Double {
        diameter > 27 ? 3 : metric.min { abs($0.diameter - diameter) < abs($1.diameter - diameter) }!.coarse
    }

    /// The size and pitch a face suggests: a hole near a size's minor (tap-drill) diameter, or a boss
    /// near its major diameter, preferring inch sizes when the project shows inches; otherwise a
    /// custom thread fitted to the face. A raised thread's face is instead a boss's minor diameter or
    /// a hole's major.
    static func suggestion(internal isInternal: Bool, surfaceDiameter d: Double, clearance: Double,
                           preferInch: Bool = false, raised: Bool = false) -> (size: String, major: Double, pitch: Double) {
        let families = preferInch ? [inch, metric] : [metric, inch]
        if raised {
            // A standard size whose minor (on a boss) or major (in a hole) is on the thread's side
            // of the face, up to 0.3 mm off, so its grooves stay clear; otherwise one fitted exactly.
            // Raised threads take the printable profile.
            let loss = ThreadProfile.printable.diameterLoss
            func gap(_ size: ThreadSize) -> Double { isInternal ? d - size.diameter : size.diameter - loss * size.coarse - d }
            for sizes in families {
                if let best = sizes.filter({ (-1e-9...0.3).contains(gap($0)) }).min(by: { gap($0) < gap($1) }) {
                    return (best.name, best.diameter, best.coarse)
                }
            }
            let pitch = pitch(for: d)
            return ("", isInternal ? d : d + loss * pitch, pitch)
        }
        for sizes in families {
            if isInternal {
                if let best = sizes.min(by: { abs($0.diameter - 1.082532 * $0.coarse - d) < abs($1.diameter - 1.082532 * $1.coarse - d) }),
                   abs(best.diameter - 1.082532 * best.coarse + 2 * clearance - d) <= max(0.4, 0.5 * best.coarse) {
                    return (best.name, best.diameter, best.coarse)
                }
            } else if let best = sizes.min(by: { abs($0.diameter - d) < abs($1.diameter - d) }), abs(best.diameter - d) <= 0.3 {
                return (best.name, best.diameter, best.coarse)
            }
        }
        if isInternal {
            let pitch = pitch(for: d + 1)
            let loss = (ThreadProfile.defaultFor(raised: false, majorDiameter: d, standard: false) ?? .iso).diameterLoss
            return ("", d + loss * pitch, pitch)
        }
        return ("", d, pitch(for: d))
    }
}

// MARK: Fit

/// How a thread sits on its face, worked out from the diameters before anything is built (October
/// 21, 2026), so the size menu and messages can say why a size works or not.
struct ThreadFit: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A full-depth thread, the face changing little.
        case full
        /// The face's material gives only part of the thread's depth: a hole wider than the thread's
        /// root, or a boss thinner than its crest.
        case partial
        /// A full thread, but the face changes a lot first: a hole cut out wider, a boss turned down.
        case resizes
        /// The thread misses the face: smaller than the hole, or bigger than the boss.
        case misses
    }
    var kind: Kind
    /// The share of a full thread's depth the face gives it, 0 to 1.
    var depth: Double
    /// The hole cut out to (the root), or the boss turned down to (the crest), as a diameter.
    var resultDiameter: Double

    /// Under this share of its depth a printed thread is likely to strip.
    static let shallow = 0.6
    var isUsable: Bool { kind != .misses }
}

extension ThreadSpec {
    var fit: ThreadFit {
        let s = surfaceDiameter / 2, depth = crestRadius - rootRadius
        // Within a few percent of the depth counts as touching (or as not touching).
        let slack = 0.03 * depth
        let resize = 2 * max(0.4, 0.25 * pitch)
        if isRaised {
            // Raised ridges stand out of the face whole, with grooves as deep as a matching part's
            // ridges need: a boss's face at or inside the minor diameter, a hole's at or outside the
            // major. A boss well inside the root is built up to it, a hole well outside the crest
            // filled in to it.
            if isInternal {
                guard s >= majorDiameter / 2 - slack, s > rootRadius + slack else { return ThreadFit(kind: .misses, depth: 0, resultDiameter: 2 * crestRadius) }
                return ThreadFit(kind: 2 * (s - crestRadius) > resize ? .resizes : .full, depth: 1, resultDiameter: 2 * min(s, crestRadius))
            }
            guard s <= minorDiameter / 2 + slack, s < crestRadius - slack else { return ThreadFit(kind: .misses, depth: 0, resultDiameter: 2 * rootRadius) }
            return ThreadFit(kind: 2 * (rootRadius - s) > resize ? .resizes : .full, depth: 1, resultDiameter: 2 * max(s, rootRadius))
        }
        if isInternal {
            guard s < crestRadius - slack else { return ThreadFit(kind: .misses, depth: 0, resultDiameter: 2 * rootRadius) }
            let share = min(1, (crestRadius - max(s, rootRadius)) / depth)
            let kind: ThreadFit.Kind = s > rootRadius + slack ? .partial : 2 * rootRadius - surfaceDiameter > resize ? .resizes : .full
            return ThreadFit(kind: kind, depth: share, resultDiameter: 2 * rootRadius)
        }
        guard s > rootRadius + slack else { return ThreadFit(kind: .misses, depth: 0, resultDiameter: 2 * crestRadius) }
        let share = min(1, (min(s, crestRadius) - rootRadius) / depth)
        let kind: ThreadFit.Kind = s < crestRadius - slack ? .partial : surfaceDiameter - 2 * crestRadius > resize ? .resizes : .full
        return ThreadFit(kind: kind, depth: share, resultDiameter: 2 * crestRadius)
    }

    /// The same face with another size and pitch (and the name, when it is a standard one).
    func with(size: ThreadSize?, diameter: Double, pitch: Double) -> ThreadSpec {
        var spec = self
        spec.majorDiameter = diameter
        spec.pitch = pitch
        let named = size.flatMap { abs($0.diameter - diameter) < 1e-6 && $0.has(pitch: pitch) ? $0 : nil }
        spec.size = (named ?? ThreadPresets.size(diameter: diameter, pitch: pitch))?.name ?? ""
        return spec
    }

    /// The same size with another pitch. A custom raised thread on a boss keeps the boss as its
    /// minor diameter, so its diameter follows the pitch.
    func with(pitch: Double) -> ThreadSpec {
        let diameter = isRaised && !isInternal && standardSize == nil ? surfaceDiameter + shape.diameterLoss * pitch : majorDiameter
        return with(size: standardSize, diameter: diameter, pitch: pitch)
    }

    /// This face's thread raised onto it, or cut into it: the standard size the face then suggests,
    /// else a custom thread fitted to the face (keeping a custom thread's pitch).
    func made(raised: Bool, preferInch: Bool = false) -> ThreadSpec {
        var spec = self
        spec.raised = raised ? true : nil
        spec.taperedEnds = raised ? true : nil
        let suggestion = ThreadPresets.suggestion(internal: isInternal, surfaceDiameter: surfaceDiameter, clearance: clearance,
                                                  preferInch: preferInch, raised: raised)
        if suggestion.size.isEmpty, standardSize == nil {
            // A custom thread's face: a raised boss's or cut hole's minor diameter, else its major.
            spec.profile = ThreadProfile.defaultFor(raised: raised, majorDiameter: majorDiameter, standard: false)
            let atMinor = raised != isInternal
            return spec.with(size: nil, diameter: surfaceDiameter + (atMinor ? spec.shape.diameterLoss * pitch : 0), pitch: pitch)
        }
        spec.profile = ThreadProfile.defaultFor(raised: raised, majorDiameter: suggestion.major, standard: !suggestion.size.isEmpty)
        return spec.with(size: ThreadPresets.size(named: suggestion.size), diameter: suggestion.major, pitch: suggestion.pitch)
    }

    /// The same thread with another cross-section. A custom raised thread on a boss keeps the boss as
    /// its minor diameter, so its diameter follows the profile's depth.
    func with(profile: ThreadProfile) -> ThreadSpec {
        var spec = self
        spec.profile = profile == .iso ? nil : profile
        guard isRaised, !isInternal, standardSize == nil else { return spec }
        return spec.with(size: nil, diameter: surfaceDiameter + profile.diameterLoss * pitch, pitch: pitch)
    }

    /// The diameters a thread of this pitch can have and still reach the face: over the hole (less
    /// the clearance), or with its root inside the boss. Raised: at least the boss's diameter plus
    /// the thread's depth, or at most the hole's diameter.
    var reachableDiameters: ClosedRange<Double>? {
        let core = shape.diameterLoss * pitch
        let slack = 2 * 0.03 * (crestRadius - rootRadius)
        let range = isRaised ? (isInternal ? Self.diameterRange.lowerBound...(surfaceDiameter + slack)
                                           : (surfaceDiameter + core - slack)...Self.diameterRange.upperBound)
            : isInternal ? (surfaceDiameter - 2 * clearance + 0.1 * pitch)...Self.diameterRange.upperBound
            : Self.diameterRange.lowerBound...(surfaceDiameter + 2 * clearance + core - 0.1 * pitch)
        let clamped = max(range.lowerBound, Self.diameterRange.lowerBound)...min(range.upperBound, Self.diameterRange.upperBound)
        return clamped.lowerBound < clamped.upperBound ? clamped : nil
    }

    /// The largest pitch this diameter can take (leaving a core, its profile fitting): 0 when none.
    var largestPitch: Double {
        let side = isInternal ? clearance : -clearance
        return min(Self.pitchRange.upperBound, (majorDiameter + 2 * side - 0.2) / shape.diameterLoss - 0.01)
    }

    /// A sentence on how this thread fits its face, with lengths written by `length` ("6.8 mm").
    func fitSummary(_ length: (Double) -> String) -> String {
        let fit = fit, face = isInternal ? "hole" : "boss", d = length(surfaceDiameter)
        if isRaised {
            switch fit.kind {
            case .full, .partial:
                let height = isInternal ? surfaceDiameter / 2 - rootRadius : crestRadius - surfaceDiameter / 2
                return isInternal ? "\(title) is raised inside this \(d) hole: ridges \(length(height)) tall, the wall left as it is."
                    : "\(title) is raised on this \(d) boss: ridges \(length(height)) tall, the boss left as it is."
            case .resizes:
                return isInternal ? "\(title) is smaller than this \(d) hole: the hole is filled in to \(length(fit.resultDiameter)) behind its ridges."
                    : "\(title) is bigger than this \(d) boss: the boss is built up to \(length(fit.resultDiameter)) under its ridges."
            case .misses:
                let nearest = ThreadPresets.nearestUsable(to: self).map { " Try \($0.name), Cut, or a" } ?? " Try Cut, or a"
                let range = reachableDiameters
                return isInternal ? "\(title) is too big to raise inside this \(d) hole: the wall would fill its grooves.\(nearest) diameter of \(length(range?.upperBound ?? surfaceDiameter)) or less."
                    : "\(title) is too small to raise on this \(d) boss: the boss would fill its grooves.\(nearest) diameter of \(length(range?.lowerBound ?? surfaceDiameter)) or more."
            }
        }
        switch fit.kind {
        case .full:
            return "\(title) fits this \(d) \(face): a full-depth thread."
        case .partial:
            let percent = Int((fit.depth * 100).rounded())
            let full = isInternal ? "a hole of \(length(2 * rootRadius)) or less" : "a boss of \(length(2 * crestRadius)) or more"
            let why = "this \(d) \(face) is too \(isInternal ? "wide" : "thin") for \(title)"
            if fit.depth < ThreadFit.shallow {
                return "Only \(percent)% of a full thread (\(why)), so it may strip. Use \(full), or another size."
            }
            return "\(percent)% of a full thread (\(why)); usually strong enough. \(full.prefix(1).uppercased() + full.dropFirst()) gives a full thread."
        case .resizes:
            return isInternal ? "\(title) is bigger than this \(d) hole: the hole is cut out to \(length(fit.resultDiameter)) for a full thread."
                : "\(title) is smaller than this \(d) boss: the boss is turned down to \(length(fit.resultDiameter)) for a full thread."
        case .misses:
            let limit = isInternal ? "over \(length(surfaceDiameter - 2 * clearance))" : "under \(length(surfaceDiameter + 2 * clearance + shape.diameterLoss * pitch))"
            let reason = isInternal ? "is smaller than this \(d) hole, so it would not reach the wall"
                : "is bigger than this \(d) boss, so its grooves would miss it"
            let nearest = ThreadPresets.nearestUsable(to: self).map { " Try \($0.name), or a" } ?? " Try a"
            return "\(title) \(reason).\(nearest) custom diameter \(limit)."
        }
    }

    /// A short note for the size menu: "Fits", "72% depth", "Cuts hole to Ø8.8", "Too small".
    func fitNote(_ length: (Double) -> String) -> String {
        let fit = fit
        if isRaised {
            switch fit.kind {
            case .full, .partial: return "Full thread"
            case .resizes: return isInternal ? "Fills the hole in to \(length(fit.resultDiameter))" : "Builds the boss up to \(length(fit.resultDiameter))"
            case .misses: return isInternal ? "Too big to raise in the hole" : "Too small to raise on the boss"
            }
        }
        switch fit.kind {
        case .full: return "Full thread"
        case .partial: return "\(Int((fit.depth * 100).rounded()))% depth" + (fit.depth < ThreadFit.shallow ? ", may strip" : "")
        case .resizes: return isInternal ? "Cuts the hole out to \(length(fit.resultDiameter))" : "Turns the boss down to \(length(fit.resultDiameter))"
        case .misses: return isInternal ? "Smaller than the hole" : "Bigger than the boss"
        }
    }
}

extension ThreadPresets {
    /// The standard size nearest a thread that does not reach its face which does, in its standard
    /// (coarse pitch): the next size up for a hole, down for a boss (the other way when raised).
    static func nearestUsable(to spec: ThreadSpec) -> ThreadSize? {
        let family = spec.standardSize?.standard == .inch ? inch : metric
        let upward = spec.isInternal != spec.isRaised
        let ordered = upward ? family : family.reversed()
        return ordered.first { size in
            (upward ? size.diameter > spec.majorDiameter : size.diameter < spec.majorDiameter) &&
                spec.with(size: size, diameter: size.diameter, pitch: size.coarse).fit.isUsable
        }
    }
}

extension ExtrusionCut {
    /// A thread on `body` (which supplies the placeholder profile).
    static func thread(of body: SolidBody, _ spec: ThreadSpec) -> ExtrusionCut {
        var operation = ExtrusionCut(profile: body.profile, depth: body.depth)
        operation.thread = spec
        return operation
    }
}

extension SolidBody {
    /// The thread a cylindrical face takes: which kind, a suggested size, and the face's axis and
    /// extent in the solid's own frame. Nil for a face that is not a full-length cylinder.
    func threadSpec(onFace face: Int, of solid: KernelSolid, clearance: Double, preferInch: Bool = false) -> ThreadSpec? {
        guard let cylinder = solid.faceCylinder(face) else { return nil }
        let side = ssk_face_cylinder_side(solid.handle, Int32(face))
        guard side != 0 else { return nil }
        let axis = simd_normalize(cylinder.direction)
        // The face's extent along its axis, from points on its edges.
        let heights = solid.faceEdges(face).flatMap { solid.edgeSamples($0, count: 9) }.map { simd_dot($0 - cylinder.point, axis) }
        guard let faceLow = heights.min(), let faceHigh = heights.max(), faceHigh - faceLow > 0.1 else { return nil }
        let across: SIMD3<Double> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let reference = simd_normalize(simd_cross(axis, across))
        let isInternal = side < 0, diameter = 2 * cylinder.radius
        let suggestion = ThreadPresets.suggestion(internal: isInternal, surfaceDiameter: diameter, clearance: clearance, preferInch: preferInch)
        // The thread never ends exactly on a face: past an open end (air beyond it, where a hole
        // opens or a boss ends) it runs on a pitch; at a closed end (a blind hole's floor, a boss's
        // base) a hair, so the cut does not share a face with the solid.
        let probe = cylinder.radius + (isInternal ? 0.3 : -0.3) * suggestion.pitch
        func isOpen(_ height: Double, _ outward: Double) -> Bool {
            let p = cylinder.point + axis * (height + outward * 0.25 * suggestion.pitch) + reference * probe
            return !ssk_point_inside(solid.handle, SSKVec3(x: p.x, y: p.y, z: p.z))
        }
        let lowOpen = isOpen(faceLow, -1), highOpen = isOpen(faceHigh, 1)
        let low = faceLow - (lowOpen ? suggestion.pitch : 0.02), high = faceHigh + (highOpen ? suggestion.pitch : 0.02)
        let start = cylinder.point + axis * low
        let localOrigin = localPoint(start)
        let localAxis = simd_normalize(localPoint(start + axis) - localOrigin)
        let localReference = simd_normalize(localPoint(start + reference) - localOrigin)
        let ends = ThreadEnds(start: faceLow - low, end: faceHigh - low, startOpen: lowOpen, endOpen: highOpen)
        return ThreadSpec(isInternal: isInternal, size: suggestion.size, majorDiameter: suggestion.major, pitch: suggestion.pitch, clearance: clearance,
                          origin: localOrigin, axis: localAxis, reference: localReference, length: high - low, surfaceDiameter: diameter,
                          ends: ends, leadIn: lowOpen || highOpen ? true : nil,
                          profile: ThreadProfile.defaultFor(raised: false, majorDiameter: suggestion.major, standard: !suggestion.size.isEmpty))
    }

    /// Whether a thread is screwed into at its `ends.end` side rather than its start: the open end,
    /// or the upper one (in the world) when both are open, as a through hole's top.
    func threadEntryIsAtEnd(_ spec: ThreadSpec) -> Bool {
        guard let ends = spec.ends else { return true }
        if ends.startOpen != ends.endOpen { return ends.endOpen }
        let origin = worldPoint(spec.origin), axis = simd_normalize(worldPoint(spec.origin + spec.axis) - origin)
        return axis.z > 1e-6 || abs(axis.z) <= 1e-6 && (axis.y > 1e-6 || abs(axis.y) <= 1e-6 && axis.x > 0)
    }

    /// This solid with `spec` threaded into it (at `cuts[index]`, before the steps from there on, when
    /// given), or nil when the kernel cannot build it.
    func threading(_ spec: ThreadSpec, at index: Int? = nil) -> SolidBody? {
        var result = self
        result.cuts.insert(.thread(of: self, spec), at: index.map { min(max($0, 0), cuts.count) } ?? cuts.count)
        guard result.isValid, (try? SolidKernel.solid(for: result)) != nil else { return nil }
        return result
    }

    /// The thinnest wall a cut thread leaves behind it, to a tenth of a millimeter, when that is
    /// under `limit`: the material under a bolt's roots (a hollow boss such as a jar's neck) or
    /// around a nut's grooves (a hole near an edge); 0 when it cuts through. Nil when there is at
    /// least `limit` all round, or for a raised thread, which adds to the wall instead. `solid` is
    /// this solid without the thread (October 22, 2026).
    func wallBehindThread(_ spec: ThreadSpec, in solid: KernelSolid, limit: Double = 1) -> Double? {
        guard !spec.isRaised else { return nil }
        let origin = worldPoint(spec.origin), axis = simd_normalize(worldPoint(spec.origin + spec.axis) - origin)
        let reference = worldPoint(spec.origin + spec.reference) - origin
        let x = simd_normalize(reference - axis * simd_dot(reference, axis)), y = simd_cross(axis, x)
        let (low, high) = spec.ends.map { ($0.start, $0.end) } ?? (0, spec.length)
        // Where the cut reaches deepest into the wall: a bolt's roots, a nut's grooves.
        let deepest = spec.isInternal ? spec.crestRadius : spec.rootRadius
        func isWall(_ depth: Double, at height: Double, _ angle: Double) -> Bool {
            let radius = deepest + (spec.isInternal ? depth : -depth)
            guard radius > 0 else { return true }
            let p = origin + axis * height + (x * cos(angle) + y * sin(angle)) * radius
            return ssk_point_inside(solid.handle, SSKVec3(x: p.x, y: p.y, z: p.z))
        }
        var thinnest = limit
        for fraction in [0.25, 0.5, 0.75] {
            let height = low + (high - low) * fraction
            for step in 0..<12 {
                let angle = Double(step) * .pi / 6
                guard !isWall(limit, at: height, angle) else { continue }
                var depth = 0.0
                while depth < thinnest, isWall(depth, at: height, angle) { depth += 0.1 }
                thinnest = min(thinnest, depth)
            }
        }
        return thinnest < limit - 1e-9 ? (thinnest * 10).rounded() / 10 : nil
    }
}

extension ThreadSpec {
    /// A sentence on a thin wall behind a cut thread (see `wallBehindThread`), with lengths written by
    /// `length`.
    func wallWarning(_ wall: Double, _ length: (Double) -> String) -> String {
        wall < 0.05 ? "This thread cuts through the wall into the inside." : "Only about \(length(wall)) of wall stays behind this thread."
    }
}

extension ThreadSpec {
    /// The shortest thread length offered: one turn.
    var shortestLength: Double { max(pitch, 0.5) }

    /// This thread (made along its whole face) cut short to `threaded` along the face, kept at the end
    /// it is screwed in at (`atEnd`: the `ends.end` side) and stopping partway along the face at the
    /// other. Itself when `threaded` covers the face; nil when it is shorter than a turn.
    func shortened(to threaded: Double, atEnd: Bool) -> ThreadSpec? {
        guard let ends, threaded.isFinite else { return nil }
        if threaded >= ends.end - ends.start - 1e-6 { return self }
        guard threaded >= shortestLength - 1e-9 else { return nil }
        var spec = self
        if atEnd {
            let start = ends.end - threaded
            spec.origin = origin + axis * start
            spec.length = length - start
            spec.ends = ThreadEnds(start: 0, end: threaded, startOpen: false, endOpen: ends.endOpen)
        } else {
            spec.length = ends.start + threaded
            spec.ends = ThreadEnds(start: ends.start, end: ends.start + threaded, startOpen: ends.startOpen, endOpen: false)
        }
        if spec.leadIn == true && !spec.hasOpenEnd { spec.leadIn = nil }
        return spec
    }

    /// The same thread on the mirror image of its solid: the frame's y axis flips, and so does the hand.
    var mirrored: ThreadSpec {
        var image = self
        let flip = { (v: SIMD3<Double>) in SIMD3(v.x, -v.y, v.z) }
        image.origin = flip(origin)
        image.axis = flip(axis)
        image.reference = flip(reference)
        image.leftHanded = leftHanded == true ? nil : true
        return image
    }
}

extension SolidKernel {
    static func applyThread(_ operation: ExtrusionCut, to solid: KernelSolid, of body: SolidBody) throws -> KernelSolid {
        guard let spec = operation.thread else { throw Failure(message: "Missing thread") }
        let origin = body.worldPoint(spec.origin)
        let axis = simd_normalize(body.worldPoint(spec.origin + spec.axis) - origin)
        let reference = body.worldPoint(spec.origin + spec.reference) - origin
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        // A raised thread is added only along the face itself: past an open end lies air (the
        // thread's length runs on a pitch there), past a closed one the solid it stands on.
        let clip = spec.ends.map { ($0.startOpen ? $0.start : 0, $0.endOpen ? $0.end : spec.length) } ?? (0, spec.length)
        guard let tool = ssk_thread_tool(vec(origin), vec(axis), vec(reference), 0, spec.length, spec.pitch, spec.crestRadius, spec.rootRadius,
                                         spec.surfaceDiameter / 2, spec.isInternal, spec.leftHanded == true, Int32(spec.startCount),
                                         spec.isRaised, clip.0, clip.1, spec.shape.flankDegrees) else {
            throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Thread failed")
        }
        var result: KernelSolid
        if spec.isRaised {
            result = try boolean(solid, KernelSolid(adopting: tool), .union)
            guard result.volume > solid.volume + 1e-9 else { throw Failure(message: "The thread does not stand out of this solid") }
        } else {
            result = try boolean(solid, KernelSolid(adopting: tool), .subtract)
            guard result.volume < solid.volume - 1e-9 else { throw Failure(message: "The thread does not reach this solid") }
        }
        if spec.leadIn == true, let ends = spec.ends {
            // A lead-in that will not build leaves the thread square-ended rather than failing it.
            for (height, isOpen, inward) in [(ends.start, ends.startOpen, axis), (ends.end, ends.endOpen, -axis)] where isOpen {
                if let cone = try? leadInTool(spec, at: origin + axis * height, inward: inward, across: reference),
                   let beveled = try? boolean(result, cone, .subtract), beveled.isValidSolid {
                    result = beveled
                }
            }
        }
        if spec.isRaised, spec.taperedEnds == true, let ends = spec.ends {
            // Raised ridges fade out where they meet the solid (and at an open end with no lead-in)
            // rather than stopping square. A fade that will not build leaves the end square.
            for (height, isOpen, inward) in [(ends.start, ends.startOpen, axis), (ends.end, ends.endOpen, -axis)] where !isOpen || spec.leadIn != true {
                if let fade = try? fadeTool(spec, at: origin + axis * height, inward: inward, across: reference),
                   let faded = try? boolean(result, fade, .subtract), faded.isValidSolid, faded.volume < result.volume {
                    result = faded
                }
            }
        }
        return result
    }

    /// What fades a raised thread's ridges out at an end at `face`, `inward` pointing along the
    /// thread: everything beyond a cone from the face's own surface at the end to the ridges' full
    /// height a quarter turn in (a quarter of the lead along the axis), so each ridge tapers away
    /// over about a quarter turn. On a boss it is the outside of that cone, in a hole the inside.
    static func fadeTool(_ spec: ThreadSpec, at face: SIMD3<Double>, inward: SIMD3<Double>, across: SIMD3<Double>) throws -> KernelSolid {
        let surface = spec.surfaceDiameter / 2, run = spec.lead / 4
        // (radius, depth into the thread) in a plane through the axis.
        let points: [(Double, Double)]
        if spec.isInternal {
            // The ridges stand in from the wall to the root: take what lies inside the line from the
            // wall at the end to the root a quarter turn in, carried on to the axis.
            let root = spec.rootRadius - 0.05 * spec.pitch
            guard surface - root > 1e-3 else { throw Failure(message: "No ridges to fade") }
            points = [(0, 0), (surface, 0), (0, run * surface / (surface - root))]
        } else {
            let crest = spec.crestRadius + 0.05 * spec.pitch, outer = crest + 0.05
            guard crest - surface > 1e-3 else { throw Failure(message: "No ridges to fade") }
            points = [(surface, 0), (outer, 0), (outer, run * (outer - surface) / (crest - surface))]
        }
        let x = simd_normalize(across - inward * simd_dot(across, inward))
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        let plane = SSKPlane(origin: vec(face), xAxis: vec(x), yAxis: vec(simd_normalize(inward)))
        let xy = points.flatMap { [$0.0, $0.1] }
        guard let cone = ssk_revolve_profile(plane, xy, nil, Int32(points.count), 0, 0, 0, 1, 360) else {
            throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Fade failed")
        }
        return KernelSolid(adopting: cone)
    }

    /// What a lead-in removes at an open end at `face`, `inward` pointing along the thread: in a nut a
    /// 45° countersink from just past the crest (or a raised thread's wall) down to the root, on a
    /// bolt a 45° bevel from just inside the root out past the crest. It reaches a little into the
    /// air beyond the end.
    static func leadInTool(_ spec: ThreadSpec, at face: SIMD3<Double>, inward: SIMD3<Double>, across: SIMD3<Double>) throws -> KernelSolid {
        let pitch = spec.pitch, root = spec.rootRadius - 0.05 * pitch
        let beyond = min(0.2 * pitch + 0.1, 0.5 * root)
        // (radius, depth into the thread) in a plane through the axis.
        let points: [(Double, Double)]
        if spec.isInternal {
            let mouth = max(spec.crestRadius, spec.isRaised ? spec.surfaceDiameter / 2 : 0) + 0.1 * pitch
            points = [(0, -beyond), (mouth + beyond, -beyond), (root, mouth - root), (0, mouth - root)]
        } else {
            let outer = max(spec.surfaceDiameter / 2, spec.crestRadius) + 0.05
            points = [(root - beyond, -beyond), (outer, -beyond), (outer, outer - root)]
        }
        let x = simd_normalize(across - inward * simd_dot(across, inward))
        func vec(_ v: SIMD3<Double>) -> SSKVec3 { SSKVec3(x: v.x, y: v.y, z: v.z) }
        let plane = SSKPlane(origin: vec(face), xAxis: vec(x), yAxis: vec(simd_normalize(inward)))
        let xy = points.flatMap { [$0.0, $0.1] }
        guard let cone = ssk_revolve_profile(plane, xy, nil, Int32(points.count), 0, 0, 0, 1, 360) else {
            throw Failure(message: ssk_last_error().map { String(cString: $0) } ?? "Lead-in failed")
        }
        return KernelSolid(adopting: cone)
    }
}

// MARK: Matching parts

/// A part that screws onto a thread, made already screwed on so the fit can be seen: a nut or cap
/// over a bolt's thread, a bolt or plug into a nut's (October 21, 2026). It is an ordinary solid
/// with its own thread entry, the same size, hand, and clearance, and its helix in step with the
/// original's.
enum ThreadMate: String, CaseIterable, Sendable {
    case nut, cap, bolt, plug

    var title: String {
        switch self { case .nut: "Hex Nut"; case .cap: "Cap"; case .bolt: "Hex Bolt"; case .plug: "Plug" }
    }
    var noun: String {
        switch self { case .nut: "nut"; case .cap: "cap"; case .bolt: "bolt"; case .plug: "plug" }
    }
    /// It carries a nut's thread (it goes over a bolt's).
    var isInternal: Bool { self == .nut || self == .cap }

    /// The parts that fit a thread, the likelier first: a cap or plug for jar-sized threads.
    static func choices(for spec: ThreadSpec) -> [ThreadMate] {
        guard spec.hasOpenEnd else { return [] }
        let pair: [ThreadMate] = spec.isInternal ? [.bolt, .plug] : [.nut, .cap]
        return spec.majorDiameter >= 20 ? pair.reversed() : pair
    }

    /// ISO hex nut and bolt head widths across flats, by size, and the usual inch nut sizes.
    static let acrossFlats: [String: Double] = [
        "M2": 4, "M2.5": 5, "M3": 5.5, "M4": 7, "M5": 8, "M6": 10, "M8": 13, "M10": 16, "M12": 18, "M14": 21, "M16": 24, "M20": 30,
        "M24": 36, "M30": 46, "M36": 55,
        "#4": 6.35, "#6": 7.94, "#8": 8.73, "#10": 9.53, "1/4": 11.11, "5/16": 12.7, "3/8": 14.29, "1/2": 19.05, "5/8": 23.81, "3/4": 28.58]
}

extension SolidBody {
    /// The thread entries (indices into `cuts`) that can take a matching part.
    var matableThreads: [Int] { cuts.indices.filter { cuts[$0].thread?.hasOpenEnd == true } }

    /// The thread entry that face `face` of this solid was cut by (its flanks, crests, roots, or
    /// lead-in), or nil.
    func thread(atFace face: Int, of solid: KernelSolid) -> Int? {
        let points = solid.faceEdges(face).flatMap { solid.edgeSamples($0, count: 7) }
        guard !points.isEmpty else { return nil }
        return matableThreads.last { index in
            guard let spec = cuts[index].thread else { return false }
            let origin = worldPoint(spec.origin), axis = simd_normalize(worldPoint(spec.origin + spec.axis) - origin)
            let inner = spec.rootRadius - 0.1 * spec.pitch - 0.01
            let outer = max(spec.crestRadius, spec.surfaceDiameter / 2) + 0.2 * spec.pitch + 0.11
            return points.allSatisfy { point in
                let along = simd_dot(point - origin, axis), radius = simd_length(point - origin - axis * along)
                return along > -0.01 && along < spec.length + 0.01 && radius > inner && radius < outer
            }
        }
    }

    /// A `kind` part for the thread at `cuts[index]`, screwed onto its open end (the upper one when
    /// both are open), or nil when the thread has no open end or the part will not build. A nut is
    /// flush with a bolt's tip; a cap's ceiling rests on it; a bolt's or plug's head sits on the
    /// face the hole opens onto. Against a closed end (a boss's base, a blind hole's floor) the part
    /// stops half a millimeter short.
    func matingPart(_ kind: ThreadMate, forThreadAt index: Int, cap shape: CapShape? = nil) -> SolidBody? {
        guard cuts.indices.contains(index), let spec = cuts[index].thread, let ends = spec.ends, spec.hasOpenEnd,
              kind.isInternal != spec.isInternal else { return nil }
        let origin = worldPoint(spec.origin), axis = simd_normalize(worldPoint(spec.origin + spec.axis) - origin)
        let reference = worldPoint(spec.origin + spec.reference) - origin
        // The open end it screws on at, and the way out of the thread there.
        let atEnd = threadEntryIsAtEnd(spec)
        let out = atEnd ? axis : -axis
        let mouth = origin + axis * (atEnd ? ends.end : ends.start)
        let faceLength = ends.end - ends.start, through = ends.startOpen && ends.endOpen
        let pitch = spec.pitch, diameter = spec.majorDiameter
        let shortOfFloor = through ? 0 : min(0.5, faceLength / 4)
        let engagement = kind == .nut ? min(faceLength, max(0.8 * diameter, 3 * pitch)) : shape?.skirt ?? faceLength - shortOfFloor
        guard engagement >= pitch else { return nil }
        let flats = max(ThreadMate.acrossFlats[spec.size] ?? (1.5 * diameter + 1).rounded(), 2 * spec.crestRadius + 2.4)
        let finish = min(max(0.08 * diameter, 1.6), 3)

        // Profiles on the plane square to the axis at `height` past the mouth.
        func plane(at height: Double) -> (SketchPlane, Point2)? {
            let point = mouth + out * height
            guard let plane = SketchPlane.through(point, normal: out) else { return nil }
            return (plane, plane.coordinates(of: point))
        }
        func circle(_ diameter: Double, at height: Double) -> SketchProfile? {
            guard let (plane, center) = plane(at: height) else { return nil }
            return PegJoint.circle(diameter, at: center, on: plane)
        }
        func hexagon(at height: Double) -> SketchProfile? {
            guard let (plane, center) = plane(at: height) else { return nil }
            let corner = flats / sqrt(3)
            let points = (0..<6).map { i in center + Point2(x: corner * cos(Double(i) * .pi / 3), y: corner * sin(Double(i) * .pi / 3)) }
            let sides = points.indices.map { SketchShape(kind: .line, plane: plane, start: points[$0], end: points[($0 + 1) % 6]) }
            return Geometry.profiles(in: sides, on: plane).first
        }

        var part: SolidBody
        switch kind {
        case .nut, .cap:
            // A body from `engagement` inside the mouth, bored at the minor diameter for its thread.
            let wall = shape?.wall ?? finish, outer = 2 * (spec.crestRadius + wall)
            let capOutline = shape?.ribbed == true ? plane(at: -engagement).flatMap { CapShape.ribbed(outer, at: $0.1, on: $0.0) }
                : circle(outer, at: -engagement)
            guard let outline = kind == .nut ? hexagon(at: -engagement) : capOutline,
                  let bore = circle(spec.minorDiameter, at: -engagement) else { return nil }
            part = SolidBody(profile: outline, depth: engagement + (kind == .cap ? shape?.top ?? finish : 0))
            part.cuts.append(ExtrusionCut(profile: bore, depth: engagement, throughAll: kind == .nut))
        case .bolt, .plug:
            // A head on the mouth's face and a shank at the major diameter down into the hole.
            guard let head = kind == .bolt ? hexagon(at: 0) : circle(diameter + 2 * max(2, 0.1 * diameter), at: 0),
                  let shank = circle(diameter, at: 0) else { return nil }
            part = SolidBody(profile: head, depth: kind == .bolt ? max(2, 0.7 * diameter) : finish)
            part.cuts.append(ExtrusionCut(profile: shank, depth: -engagement, operation: .join))
        }
        guard part.isValid, let solid = try? SolidKernel.solid(for: part) else { return nil }

        // Its thread, from the part's own round face, in step with the original's helix: the same
        // axis and start direction, starting a whole number of pitches from the original's start.
        let radius = kind.isInternal ? spec.minorDiameter / 2 : diameter / 2
        guard let face = (0..<solid.faceCount).first(where: { face in
            guard let cylinder = solid.faceCylinder(face) else { return false }
            return abs(cylinder.radius - radius) < 1e-4 && abs(abs(simd_dot(simd_normalize(cylinder.direction), axis)) - 1) < 1e-6
        }), let found = part.threadSpec(onFace: face, of: solid, clearance: spec.clearance), let foundEnds = found.ends else { return nil }
        let foundOrigin = part.worldPoint(found.origin), foundAxis = part.worldPoint(found.origin + found.axis) - foundOrigin
        let a = simd_dot(foundOrigin + foundAxis * foundEnds.start - origin, axis)
        let b = simd_dot(foundOrigin + foundAxis * foundEnds.end - origin, axis)
        let flipped = a > b
        let (low, high) = (min(a, b), max(a, b))
        let lowOpen = flipped ? foundEnds.endOpen : foundEnds.startOpen, highOpen = flipped ? foundEnds.startOpen : foundEnds.endOpen
        // It starts where its face does (a pitch out past an open end, a hair into a closed one, so
        // a cap keeps its top), its start direction turned by as much of a turn as the start moved
        // along the axis over the lead, so the helix stays the original's.
        let start = low - (lowOpen ? pitch : 0.02)
        let finishLine = high + (highOpen ? pitch : 0.02)
        let threadStart = origin + axis * start
        let turn = 2 * .pi * start / spec.lead * (spec.leftHanded == true ? -1 : 1)
        let across = simd_normalize(reference - axis * simd_dot(reference, axis))
        let turned = across * cos(turn) + simd_cross(axis, across) * sin(turn)
        var thread = spec
        thread.origin = part.localPoint(threadStart)
        thread.axis = simd_normalize(part.localPoint(threadStart + axis) - thread.origin)
        thread.reference = simd_normalize(part.localPoint(threadStart + turned) - thread.origin)
        thread.length = finishLine - start
        thread.isInternal = kind.isInternal
        // Cut into the part's own bore or shank, whichever way the original was made.
        thread.raised = nil
        thread.surfaceDiameter = 2 * radius
        thread.ends = ThreadEnds(start: low - start, end: high - start, startOpen: lowOpen, endOpen: highOpen)
        // A lead-in like the original's (on unless it was turned off).
        thread.leadIn = spec.leadIn == true && (lowOpen || highOpen) ? true : nil
        thread.taperedEnds = nil
        return part.threading(thread)
    }
}

/// A cap's own shape, where Matching Part's defaults will not do (Screw Lid): its wall beyond the
/// thread's crest, its top, how far its skirt reaches down the neck, and a ribbed grip.
struct CapShape: Equatable, Sendable {
    var wall: Double
    var top: Double
    var skirt: Double
    var ribbed: Bool

    /// A round outline `diameter` across with ribs standing 0.8 mm out of it about every 4 mm, for
    /// a grip: one outline, so the lid is one extrusion however many ribs it has.
    static func ribbed(_ diameter: Double, at center: Point2, on plane: SketchPlane) -> SketchProfile? {
        let radius = diameter / 2, height = 0.8, width = 1.6
        let count = max(12, Int((2 * .pi * radius / 4).rounded()))
        let half = width / 2 / radius, step = 2 * .pi / Double(count)
        var points: [Point2] = []
        func at(_ angle: Double, _ r: Double) -> Point2 { center + Point2(x: r * cos(angle), y: r * sin(angle)) }
        for i in 0..<count {
            let middle = Double(i) * step
            points += [at(middle - half, radius), at(middle - half, radius + height), at(middle + half, radius + height), at(middle + half, radius)]
            // The circle between this rib and the next, in a few straight pieces.
            for k in 1..<4 { points.append(at(middle + half + (step - 2 * half) * Double(k) / 4, radius)) }
        }
        let sides = points.indices.map { SketchShape(kind: .line, plane: plane, start: points[$0], end: points[($0 + 1) % points.count]) }
        return Geometry.profiles(in: sides, on: plane).first { $0.outline.count >= points.count / 2 }
    }
}

// MARK: Screw Lid

/// Screw Lid (October 26, 2026): what to put on a container's round neck. A raised thread in the
/// printable profile goes on the neck, and a lid comes with it, already screwed on.
struct ScrewLidSpec: Equatable, Sendable {
    var pitch = 3.0
    /// Two starts close a lid in about a turn.
    var starts = 2
    /// How far the lid turns to close: the thread is this many leads long.
    var turns = 1.0
    var clearance: Double
    /// The lid's top, and its whole height (nil: the thread plus the top plus a millimeter).
    var top = 2.0
    var height: Double?
    var wall = 2.0
    var ribbed = true

    static let pitchRange = 1.0...6.0
    static let turnsRange = 0.5...4.0
    static let topRange = 0.8...10.0
}

enum ScrewLid {
    struct Result {
        var jar: SolidBody
        var lid: SolidBody
        var thread: ThreadSpec
    }

    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// The thread the neck at `face` of `body` takes, and the lid's height range, before building.
    static func thread(on body: SolidBody, face: Int, _ spec: ScrewLidSpec) throws -> (thread: ThreadSpec, neck: Double) {
        guard let solid = try? SolidKernel.solid(for: body), var thread = body.threadSpec(onFace: face, of: solid, clearance: spec.clearance) else {
            throw Failure(message: "Tap the outside of a round neck, such as a jar's.")
        }
        guard !thread.isInternal else { throw Failure(message: "A screw lid goes over a round neck; this is a hole.") }
        guard let ends = thread.ends, thread.hasOpenEnd else { throw Failure(message: "The neck needs an open end, its rim, for the lid to go on.") }
        guard ScrewLidSpec.pitchRange.contains(spec.pitch) else { throw Failure(message: "The pitch must be 1–6 mm.") }
        guard ThreadSpec.startsRange.contains(spec.starts) else { throw Failure(message: "A lid's thread has 1 to 4 starts.") }
        guard ScrewLidSpec.turnsRange.contains(spec.turns) else { throw Failure(message: "A lid closes in ½ to 4 turns.") }
        thread = thread.made(raised: true).with(profile: .printable)
        thread = thread.with(size: nil, diameter: thread.surfaceDiameter + ThreadProfile.printable.diameterLoss * spec.pitch, pitch: spec.pitch)
        thread.starts = spec.starts > 1 ? spec.starts : nil
        let neck = ends.end - ends.start
        let threaded = spec.turns * thread.lead
        guard threaded <= neck - 0.5 else {
            throw Failure(message: "The neck is \(ThreadSpec.mm(neck)) mm tall: \(ThreadSpec.mm(spec.turns)) turns of this thread need \(ThreadSpec.mm(threaded + 0.5)) mm. Choose fewer turns, starts, or a smaller pitch.")
        }
        guard thread.isValid, thread.fit.isUsable,
              let short = thread.shortened(to: threaded, atEnd: body.threadEntryIsAtEnd(thread)) else {
            throw Failure(message: "That thread does not fit this neck; try another pitch.")
        }
        return (short, neck)
    }

    /// The neck threaded and its lid, already screwed on, or why not.
    static func make(on body: SolidBody, face: Int, _ spec: ScrewLidSpec) throws -> Result {
        let (thread, neck) = try self.thread(on: body, face: face, spec)
        guard ScrewLidSpec.topRange.contains(spec.top) else { throw Failure(message: "The lid's top must be 0.8–10 mm thick.") }
        let threaded = thread.threadedLength
        let height = spec.height ?? threaded + spec.top + 1
        let skirt = height - spec.top
        guard skirt >= threaded - 0.5 else {
            throw Failure(message: "The lid must be at least \(ThreadSpec.mm(threaded - 0.5 + spec.top)) mm tall to cover its thread.")
        }
        guard skirt <= neck - 0.5 else {
            throw Failure(message: "The lid can be at most \(ThreadSpec.mm(neck - 0.5 + spec.top)) mm tall: the neck is \(ThreadSpec.mm(neck)) mm.")
        }
        guard let jar = body.threading(thread) else { throw Failure(message: "The thread could not be built on this neck; try another pitch.") }
        guard let lid = jar.matingPart(.cap, forThreadAt: jar.cuts.count - 1,
                                       cap: CapShape(wall: spec.wall, top: spec.top, skirt: skirt, ribbed: spec.ribbed)) else {
            throw Failure(message: "The lid could not be built; try another height or pitch.")
        }
        return Result(jar: jar, lid: lid, thread: thread)
    }
}
