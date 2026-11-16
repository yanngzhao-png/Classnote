// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Classnote", platforms: [.macOS(.v14)],
    products: [.executable(name: "Classnote", targets: ["Classnote"])],
    targets: [
        .target(name: "ClassnoteCore"),
        .executableTarget(name: "Classnote", dependencies: ["ClassnoteCore"]),
        .executableTarget(name: "ClassnoteChecks", dependencies: ["ClassnoteCore"], path: "Tests/ClassnoteCoreTests")
    ], swiftLanguageModes: [.v5]
)
