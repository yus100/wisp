// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that does not need AppKit: the ACP client, agent process, conversation model,
        // speech-to-text client, Ghostty launcher, config, and parsing. Covered by WispCoreTests.
        .target(name: "WispCore"),
        .target(name: "WispRendering", resources: [.copy("Resources")]),
        .testTarget(name: "WispRenderingTests", dependencies: ["WispRendering", "WispCore"]),
        // The menu-bar app: panel, views, hotkeys, microphone, and the `ctl` remote control.
        .executableTarget(
            name: "Wisp",
            dependencies: ["WispCore", "WispRendering"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "WispUITests", dependencies: ["Wisp", "WispCore"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
