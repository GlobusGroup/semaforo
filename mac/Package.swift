// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Azioni",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Azioni",
            path: "Sources/Azioni"
        ),
        .testTarget(
            name: "AzioniTests",
            dependencies: ["Azioni"],
            path: "Tests/AzioniTests"
        ),
    ]
)
