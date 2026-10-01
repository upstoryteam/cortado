// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cortado",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cortado",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ],
            // Without this the binary is stamped as built with the macOS 15 SDK,
            // and macOS 26 and later draw it with the old controls instead of glass.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "27.0"]),
            ]
        ),
        .testTarget(
            name: "CortadoTests",
            dependencies: ["Cortado"]
        ),
    ]
)
