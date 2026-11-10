// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Azioni",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates for the shared app; see scripts/release.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Azioni",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Azioni",
            // build-app.sh copies Sparkle.framework into Azioni.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "AzioniTests",
            dependencies: ["Azioni"],
            path: "Tests/AzioniTests"
        ),
    ]
)
