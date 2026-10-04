import Foundation
import InferenceAudio
import InferenceSDK
import XCTest

final class PCMTests: XCTestCase {
    func testFloatRoundTrip() {
        let floats: [Float] = [0, 0.5, -0.5, 1, -1, 2, -2]
        let data = PCM16.fromFloat(floats)
        XCTAssertEqual(PCM16.samples(data), [0, 16383, -16384, 32767, -32768, 32767, -32768])
        let back = PCM16.toFloat(data)
        XCTAssertEqual(back[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(back[4], -1)
    }

    func testLevels() {
        XCTAssertEqual(PCM16.peak(pcm([0, 100, -16384, 3])), 0.5)
        XCTAssertEqual(PCM16.peak(Data()), 0)
        XCTAssertEqual(PCM16.rms(pcm([Int16](repeating: 0, count: 100))), 0)
        XCTAssertEqual(PCM16.rms(pcm(sine(16_000))), Float(0.5 / 2.0.squareRoot()), accuracy: 0.01)
        XCTAssertEqual(PCM16.meter(0), 0)
        XCTAssertEqual(PCM16.meter(1), 1)
        XCTAssertEqual(PCM16.meter(0.001), 0)  // -60 dBFS
        XCTAssertEqual(PCM16.meter(0.01), 0.25, accuracy: 0.001)  // -40 dBFS
    }

    func testChannels() {
        let mono = pcm([1, -2])
        let stereo = PCM16.upmix(mono, channels: 2)
        XCTAssertEqual(PCM16.samples(stereo), [1, 1, -2, -2])
        XCTAssertEqual(PCM16.downmix(pcm([10, 20, -4, 0]), channels: 2), pcm([15, -2]))
        XCTAssertEqual(PCM16.upmix(mono, channels: 1), mono)
    }

    func testFormat() {
        XCTAssertEqual(PCMFormat.speech.bytesPerSecond, 32_000)
        XCTAssertEqual(PCMFormat(sampleRate: 24_000, channels: 2).bytesPerFrame, 4)
        XCTAssertEqual(PCMFormat.speech.duration(ofBytes: 16_000), 0.5)
    }

    func testFramer() {
        var f16 = PCMFramer(format: .speech)
        XCTAssertEqual(f16.bytesPerFrame, 640)
        var f24 = PCMFramer(format: PCMFormat(sampleRate: 24_000, channels: 1))
        XCTAssertEqual(f24.bytesPerFrame, 960)
        XCTAssertEqual(f16.append(Data(count: 639)), [])
        XCTAssertEqual(f16.append(Data(count: 1300)).map(\.count), [640, 640, 640])
        XCTAssertEqual(f16.pendingBytes, 19)
        XCTAssertEqual(f16.flush()?.count, 19)
        XCTAssertNil(f16.flush())
        XCTAssertEqual(f24.append(Data(count: 960 * 2 + 1)).map(\.count), [960, 960])
        let stereo = PCMFramer(format: PCMFormat(sampleRate: 48_000, channels: 2), milliseconds: 10)
        XCTAssertEqual(stereo.bytesPerFrame, 1920)
    }

    func testSilenceGate() {
        var gate = SilenceGate()
        XCTAssertFalse(gate.pass(level: 0, now: 100), "silence before any sound is not sent")
        XCTAssertTrue(gate.pass(level: 0.2, now: 101))
        XCTAssertTrue(gate.pass(level: 0.0001, now: 104), "the pause after speech still goes out")
        XCTAssertTrue(gate.pass(level: 0, now: 107))
        XCTAssertFalse(gate.pass(level: 0, now: 107.1), "past the 6 s tail")
        XCTAssertTrue(gate.pass(level: 0.0005, now: 200), "the threshold counts as sound")
    }
}

final class ResamplerTests: XCTestCase {
    /// 1 s at 16 kHz in uneven pieces → 1 s at 24 kHz in whole 20 ms frames, same tone and level.
    func check(_ resampler: any PCMResampler, file: StaticString = #filePath, line: UInt = #line) {
        var framer = PCMFramer(format: PCMFormat(sampleRate: resampler.outputRate, channels: 1))
        let input = sine(resampler.inputRate)
        var frames: [Data] = []
        var at = 0
        var piece = 480
        while at < input.count {
            let n = min(piece, input.count - at)
            frames += framer.append(resampler.process(pcm(Array(input[at..<at + n]))))
            at += n
            piece = piece == 480 ? 517 : 480
        }
        frames += framer.append(resampler.flush())
        let last = framer.flush()
        let total = frames.reduce(0) { $0 + $1.count } + (last?.count ?? 0)
        XCTAssertEqual(Double(total / 2), Double(resampler.outputRate), accuracy: Double(resampler.outputRate) / 500,
                       "1 s in, 1 s out", file: file, line: line)
        let middle = frames.dropFirst(5).prefix(20).reduce(Data(), +)
        XCTAssertEqual(PCM16.rms(middle), Float(0.5 / 2.0.squareRoot()), accuracy: 0.03, file: file, line: line)
    }

    func testLinearUp() { check(LinearResampler(from: 16_000, to: 24_000)) }
    func testLinearDown() { check(LinearResampler(from: 48_000, to: 16_000)) }
    func testBestUp() { check(makeResampler(from: 16_000, to: 24_000)) }

    func testLinearSamples() {
        let r = LinearResampler(from: 1, to: 2)
        XCTAssertEqual(PCM16.samples(r.process(pcm([0, 100]))), [0, 50])
        XCTAssertEqual(PCM16.samples(r.process(pcm([200]))), [100, 150])
        XCTAssertEqual(PCM16.samples(r.flush()), [200, 200])
    }

    func testSameRatePassesThrough() {
        for r in [LinearResampler(from: 16_000, to: 16_000), makeResampler(from: 16_000, to: 16_000)] as [any PCMResampler] {
            let data = pcm(sine(100))
            XCTAssertEqual(r.process(data), data)
            XCTAssertEqual(r.flush(), Data())
        }
    }
}
