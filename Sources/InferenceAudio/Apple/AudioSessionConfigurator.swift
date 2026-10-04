#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// The app's audio session, set up for what it is doing, and what happens
/// to it (interruptions, route changes) as async streams.
///
/// AVAudioSession exists on iOS, watchOS, tvOS and visionOS. On macOS there
/// is none: `apply`, `activate` and `deactivate` do nothing, the route is
/// empty and the streams finish at once, so the same code runs on the Mac.
///
/// Bluetooth speaker mics (HFP): every recording preset allows the HFP
/// route. Over HFP while Apple's PushToTalk framework owns the session, an
/// AVAudioEngine input tap never fires; `Microphone` switches to its
/// recorder backend there (see `Microphone.Backend`).
public struct AudioSessionConfigurator: Sendable {
    public static let shared = AudioSessionConfigurator()

    public init() {}

    public enum Preset: Sendable, Equatable {
        /// A call: `.playAndRecord` in `.voiceChat` mode (the system's echo
        /// cancellation and gain control, with `Microphone(voiceProcessing: true)`),
        /// Bluetooth HFP allowed, loudspeaker by default.
        case voiceChat
        /// Push-to-talk and dictation: `.playAndRecord` in the default mode,
        /// Bluetooth HFP allowed (a speaker mic), loudspeaker by default. With
        /// the PushToTalk framework, apply it before a transmission; the
        /// framework activates the session itself.
        case pushToTalk
        /// Long recordings: `.playAndRecord`, Bluetooth HFP allowed, mixes
        /// with other audio so a recording does not stop the user's music.
        case record
        /// Listening back: `.playback` in `.spokenAudio` mode (plays with the
        /// screen locked, given the `audio` background mode).
        case playback
    }

    /// The system took the session (a call, Siri, an alarm) or gave it back.
    public enum Interruption: Equatable, Sendable {
        case began
        /// `shouldResume`: the system says capture or playback may continue.
        case ended(shouldResume: Bool)
    }

    /// One input or output of the route.
    public struct Port: Equatable, Sendable {
        public var name: String
        /// The port type's raw value, e.g. "BluetoothHFP", "MicrophoneBuiltIn".
        public var type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }

        /// A Bluetooth hands-free (HFP) port: a headset or speaker mic.
        public var isBluetoothHFP: Bool { type == "BluetoothHFP" }
    }

    public struct Route: Equatable, Sendable {
        public var inputs: [Port]
        public var outputs: [Port]

        public init(inputs: [Port] = [], outputs: [Port] = []) {
            self.inputs = inputs
            self.outputs = outputs
        }

        /// The microphone is a Bluetooth HFP device.
        public var isBluetoothHFPInput: Bool { inputs.contains(where: \.isBluetoothHFP) }
    }

    public struct RouteChange: Equatable, Sendable {
        /// Why: "newDeviceAvailable", "oldDeviceUnavailable", "categoryChange", "override", …
        public var reason: String
        /// The route after the change.
        public var route: Route
    }

    #if os(macOS)
    public func apply(_ preset: Preset) throws {}
    public func activate() async throws {}
    public func deactivate() {}
    public var currentRoute: Route { Route() }
    public func interruptions() -> AsyncStream<Interruption> { AsyncStream { $0.finish() } }
    public func routeChanges() -> AsyncStream<RouteChange> { AsyncStream { $0.finish() } }
    public func mediaServicesResets() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    #else
    /// `AVAudioSession.CategoryOptions.allowBluetoothHFP` (named
    /// `.allowBluetooth` before the iOS 26 SDK): the raw value builds with both.
    private static let allowBluetoothHFP = AVAudioSession.CategoryOptions(rawValue: 0x4)
    #if os(watchOS)
    private static let defaultToSpeaker: AVAudioSession.CategoryOptions = []  // the watch has one speaker
    #else
    private static let defaultToSpeaker: AVAudioSession.CategoryOptions = .defaultToSpeaker
    #endif

    /// Sets the session's category, mode and options for `preset`.
    public func apply(_ preset: Preset) throws {
        let session = AVAudioSession.sharedInstance()
        switch preset {
        case .voiceChat:
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [Self.allowBluetoothHFP, Self.defaultToSpeaker])
        case .pushToTalk:
            try session.setCategory(.playAndRecord, mode: .default, options: [Self.allowBluetoothHFP, Self.defaultToSpeaker])
        case .record:
            try session.setCategory(.playAndRecord, mode: .default, options: [Self.allowBluetoothHFP, Self.defaultToSpeaker, .mixWithOthers])
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
    }

    /// Activates the session without blocking the caller's thread (it can
    /// take a moment while a Bluetooth route comes up).
    public func activate() async throws {
        #if os(watchOS)
        let session = AVAudioSession.sharedInstance()
        _ = try await session.activate(options: [])
        #else
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(true)
        }.value
        #endif
    }

    /// Deactivates the session and lets other apps' audio resume.
    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public var currentRoute: Route { Self.route(AVAudioSession.sharedInstance().currentRoute) }

    /// Interruptions from now on, until the stream is dropped.
    public func interruptions() -> AsyncStream<Interruption> {
        observe(AVAudioSession.interruptionNotification) { note in
            let info = note.userInfo ?? [:]
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began: return .began
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                return .ended(shouldResume: options.contains(.shouldResume))
            @unknown default: return nil
            }
        }
    }

    /// Route changes from now on (a headset came or went), until the stream is dropped.
    public func routeChanges() -> AsyncStream<RouteChange> {
        observe(AVAudioSession.routeChangeNotification) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(Self.name) ?? "unknown"
            return RouteChange(reason: reason, route: Self.route(AVAudioSession.sharedInstance().currentRoute))
        }
    }

    /// The media server restarted: every engine and player must be rebuilt.
    public func mediaServicesResets() -> AsyncStream<Void> {
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in () }
    }

    private func observe<T: Sendable>(_ name: Notification.Name, _ map: @escaping @Sendable (Notification) -> T?) -> AsyncStream<T> {
        AsyncStream { continuation in
            let token = ObserverToken(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                if let value = map(note) { continuation.yield(value) }
            })
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.token) }
        }
    }

    private static func route(_ route: AVAudioSessionRouteDescription) -> Route {
        Route(inputs: route.inputs.map { Port(name: $0.portName, type: $0.portType.rawValue) },
              outputs: route.outputs.map { Port(name: $0.portName, type: $0.portType.rawValue) })
    }

    private static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    #endif
}

/// A notification observer handed to a @Sendable cleanup closure.
final class ObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
}
#endif
