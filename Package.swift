// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InferenceSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "InferenceSDK", targets: ["InferenceSDK"]),
        .executable(name: "agent-run", targets: ["agent-run"]),
    ],
    targets: [
        .target(name: "InferenceSDK"),
        .executableTarget(name: "agent-run", dependencies: ["InferenceSDK"]),
        .testTarget(name: "InferenceSDKTests", dependencies: ["InferenceSDK"], resources: [.copy("Fixtures")]),
    ]
)
