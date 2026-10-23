// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniversityKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UniversityKit", targets: ["UniversityKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.11.1")),
        .package(url: "https://github.com/scinfu/SwiftSoup", .upToNextMinor(from: "2.14.3")),
    ],
    targets: [
        .target(
            name: "UniversityKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .testTarget(
            name: "UniversityKitTests",
            dependencies: ["UniversityKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
