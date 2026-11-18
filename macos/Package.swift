// swift-tools-version:5.9
// sniplite for macOS: a native Swift / AppKit port of the Windows tool.
// Build the .app with ./build.sh (needs only the Command Line Tools).
import PackageDescription

let package = Package(
    name: "SnipLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnipLite",
            path: "Sources/SnipLite",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
