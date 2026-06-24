// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyDictate",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyDictate",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MyDictate"
        )
    ]
)
