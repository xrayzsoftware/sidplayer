// swift-tools-version:5.9
import PackageDescription

// Homebrew Apple Silicon prefix. Phase 1 only — Phase 6 will vendor
// libsidplayfp so we don't depend on Homebrew at runtime.
let homebrewPrefix = "/opt/homebrew"

let package = Package(
    name: "sidplayer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SIDEngine", targets: ["SIDEngine"]),
        .executable(name: "sidspike", targets: ["sidspike"]),
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
        .executableTarget(
            name: "sidspike",
            dependencies: ["SIDEngine"],
            path: "Sources/sidspike"
        ),
        .testTarget(
            name: "SIDEngineTests",
            dependencies: ["SIDEngine"],
            path: "Tests/SIDEngineTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
