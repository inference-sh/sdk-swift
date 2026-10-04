import Foundation

/// Follows a WAV file another writer is recording (AVAudioRecorder,
/// AVAudioFile, `WAVWriter`) and hands its audio on as mono 16-bit PCM as
/// the file grows. The file is polled every `interval` on a private queue.
///
/// This is how live audio gets out of `AVAudioRecorder`: over Bluetooth HFP
/// with the PushToTalk framework owning the audio session, an AVAudioEngine
/// input tap never fires, so capture has to be a recorder writing a file,
/// and the file is the stream (`Microphone.Backend.recorder`).
public final class WAVFileTailer: @unchecked Sendable {
    /// Audio as it arrives: mono Int16 LE at `format.sampleRate`, on the
    /// tailer's queue. Set before `start`.
    public var onAudio: ((Data, WAVFormat) -> Void)?
    /// The file is not a WAV this can read (called once; tailing stops). Set before `start`.
    public var onError: ((Error) -> Void)?

    public let url: URL
    public let interval: TimeInterval
    private let queue = DispatchQueue(label: "sh.inference.audio.tail", qos: .userInitiated)
    private var handle: FileHandle?
    private var parser = WAVStreamParser()
    private var timer: DispatchSourceTimer?
    private var failed = false
    /// File bytes read so far.
    private var offset = 0

    public init(url: URL, interval: TimeInterval = 0.02) {
        self.url = url
        self.interval = interval
    }

    /// Starts polling. The file may not exist yet.
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.poll(final: false) }
            timer = t
            t.resume()
        }
    }

    /// The writer has finished: reads what is left (up to the data size the
    /// finished header states) and stops. Synchronous: everything has been
    /// delivered through `onAudio` when it returns.
    public func finish() {
        queue.sync {
            timer?.cancel()
            timer = nil
            poll(final: true)
            try? handle?.close()
            handle = nil
        }
    }

    /// Stops without reading further.
    public func cancel() {
        queue.sync {
            timer?.cancel()
            timer = nil
            onAudio = nil
            try? handle?.close()
            handle = nil
        }
    }

    /// The format, once the header has been read.
    public var format: WAVFormat? { queue.sync { parser.format } }

    private func poll(final: Bool) {
        guard !failed else { return }
        if handle == nil {
            guard let h = try? FileHandle(forReadingFrom: url) else { return }
            handle = h
        }
        guard let handle else { return }
        var limit = Int.max
        if final, let at = parser.dataSizeOffset, let declared = Self.declaredDataSize(url, at: at) {
            limit = at + 4 + declared  // a finished file may carry chunks after its audio
        }
        while offset < limit {
            let want = min(64 * 1024, limit - offset)
            guard let bytes = try? handle.read(upToCount: want), !bytes.isEmpty else { break }
            offset += bytes.count
            do {
                let audio = try parser.feed(bytes)
                if !audio.isEmpty, let format = parser.format { onAudio?(audio, format) }
            } catch {
                failed = true
                onError?(error)
                return
            }
        }
    }

    /// The data chunk's size from the header, once the writer has filled it in.
    private static func declaredDataSize(_ url: URL, at offset: Int) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil,
              let b = try? h.read(upToCount: 4), b.count == 4 else { return nil }
        let size = b.readUInt32LE(0)
        return size > 0 && size < 0x7FFF_FFF0 ? Int(size) : nil  // unset placeholders: 0 or ~4 GB
    }
}
