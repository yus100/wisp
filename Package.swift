// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrokSpotlight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GrokSpotlight",
            path: "Sources/GrokSpotlight",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
