import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InferenceAudio
import InferenceSDK
import XCTest

/// A WAV header the way Apple writes one: RIFF, fmt, a FLLR filler chunk,
/// then data (size 0 while recording).
func appleWAVHeader(rate: Int, channels: Int = 1, bits: Int = 16, float: Bool = false, dataSize: Int = 0,
                    junk: Bool = false) -> Data {
    var d = Data()
    func u32(_ v: Int) { d.append(contentsOf: withUnsafeBytes(of: UInt32(v).littleEndian, Array.init)) }
    func u16(_ v: Int) { d.append(contentsOf: withUnsafeBytes(of: UInt16(v).littleEndian, Array.init)) }
    d.append(contentsOf: Array("RIFF".utf8)); u32(0); d.append(contentsOf: Array("WAVE".utf8))
    if junk { d.append(contentsOf: Array("JUNK".utf8)); u32(28); d.append(Data(count: 28)) }
    d.append(contentsOf: Array("fmt ".utf8)); u32(16)
    u16(float ? 3 : 1); u16(channels); u32(rate); u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
    d.append(contentsOf: Array("FLLR".utf8)); u32(4000); d.append(Data(count: 4000))
    d.append(contentsOf: Array("data".utf8)); u32(dataSize)
    return d
}

func sine(_ count: Int, rate: Int = 16_000, hz: Double = 440, amplitude: Double = 0.5) -> [Int16] {
    (0..<count).map { Int16(amplitude * 32767 * sin(2 * .pi * hz * Double($0) / Double(rate))) }
}

func pcm(_ samples: [Int16]) -> Data { PCM16.data(samples) }

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("inference-audio-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A value shared with callbacks on other threads.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// Waits for something that happens on another task. Fails the test after 5 s.
func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                _ condition: @escaping () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for: \(what)", file: file, line: line)
}

/// A LiveSocket the test drives.
final class FakeSocket: LiveSocket, @unchecked Sendable {
    let events: AsyncStream<LiveSocketEvent>
    private let sink: AsyncStream<LiveSocketEvent>.Continuation
    private let frames = Locked<[LiveFrame]>([])

    init() { (events, sink) = AsyncStream.makeStream(of: LiveSocketEvent.self) }

    var sent: [LiveFrame] { frames.value }
    func send(_ frame: LiveFrame) { frames.mutate { $0.append(frame) } }
    func close(code: Int, reason: String) {
        sink.yield(.closed(code: code, reason: reason))
        sink.finish()
    }

    func open() { sink.yield(.opened) }
    func message(_ text: String) { sink.yield(.frame(.text(text))) }
    func message(_ data: Data) { sink.yield(.frame(.binary(data))) }
}

/// An AudioSink that keeps what it was given.
final class CollectingSink: AudioSink, @unchecked Sendable {
    let log = Locked<[String]>([])
    let played = Locked<[Data]>([])

    func start(format: PCMFormat) throws { log.mutate { $0.append("start \(format.sampleRate)") } }
    func play(_ pcm: Data) { played.mutate { $0.append(pcm) } }
    func flush() { log.mutate { $0.append("flush") } }
    func stop() { log.mutate { $0.append("stop") } }
}

/// An AudioSource the test feeds by hand.
final class ManualSource: AudioSource, @unchecked Sendable {
    let formats = Locked<[PCMFormat]>([])
    private let continuation = Locked<AsyncThrowingStream<Data, Error>.Continuation?>(nil)
    let stops = Locked(0)

    func start(format: PCMFormat) async throws -> AsyncThrowingStream<Data, Error> {
        formats.mutate { $0.append(format) }
        let (stream, c) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation.mutate { $0 = c }
        return stream
    }

    func feed(_ frame: Data) { continuation.value?.yield(frame) }

    func stop() {
        stops.mutate { $0 += 1 }
        continuation.value?.finish()
    }
}

/// Speech-like test signal: a 16-bit 16 kHz mono WAV file of a tone.
func toneWAV(seconds: Double, rate: Int = 16_000) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
    try WAV.wrap(pcm(sine(Int(seconds * Double(rate)), rate: rate)), format: PCMFormat(sampleRate: rate, channels: 1)).write(to: url)
    return url
}
