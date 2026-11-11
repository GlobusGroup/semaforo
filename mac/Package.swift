// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Semaforo",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates for the shared app; see scripts/release.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Semaforo",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Semaforo",
            // build-app.sh copies Sparkle.framework into Semaforo.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "SemaforoTests",
            dependencies: ["Semaforo"],
            path: "Tests/SemaforoTests"
        ),
    ]
)
