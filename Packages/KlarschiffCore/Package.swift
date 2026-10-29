// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlarschiffCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KlarschiffCore", targets: ["KlarschiffCore"])
    ],
    targets: [
        .target(name: "KlarschiffCore"),
        .testTarget(name: "KlarschiffCoreTests", dependencies: ["KlarschiffCore"])
    ],
    swiftLanguageModes: [.v6]
)
