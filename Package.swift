// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xonevertr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xonevertr", targets: ["Xonevertr"]),
        .library(name: "ConversionCore", targets: ["ConversionCore"])
    ],
    targets: [
        .target(name: "ConversionCore"),
        .target(name: "QueueCore"),
        .executableTarget(name: "Xonevertr", dependencies: ["ConversionCore", "QueueCore"]),
        .testTarget(name: "QueueCoreTests", dependencies: ["QueueCore"]),
        .testTarget(name: "ConversionCoreTests", dependencies: ["ConversionCore"], resources: [.copy("Fixtures")])
    ]
)
