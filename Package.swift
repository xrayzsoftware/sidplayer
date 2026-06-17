// swift-tools-version:5.9
import PackageDescription

// libsidplayfp is vendored as a static archive under
// Sources/CSIDEngine/Vendor/. The archive is self-contained (only depends
// on libc++ / libSystem) so the resulting .app has no Homebrew runtime
// dependency. arm64 only at the moment.

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
        // Pure-Swift 7z reader. HVSC ships only 7z and AppSandbox forbids
        // shelling out to /usr/bin/tar.
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6"),
    ],
    targets: [
        .target(
            name: "CSIDEngine",
            path: "Sources/CSIDEngine",
            // Don't try to compile the vendored archive as a source file.
            exclude: ["Vendor/lib"],
            publicHeadersPath: "include",
            cxxSettings: [
                // libsidplayfp's own headers (vendored). Path is relative
                // to the target source directory.
                .headerSearchPath("Vendor/include"),
            ],
            linkerSettings: [
                // Pass the static archives directly to the linker. Paths are
                // relative to the package root. Force-load isn't required —
                // libsidplayfp symbols are referenced from CSIDEngine.mm.
                // libsidplayfp's ReSIDfp builder references the reSIDfp DSP in
                // libresidfp, so it must follow libsidplayfp on the link line.
                .unsafeFlags([
                    "Sources/CSIDEngine/Vendor/lib/libsidplayfp.a",
                    "Sources/CSIDEngine/Vendor/lib/libresidfp.a",
                ]),
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
                .product(name: "SWCompression", package: "SWCompression"),
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
