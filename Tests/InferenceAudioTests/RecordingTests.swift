import Foundation
import InferenceAudio
import InferenceSDK
import XCTest

final class RecordingTests: XCTestCase {
    func testSegmentsRotateAndReadBackAcrossBoundaries() throws {
        let store = RecordingStore(root: temporaryDirectory())
        var m = RecordingManifest(id: "r1")
        try store.create(m)
        let writer = SegmentWriter(directory: store.directory(m.id), config: .init(maxSegmentSamples: 1000))
        let started = Locked<[String]>([])
        writer.onSegmentStarted = { segment in started.mutate { $0.append(segment.file) } }
        let audio = pcm((0..<2500).map { Int16($0 % 1000) })
        try writer.append(audio.prefix(1001))  // half a sample waits for the next append
        try writer.append(audio.dropFirst(1001))
        try writer.close()
        XCTAssertEqual(started.value, ["seg-0000.pcm", "seg-0001.pcm", "seg-0002.pcm"])
        XCTAssertEqual(writer.totalSamples, 2500)

        store.finalize(&m)
        XCTAssertEqual(m.segments.map(\.sampleCount), [1000, 1000, 500])
        XCTAssertEqual(m.segments.map(\.startSample), [0, 1000, 2000])
        XCTAssertEqual(m.state, .ended)
        XCTAssertEqual(try store.readPCM(m, 900..<2100), audio.subdata(in: 1800..<4200))
        XCTAssertThrowsError(try store.readPCM(m, 0..<2501))
        let clip = try store.clipWAV(m, from: 2400, to: 9999)  // clamped
        XCTAssertEqual(try WAV.decode(clip).pcm, audio.subdata(in: 4800..<5000))
        let joined = store.directory(m.id).appendingPathComponent("all.wav")
        try store.joinWAV(m, to: joined)
        XCTAssertEqual(try WAV.read(joined).pcm, audio)
    }

    func testManifestSavesAtomicallyAndLoadsLeniently() throws {
        let store = RecordingStore(root: temporaryDirectory())
        var m = RecordingManifest(id: "r2", metadata: ["title": "standup"])
        try store.create(m)
        m.gaps.append(.init(atSample: 10, startedAt: Date(), reason: "call"))
        try store.save(m)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(m.id, "manifest.json.tmp").path))
        let loaded = try store.load("r2")
        XCTAssertEqual(loaded.metadata["title"], "standup")
        XCTAssertEqual(loaded.gaps.count, 1)
        // Fields a writer did not know about yet default.
        try Data(#"{"id":"r3","startedAt":"2026-10-04T10:00:00Z","state":"recording"}"#.utf8)
            .write(to: { try? FileManager.default.createDirectory(at: store.directory("r3"), withIntermediateDirectories: true); return store.url("r3", "manifest.json") }())
        let old = try store.load("r3")
        XCTAssertEqual(old.sampleRate, 16_000)
        XCTAssertEqual(old.segments, [])
        XCTAssertEqual(store.list().map(\.id).sorted(), ["r2", "r3"])
    }

    /// The process died mid-recording: a segment the manifest never heard
    /// of, a torn last sample, an open gap. Recovery rebuilds it from disk.
    func testRecoversAfterACrash() throws {
        let store = RecordingStore(root: temporaryDirectory())
        var m = RecordingManifest(id: "crashed", startedAt: Date(timeIntervalSinceNow: -60))
        m.gaps.append(.init(atSample: 400, startedAt: Date(timeIntervalSinceNow: -30), reason: "interruption"))
        try store.create(m)
        try pcm([Int16](repeating: 7, count: 300)).write(to: store.url(m.id, "seg-0000.pcm"))
        try (pcm([Int16](repeating: 8, count: 200)) + Data([1])).write(to: store.url(m.id, "seg-0001.pcm"))
        try Data().write(to: store.url(m.id, "seg-0002.pcm"))
        let recovered = store.recoverInterrupted()
        XCTAssertEqual(recovered.map(\.id), ["crashed"])
        let r = try store.load("crashed")
        XCTAssertEqual(r.state, .ended)
        XCTAssertEqual(r.segments.map(\.sampleCount), [300, 200])
        XCTAssertEqual(r.totalSamples, 500)
        XCTAssertNotNil(r.endedAt)
        XCTAssertNotNil(r.gaps[0].endedAt)
        XCTAssertEqual(r.gaps[0].atSample, 400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(m.id, "seg-0002.pcm").path))
        XCTAssertEqual(try Data(contentsOf: store.url(m.id, "seg-0001.pcm")).count, 400, "the torn byte is trimmed")
        XCTAssertTrue(store.recoverInterrupted().isEmpty, "only once")
    }

    func testRecorderCapturesInterruptsAndResumes() async throws {
        let store = RecordingStore(root: temporaryDirectory())
        let source = ManualSource()
        let recorder = CrashSafeRecorder(store: store, source: source, segmentConfig: .init(maxSegmentSamples: 16_000))
        recorder.handlesInterruptions = false
        let heard = Locked(0)
        recorder.onAudio = { pcm in heard.mutate { $0 += pcm.count } }
        let first = try await recorder.start(metadata: ["title": "test"])
        XCTAssertEqual(try store.load(first.id).state, .recording)
        for _ in 0..<60 { source.feed(pcm(sine(320))) }  // 1.2 s
        await eventually("written") { recorder.current.elapsed >= 1.2 }
        // A crash now would leave the samples on disk.
        XCTAssertEqual(store.current(try store.load(first.id)).totalSamples, 19_200)

        await recorder.interrupt(reason: "call")
        XCTAssertEqual(recorder.current.state, .interrupted(reason: "call"))
        try await recorder.resume()
        for _ in 0..<10 { source.feed(pcm(sine(320))) }
        await eventually("written") { recorder.current.elapsed >= 1.4 }
        let stopped = await recorder.stop()
        let done = try XCTUnwrap(stopped)
        XCTAssertEqual(done.state, .ended)
        XCTAssertEqual(done.totalSamples, 22_400)
        XCTAssertEqual(done.segments.map(\.file), ["seg-0000.pcm", "seg-0001.pcm", "seg-0002.pcm"])
        XCTAssertEqual(done.gaps.count, 1)
        XCTAssertEqual(done.gaps[0].atSample, 19_200)
        XCTAssertNotNil(done.gaps[0].endedAt)
        XCTAssertEqual(done.metadata["title"], "test")
        XCTAssertEqual(heard.value, 22_400 * 2)
        XCTAssertEqual(try store.load(done.id), done)
        XCTAssertEqual(recorder.current.state, .idle)
    }
}
