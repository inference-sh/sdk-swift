// Live dictation with InferenceAudio, and its end-to-end check:
//   INFERENCE_API_KEY=... swift run live-dictate [namespace/app key=value ...]
// Streams the microphone (or a WAV file) into an STT app's stream function
// with LiveTranscriber and prints the transcript as it forms: [settled] tail.
// Release (Enter, STOP_AFTER, or the end of the file) prints the final text.
// The app defaults to xai/grok-stt; one without a stream function is
// transcribed on release instead.
// AUDIO_FILE=speech.wav   feed a WAV in real time instead of the microphone
// STOP_AFTER=10           stop the microphone after this long (default: Enter)
// BACKEND=engine|recorder the microphone backend (default: automatic)
// BATCH=1                 skip streaming: record, transcribe on release

import Foundation
import InferenceAudio
import InferenceSDK

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
guard let key = env["INFERENCE_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("usage: INFERENCE_API_KEY=... live-dictate [namespace/app key=value ...]\n".utf8))
    exit(2)
}
let client = InferenceClient(baseURL: URL(string: env["INFERENCE_API_URL"] ?? "https://api.inference.sh")!, apiKey: key)
let spec = CommandLine.arguments.count > 1 ? CommandLine.arguments.dropFirst().joined(separator: " ") : "xai/grok-stt"

let started = Date()
@Sendable func clock() -> String { String(format: "%5.2fs", Date().timeIntervalSince(started)) }

let source: any AudioSource
var fromFile = false
if let path = env["AUDIO_FILE"], !path.isEmpty {
    source = WAVFileSource(url: URL(fileURLWithPath: path))
    fromFile = true
} else {
    #if canImport(AVFoundation)
    source = Microphone(backend: Microphone.Backend(rawValue: env["BACKEND"] ?? "") ?? .automatic)
    #else
    print("ERROR: no microphone on this platform; set AUDIO_FILE")
    exit(2)
    #endif
}

if env["BATCH"] == "1" { await LiveSpeechPlans.shared.remember(nil, for: spec, client: client) }
let transcriber = LiveTranscriber(client: client, app: spec, log: { print("  \(clock()) log: \($0)") })
print("\(spec): \(fromFile ? "file \(env["AUDIO_FILE"]!)" : "microphone")")
let printer = Task {
    var shown = ""
    for await snapshot in transcriber.updates {
        let line: String
        if snapshot.transcript.patches > 0 {
            line = "[\(snapshot.transcript.settled)] \(snapshot.transcript.tail)"
        } else {
            line = "\(snapshot.phase)"
        }
        if line != shown {
            shown = line
            print("  \(clock()) \(line)")
        }
    }
}

do {
    try await transcriber.start(source: source)
    #if canImport(AVFoundation)
    if let microphone = source as? Microphone { print("  \(clock()) recording (\(microphone.activeBackend?.rawValue ?? "-"))") }
    #endif
    if fromFile {
        // The file's frames run out: that is the release.
        while (source as? WAVFileSource)?.isRunning == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    } else if let seconds = Double(env["STOP_AFTER"] ?? "") {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    } else {
        print("  talk, then press Enter")
        _ = readLine()
    }
    let released = Date()
    print("  \(clock()) released after \(String(format: "%.1f", transcriber.current.elapsed)) s of audio")
    let text = try await transcriber.finish()
    _ = await printer.value
    print("final (\(String(format: "%.2f", Date().timeIntervalSince(released))) s after release): \(text)")
    guard !text.isEmpty else {
        print("ERROR: no text")
        exit(1)
    }
    print("OK")
    exit(0)
} catch {
    transcriber.cancel()
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}

