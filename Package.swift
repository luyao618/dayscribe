// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scriber",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Scriber", targets: ["Scriber"])],
    targets: [
        .executableTarget(name: "Scriber"),
        .testTarget(name: "ScriberTests", dependencies: ["Scriber"])
    ]
)
