// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudFerryLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CloudFerryLite",
            path: "Sources/CloudFerryLite",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
