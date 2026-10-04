// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InferenceSDK",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "InferenceSDK", targets: ["InferenceSDK"]),
        // Audio on top of the SDK: microphone and playback for live functions,
        // live dictation, voice calls, crash-safe recordings. Its pure parts
        // (PCM, WAV, framing, resampling, transcripts, recordings on disk) build
        // everywhere; capture and playback need AVFoundation.
        .library(name: "InferenceAudio", targets: ["InferenceAudio"]),
    ],
    targets: [
        .target(name: "InferenceSDK"),
        .target(name: "InferenceAudio", dependencies: ["InferenceSDK"]),
        // Example CLIs and live end-to-end checks (see Makefile `e2e`, `live`).
        // Not products, so depending on the library never builds them.
        .executableTarget(name: "agent-run", dependencies: ["InferenceSDK"], path: "Examples/agent-run"),
        .executableTarget(name: "live-run", dependencies: ["InferenceSDK"], path: "Examples/live-run"),
        .testTarget(name: "InferenceSDKTests", dependencies: ["InferenceSDK"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InferenceAudioTests", dependencies: ["InferenceAudio", "InferenceSDK"]),
    ]
)
