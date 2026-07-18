// swift-tools-version: 6.0
import PackageDescription

#if canImport(XCTest)
let testSwiftSettings: [SwiftSetting]? = nil
let testLinkerSettings: [LinkerSetting]? = nil
#else
let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testSwiftSettings: [SwiftSetting]? = [.unsafeFlags([
    "-F", commandLineToolsFrameworks,
    "-Xfrontend", "-disable-cross-import-overlays",
    "-enable-experimental-feature", "SymbolLinkageMarkers",
])]
// ponytail: CLT-only test workaround; remove when SwiftPM supplies Testing.framework search paths and rpaths.
let testLinkerSettings: [LinkerSetting]? = [.unsafeFlags([
    "-F", commandLineToolsFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
])]
#endif

let package = Package(
    name: "CodexDreamSkinStudio",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "DreamSkinConfigRestoreCore", targets: ["DreamSkinConfigRestoreCore"]),
        .library(name: "DreamSkinStudioCore", targets: ["DreamSkinStudioCore"]),
        .executable(name: "dream-skin-config-restore", targets: ["DreamSkinConfigRestore"]),
    ],
    targets: [
        .target(name: "DreamSkinConfigRestoreCore"),
        .target(name: "DreamSkinStudioCore"),
        .executableTarget(name: "DreamSkinConfigRestore", dependencies: ["DreamSkinConfigRestoreCore"]),
        .testTarget(
            name: "DreamSkinConfigRestoreCoreTests",
            dependencies: ["DreamSkinConfigRestoreCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "DreamSkinStudioCoreTests",
            dependencies: ["DreamSkinStudioCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
