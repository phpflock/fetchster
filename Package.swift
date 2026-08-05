// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fetchster",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Fetchster",
            path: "Sources/Fetchster"
        )
    ]
)
