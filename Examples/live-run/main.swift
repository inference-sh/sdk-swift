// Usage example and end-to-end check for live (stream) functions:
//   INFERENCE_API_KEY=... swift run live-run <namespace/app> [key=value ...]
// Starts the app's stream function, opens its socket, prints what arrives,
// closes after a while and prints the task's result. key=value pairs are the
// function's ordinary inputs (the request body).
// FUNCTION=talk     the function to run; default: the app's stream function.
// AUDIO_FILE=a.wav  16-bit PCM WAV streamed into the input's binary live field,
//                   20 ms frames in real time, once the app is there.
// SEND='{"events":{"type":"text","text":"hi"}}'  a JSON frame to send once live.
// STAY=5            seconds to stay after the last frame went out.

import Foundation
import InferenceSDK

signal(SIGPIPE, SIG_IGN) // Linux: a peer closing mid-write must surface as an error, not kill the process
setvbuf(stdout, nil, _IOLBF, 0) // lines appear as they happen, also through a pipe
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
guard args.count >= 2, let key = env["INFERENCE_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("usage: INFERENCE_API_KEY=... live-run <namespace/app> [key=value ...]\n".utf8))
    exit(2)
}
let client = InferenceClient(baseURL: URL(string: env["INFERENCE_API_URL"] ?? "https://api.inference.sh")!, apiKey: key)
let (appRef, input) = parseAppSpec(args.dropFirst().joined(separator: " "))

/// The PCM of a WAV file: its `data` chunk and the rate its `fmt ` chunk declares.
@Sendable func readWAV(_ path: String) throws -> (pcm: Data, sampleRate: Int) {
    let file = try Data(contentsOf: URL(fileURLWithPath: path))
    func u32(_ at: Int) -> Int { file[at..<at + 4].reversed().reduce(0) { $0 << 8 | Int($1) } }
    var offset = 12, sampleRate = 0
    while offset + 8 <= file.count {
        let id = String(decoding: file[offset..<offset + 4], as: UTF8.self), size = u32(offset + 4)
        if id == "fmt " { sampleRate = u32(offset + 12) }
        if id == "data" { return (file.subdata(in: offset + 8..<min(offset + 8 + size, file.count)), sampleRate) }
        offset += 8 + size + size % 2
    }
    throw InferenceError.transport("\(path) has no data chunk: is it a WAV file?")
}

func json(_ value: LiveValue) -> String {
    guard case .json(let value) = value else { return "<binary>" }
    return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

do {
    // The function's schemas say what its socket carries.
    let functions = try await client.apps.getByName(appRef).version?.functions ?? [:]
    let name = env["FUNCTION"] ?? functions.filter { $0.value.kind == .stream }.keys.sorted().first
    guard let name, let function = functions[name] else {
        print("ERROR: \(appRef) has no stream function (functions: \(functions.keys.sorted()))")
        exit(1)
    }
    let liveInput = splitLiveSchema(function.inputSchema).live
    let liveOutput = splitLiveSchema(function.outputSchema).live
    let describe = { (fields: [LiveField]) in
        fields.map { field in
            if let pcm = pcmFormat(field.media) { return "\(field.key): pcm \(pcm.sampleRate) Hz x\(pcm.channels)" }
            if field.binary { return "\(field.key): \(field.media?.type ?? "binary")" }
            let kinds = field.alternatives.enumerated().map { alternativeLabel($1, index: $0, discriminator: field.discriminator) }
            return "\(field.key): \(kinds.joined(separator: " | "))"
        }
    }
    print("function \(name): takes \(describe(liveInput)), sends \(describe(liveOutput))")

    let (task, session) = try await client.live(
        ApiAppRunRequest(app: appRef, input: .object(input), function: name),
        options: OpenSocketOptions(inputSchema: function.inputSchema, outputSchema: function.outputSchema))
    print("task \(task.id) socket \(task.socket?.id ?? "-")")

    // Once the app is there: send what was asked, stay a while, close.
    let micro = binaryLiveField(liveInput)
    let talk: @Sendable () async throws -> Void = {
        if let json = env["SEND"], let patch = try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)) {
            print("→ \(json)")
            session.sendPatch(patch)
        }
        if let path = env["AUDIO_FILE"], let micro {
            let (pcm, sampleRate) = try readWAV(path)
            let format = pcmFormat(micro.media)
            if let format, format.sampleRate != sampleRate {
                print("WARNING: \(path) is \(sampleRate) Hz, \(micro.key) takes \(format.sampleRate) Hz")
            }
            let frame = (format?.sampleRate ?? sampleRate) / 50 * 2  // 20 ms of 16-bit mono
            var sent = 0
            for start in stride(from: 0, to: pcm.count, by: frame) {
                try session.sendField(micro.key, .binary(pcm.subdata(in: start..<min(start + frame, pcm.count))))
                sent += 1
                try await Task.sleep(for: .milliseconds(20))
            }
            print("→ \(sent) frames of \(micro.key) (\(pcm.count) bytes)")
        }
        try await Task.sleep(for: .seconds(Double(env["STAY"] ?? "") ?? 5))
        session.close()
    }

    var sender: Task<Void, Error>?
    var received = (frames: 0, bytes: 0)
    for await event in session.events {
        switch event {
        case .state(.live):
            print("state: live")
            sender = Task(operation: talk)
        case .state(let state): print("state: \(state)")
        case .binary(let data): received = (received.frames + 1, received.bytes + data.count)
        case .patch(let patch) where patch.isEmpty: print("← {}")
        case .patch: session.updates(for: event).forEach { print("← \($0.field) = \(json($0.value))") }
        case .clear(let field): print("← clear \(field)")
        case .error(let field, let message): print("← error \(field ?? "-"): \(message)")
        case .text(let text): print("← text \(text)")
        }
    }
    sender?.cancel()
    let end = await session.ended
    print("← \(received.frames) binary frames (\(received.bytes) bytes)")
    print("ended: code=\(end.code) reason=\(end.reason.debugDescription) byCaller=\(end.byCaller) taskEnded=\(end.taskEnded)")

    guard end.byCaller || end.code == 1000 else {
        // The socket broke; the app may still be holding its end.
        try? await client.tasks.cancel(task.id)
        print("UNEXPECTED END, task cancelled")
        exit(1)
    }
    // What the function returned is the task's result.
    let done = try await client.tasks.watch(task.id)
    print("task \(done.status == .completed ? "completed" : "status \(done.status.rawValue)"): \(json(.json(done.output)))")
    print("OK")
    exit(0)
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
