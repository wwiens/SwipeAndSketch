import os

/// Signpost intervals around the app's hot paths, so a run in Instruments (Points of Interest, or
/// the os_signpost instrument) shows how long each canvas refresh, live preview, solid build, save,
/// and open takes, and how often. They cost next to nothing when Instruments is not recording.
///
///     let interval = Performance.begin("Cut preview")
///     defer { Performance.end(interval) }
enum Performance {
    static let signposter = OSSignposter(subsystem: "noventix.SwipeAndSketch", category: .pointsOfInterest)

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString) -> Interval {
        #if DEBUG
        eventHook?(name)
        #endif
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
    }

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try work()
    }

    /// A single moment, such as a SwiftUI body being evaluated again.
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        #if DEBUG
        eventHook?(name)
        #endif
    }

    #if DEBUG
    /// Tests count events, and intervals as they begin, through this (how often the editor and the
    /// canvas redraw while the Pencil drags). Set on the main thread, and only by tests that count
    /// main-thread work: intervals begun elsewhere call it on their own threads.
    nonisolated(unsafe) static var eventHook: ((StaticString) -> Void)?
    #endif
}
