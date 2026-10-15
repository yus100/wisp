// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that does not need AppKit: the ACP client, agent process, conversation model,
        // speech-to-text client, Ghostty launcher, config, and parsing. Covered by WispCoreTests.
        .target(name: "WispCore"),
        // The menu-bar app: panel, views, hotkeys, microphone, and the `ctl` remote control.
        .executableTarget(
            name: "Wisp",
            dependencies: ["WispCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
