// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatalogManager",
    platforms: [.macOS("13.1")],
    dependencies: [
        .package(url: "https://github.com/rive-app/rive-ios.git", exact: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "CatalogManager",
            dependencies: [.product(name: "RiveRuntime", package: "rive-ios")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        ),
        .testTarget(name: "CatalogManagerTests", dependencies: ["CatalogManager"])
    ]
)
