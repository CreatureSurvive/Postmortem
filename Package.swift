// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Postmortem",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "Postmortem", targets: ["Postmortem"]),
    ],
    targets: [
        .target(
            name: "Postmortem",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "PostmortemTests",
            dependencies: ["Postmortem"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
