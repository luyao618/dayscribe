// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scriber",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Scriber", targets: ["Scriber"])],
    targets: [
        .executableTarget(name: "Scriber", resources: [.process("Resources")]),
        .testTarget(name: "ScriberTests", dependencies: ["Scriber"])
    ]
)
