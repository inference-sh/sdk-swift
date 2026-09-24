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
        // Example CLI and live end-to-end check (see Makefile `e2e`). Not a
        // product, so depending on the library never builds it.
        .executableTarget(name: "agent-run", dependencies: ["InferenceSDK"], path: "Examples/agent-run"),
        .testTarget(name: "InferenceSDKTests", dependencies: ["InferenceSDK"], resources: [.copy("Fixtures")]),
    ]
)
