import Foundation
import InferenceAudio
import InferenceSDK
import XCTest

final class WAVTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let audio = pcm(sine(1000))
        let file = WAV.wrap(audio, format: PCMFormat(sampleRate: 24_000, channels: 1))
        XCTAssertEqual(file.count, 44 + audio.count)
        let (decoded, format) = try WAV.decode(file)
        XCTAssertEqual(format, WAVFormat(sampleRate: 24_000, channels: 1))
        XCTAssertEqual(decoded, audio)
    }

    func testDecodeStopsAtTheDeclaredSize() throws {
        let audio = pcm(sine(100))
        let file = WAV.wrap(audio) + Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("INFO".utf8)
        XCTAssertEqual(try WAV.decode(file).pcm, audio)
    }

    func testSkipsAppleHeader() throws {
        let audio = pcm(sine(1600))
        var parser = WAVStreamParser()
        let out = try parser.feed(appleWAVHeader(rate: 16_000) + audio)
        XCTAssertEqual(parser.format, WAVFormat(sampleRate: 16_000, channels: 1))
        XCTAssertEqual(out, audio)
        XCTAssertEqual(parser.dataSizeOffset, 12 + 24 + 8 + 4000 + 4)
    }

    func testPartialWritesInAnyPieces() throws {
        let audio = pcm(sine(4000))
        let file = appleWAVHeader(rate: 16_000) + audio
        for piece in [1, 3, 7, 44, 45, 333, 4096] {
            var parser = WAVStreamParser()
            var out = Data()
            var at = 0
            while at < file.count {
                out.append(try parser.feed(file.subdata(in: at..<min(at + piece, file.count))))
                at += piece
            }
            XCTAssertEqual(out, audio, "pieces of \(piece) bytes")
        }
    }

    func testHeaderNotThereYet() throws {
        var parser = WAVStreamParser()
        let header = appleWAVHeader(rate: 16_000)
        XCTAssertEqual(try parser.feed(header.prefix(44)), Data())  // a 44-byte skip would land inside FLLR
        XCTAssertNil(parser.dataSizeOffset)
        XCTAssertEqual(try parser.feed(header.dropFirst(44)), Data())
        XCTAssertNotNil(parser.dataSizeOffset)
        XCTAssertEqual(try parser.feed(Data([1])), Data())  // half a sample waits
        XCTAssertEqual(try parser.feed(Data([2])), Data([1, 2]))
    }

    func testFloatStereoIsDownmixed() throws {
        // AVAudioFile on the Mac: JUNK, fmt (float), FLLR, data; 2 channels.
        let frames: [(Float, Float)] = [(0.5, 0.5), (1, -1), (-0.25, -0.25), (2, 2)]
        var body = Data()
        for (l, r) in frames {
            body.append(contentsOf: withUnsafeBytes(of: l.bitPattern.littleEndian, Array.init))
            body.append(contentsOf: withUnsafeBytes(of: r.bitPattern.littleEndian, Array.init))
        }
        var parser = WAVStreamParser()
        let out = try parser.feed(appleWAVHeader(rate: 48_000, channels: 2, bits: 32, float: true, junk: true) + body)
        XCTAssertEqual(PCM16.samples(out), [16384, 0, -8192, 32767])
    }

    func testNotAWAV() {
        var parser = WAVStreamParser()
        XCTAssertThrowsError(try parser.feed(Data("OggS0000000000000000".utf8)))
    }

    /// The writer's file is readable after every flush, as a crash would leave it.
    func testWriterIsReadableMidway() throws {
        let url = temporaryDirectory().appendingPathComponent("w.wav")
        let writer = try WAVWriter(url: url, format: .speech)
        try writer.append(pcm(sine(800)))
        try writer.flush()
        XCTAssertEqual(try WAV.read(url).pcm, pcm(sine(800)))
        try writer.append(pcm([1, 2, 3]))
        try writer.close()
        try writer.append(pcm([9]))  // ignored after close
        let (audio, format) = try WAV.read(url)
        XCTAssertEqual(audio, pcm(sine(800)) + pcm([1, 2, 3]))
        XCTAssertEqual(format.sampleRate, 16_000)
    }

    /// A recorder writing the file in uneven pieces while the tailer polls;
    /// at the end the header gets its data size and a chunk follows the
    /// audio, which the tailer must not read as audio.
    func testTailerFollowsAGrowingFile() throws {
        let url = temporaryDirectory().appendingPathComponent("tail.wav")
        let audio = pcm(sine(16_000))  // 1 s
        let header = appleWAVHeader(rate: 16_000)
        let tailer = WAVFileTailer(url: url, interval: 0.005)
        let received = Locked(Data())
        tailer.onAudio = { chunk, format in
            XCTAssertEqual(format.sampleRate, 16_000)
            received.mutate { $0.append(chunk) }
        }
        tailer.start()
        Thread.sleep(forTimeInterval: 0.02)  // polling a file that does not exist yet
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        let file = header + audio
        var at = 0
        var step = 1
        while at < file.count {
            let n = min(step, file.count - at)
            writer.write(file.subdata(in: at..<at + n))
            at += n
            step = step * 3 % 2_999 + 1
            if at % 5 == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(received.value.count, 0, "audio arrives while the file is still being written")
        // Finish like a recorder: a trailing chunk, then the header's size.
        writer.write(Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("INFO".utf8))
        try writer.seek(toOffset: UInt64(header.count - 4))
        writer.write(withUnsafeBytes(of: UInt32(audio.count).littleEndian) { Data($0) })
        try writer.close()
        tailer.finish()
        XCTAssertEqual(received.value, audio)
    }

    func testFileSourceFramesAtTheAskedFormat() async throws {
        let url = try toneWAV(seconds: 0.5)
        let source = WAVFileSource(url: url, realtime: false, trailingSilence: 0.1)
        var frames: [Data] = []
        for try await frame in try await source.start(format: PCMFormat(sampleRate: 24_000, channels: 1)) {
            frames.append(frame)
        }
        XCTAssertTrue(frames.dropLast().allSatisfy { $0.count == 960 })
        let seconds = Double(frames.reduce(0) { $0 + $1.count }) / 48_000
        XCTAssertEqual(seconds, 0.6, accuracy: 0.03)
        // Started again, it plays again.
        var again = 0
        for try await _ in try await source.start(format: .speech) { again += 1 }
        XCTAssertEqual(again, 30)
    }

    func testFileSourcePacesInRealTime() async throws {
        let url = try toneWAV(seconds: 0.3)
        let source = WAVFileSource(url: url)
        let started = Date()
        var count = 0
        for try await _ in try await source.start(format: .speech) { count += 1 }
        XCTAssertEqual(count, 15)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.25)
    }
}
