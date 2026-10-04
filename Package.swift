// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InferenceSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "InferenceSDK", targets: ["InferenceSDK"]),
    ],
    targets: [
        .target(name: "InferenceSDK"),
        // Example CLIs and live end-to-end checks (see Makefile `e2e`, `live`).
        // Not products, so depending on the library never builds them.
        .executableTarget(name: "agent-run", dependencies: ["InferenceSDK"], path: "Examples/agent-run"),
        .executableTarget(name: "live-run", dependencies: ["InferenceSDK"], path: "Examples/live-run"),
        .testTarget(name: "InferenceSDKTests", dependencies: ["InferenceSDK"], resources: [.copy("Fixtures")]),
    ]
)
