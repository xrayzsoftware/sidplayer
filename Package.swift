// swift-tools-version:5.9
import PackageDescription

// Homebrew Apple Silicon prefix. Phase 1 only — Phase 6 will vendor
// libsidplayfp so we don't depend on Homebrew at runtime.
let homebrewPrefix = "/opt/homebrew"

let package = Package(
    name: "sidplayer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SIDEngine",  targets: ["SIDEngine"]),
        .library(name: "SIDCatalog", targets: ["SIDCatalog"]),
        .executable(name: "sidspike", targets: ["sidspike"]),
        .executable(name: "sidcat",   targets: ["sidcat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "CSIDEngine",
            path: "Sources/CSIDEngine",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I\(homebrewPrefix)/include"]),
            ],
            linkerSettings: [
                .linkedLibrary("sidplayfp"),
                .unsafeFlags(["-L\(homebrewPrefix)/lib"]),
            ]
        ),
        .target(
            name: "SIDEngine",
            dependencies: ["CSIDEngine"],
            path: "Sources/SIDEngine"
        ),
        .target(
            name: "SIDCatalog",
            dependencies: [
                "SIDEngine",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/SIDCatalog"
        ),
        .executableTarget(
            name: "sidspike",
            dependencies: ["SIDEngine"],
            path: "Sources/sidspike"
        ),
        .executableTarget(
            name: "sidcat",
            dependencies: ["SIDCatalog", "SIDEngine"],
            path: "Sources/sidcat"
        ),
        .testTarget(
            name: "SIDEngineTests",
            dependencies: ["SIDEngine"],
            path: "Tests/SIDEngineTests"
        ),
        .testTarget(
            name: "SIDCatalogTests",
            dependencies: ["SIDCatalog"],
            path: "Tests/SIDCatalogTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
