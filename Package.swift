// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwipeAndSketchCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwipeAndSketchCore", targets: ["SwipeAndSketchCore"])],
    targets: [
        // Open CASCADE modeling kernel + Swipe & Sketch facade. Build with Scripts/build_kernel.sh.
        .binaryTarget(name: "SSKernel", path: "Vendor/SSKernel.xcframework"),
        .target(name: "SwipeAndSketchCore", dependencies: ["SSKernel"], path: "SwipeAndSketch/Core",
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "SwipeAndSketchCoreTests", dependencies: ["SwipeAndSketchCore"], path: "Tests/CoreTests")
    ]
)
