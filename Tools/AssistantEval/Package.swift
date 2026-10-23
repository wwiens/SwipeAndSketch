// swift-tools-version: 6.0
import PackageDescription

// Runs assistant requests against the real on-device Foundation Model on a Mac, with the app's
// own Core and Assistant sources (symlinked), to tune instructions and tools without the simulator.
// Usage: swift run -c release AssistantEval [--scenario empty|box|plate] "request" …
let package = Package(
    name: "AssistantEval",
    platforms: [.macOS("27.0")],
    targets: [
        .binaryTarget(name: "SSKernel", path: "SSKernel.xcframework"),
        .executableTarget(name: "AssistantEval", dependencies: ["SSKernel"], path: "Sources/AssistantEval",
                          linkerSettings: [.linkedLibrary("c++")]),
    ]
)
