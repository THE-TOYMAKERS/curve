// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Curve",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Curve", targets: ["Curve"])],
    targets: [
        .target(name: "BrowserCore"),
        .executableTarget(name: "Curve", dependencies: ["BrowserCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserCoreTests")
    ]
)
