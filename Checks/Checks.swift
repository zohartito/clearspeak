import Foundation
import AppKit
import Carbon
import ClearSpeakCore

struct CheckFailed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !condition() { throw CheckFailed(label) }
}
func expectError(_ expected: SpeechError, _ action: () throws -> Void) throws {
    do { try action(); throw CheckFailed("Expected rejection") }
    catch let actual as SpeechError { try expect(actual == expected, "Wrong error") }
}
func silence(seconds: Double = 0.15) -> SpeechChunk {
    SpeechChunk(samples: Data(repeating: 0, count: Int(24_000 * seconds) * 4))
}
@MainActor func waitUntil(_ label: String = "playback state", timeout: Double = 2, _ condition: () -> Bool) async throws {
    let attempts = Int(timeout / 0.01)
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try expect(condition(), "Timed out waiting for \(label)")
}
struct TimedPacket {
    let delay: UInt64
    let seconds: Double
}
@MainActor final class VariableThroughputProvider: SpeechProvider {
    private let plans: [[TimedPacket]]
    private var index = 0
    private var task: Task<Void, Never>?
    init(_ plans: [[TimedPacket]]) { self.plans = plans }
    func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        let plan = plans[min(index, plans.count - 1)]
        index += 1
        return AsyncThrowingStream { continuation in
            task = Task {
                for packet in plan {
                    do { try await Task.sleep(nanoseconds: packet.delay) }
                    catch { return }
                    continuation.yield(silence(seconds: packet.seconds))
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.task?.cancel() }
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }
}
@MainActor final class ImmediateProvider: SpeechProvider {
    func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        AsyncThrowingStream { $0.yield(silence(seconds: 0.5)); $0.finish() }
    }
}
@MainActor final class DelayedProvider: SpeechProvider {
    func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continuation.yield(silence())
                continuation.finish()
            }
        }
    }
}
@MainActor final class InvalidProvider: SpeechProvider {
    func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        AsyncThrowingStream { $0.yield(SpeechChunk(samples: Data([1, 2, 3]))); $0.finish() }
    }
}

@main struct Checks {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--live-continuity") {
            do { try await runLiveContinuity() }
            catch { print("FAIL live continuity check: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--live-narrators") {
            do { try await runLiveNarrators() }
            catch { print("FAIL live narrator check: \(error)"); exit(1) }
            return
        }
        var passed = 0
        func run(_ name: String, _ block: () async throws -> Void) async throws {
            try await block(); passed += 1; print("PASS \(name)")
        }
        do {
            try await run("Real hotkey registration, collision rollback and cleanup") {
                let keys = HotKeys()
                defer { keys.unregister() }
                try expect(keys.register(.r), "Default registration failed: " + keys.failures.joined())
                try expect(keys.register(.r), "Repeated registration leaked old keys")
                var reserved: EventHotKeyRef?
                let result = RegisterEventHotKey(ReadShortcut.t.keyCode, UInt32(controlKey | optionKey),
                    EventHotKeyID(signature: 0x54455354, id: 90), GetApplicationEventTarget(), 0, &reserved)
                try expect(result == noErr && reserved != nil, "Could not reserve collision fixture")
                defer { if let reserved { UnregisterEventHotKey(reserved) } }
                try expect(!keys.register(.t), "Conflicting read key accepted")
                try expect(keys.activeShortcut == .r, "Previous keys were not restored")
                try expect(keys.failures.contains(where: { $0.contains("Read") && $0.contains("already in use") }), "Missing action-specific failure")
                if let reserved { UnregisterEventHotKey(reserved) }
                reserved = nil
                try expect(keys.register(.t), "Could not change shortcut after collision removed")
                // Old read and pause keys must now be free, not silently active.
                for modifiers in [UInt32(controlKey | optionKey), UInt32(controlKey | optionKey | shiftKey)] {
                    var probe: EventHotKeyRef?
                    let status = RegisterEventHotKey(ReadShortcut.r.keyCode, modifiers,
                        EventHotKeyID(signature: 0x54455354, id: 91), GetApplicationEventTarget(), 0, &probe)
                    if let probe { UnregisterEventHotKey(probe) }
                    try expect(status == noErr, "Old shortcut leaked after rebind")
                }
                keys.unregister()
                try expect(keys.register(.r), "Shutdown failed to release keys or handler")
            }
            try await run("Reject blank and oversized inputs") {
                try expectError(.emptyText) { _ = try TextChunker.chunks(" \n\t") }
                try expectError(.tooLong) { _ = try TextChunker.chunks(String(repeating: "a", count: 50_001)) }
            }
            try await run("Unicode and whitespace preserved within chunk budget") {
                let input = String(repeating: "Hello, world! 你好世界。 👩🏽‍💻 Café.\n\n", count: 200)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let chunks = try TextChunker.chunks(input)
                try expect(chunks.count > 1 && chunks.joined() == input, "Text changed")
                try expect(chunks.allSatisfy { $0.utf8.count <= 600 }, "Oversized chunk")
            }
            try await run("Unbroken text makes progress") {
                let input = String(repeating: "x", count: 5_000)
                try expect(try TextChunker.chunks(input).joined() == input, "Text changed")
            }
            try await run("Short targets finish sentences without changing wording") {
                let first = "At 3:45 p.m., Dr. Chen measured 2.5 meters and studied the illustrative axonometric drawing, the translucent facade, and the long cantilever above the courtyard. "
                let second = "The next sentence starts here."
                let chunks = try TextChunker.chunks(first + second, preferredBytes: 80)
                try expect(chunks.first == first, "Split inside a sentence, abbreviation or decimal")
                try expect(chunks.joined() == first + second, "Selected wording changed")
                let long = String(repeating: "daylight ", count: 200) + ". Next sentence."
                let bounded = try TextChunker.chunks(long, preferredBytes: 80)
                try expect(bounded.joined() == long && bounded.allSatisfy { $0.utf8.count <= 600 }, "Long sentence escaped hard budget")
                let whitespace = "Hello." + String(repeating: " ", count: 900) + "Goodbye."
                try expect(try TextChunker.chunks(whitespace).joined() == whitespace, "Internal whitespace lost")
            }
            try await run("Bundled voice catalog is complete and internally consistent") {
                let catalog = VoiceCatalog.bundled
                let names = catalog.voices.map(\.name)
                let expected = Set([
                    "Heart (Kokoro)", "Bella (Kokoro)", "Michael (Kokoro)", "Emma (Kokoro)",
                    "Warm Male (VoxCPM)", "Warm Female (VoxCPM)",
                    "Warm Male (Fish)", "Warm Female (Fish)",
                    "Casual Male (Voxtral)", "Casual Female (Voxtral)",
                    "Fish", "Ryan", "Aiden", "Vivian", "Serena"
                ])
                try expect(names.count == expected.count && Set(names) == expected, "Catalog names changed or duplicated")
                try expect(Set(catalog.voices.map(\.engine)).isSubset(of: Set(["qwen", "fish", "kokoro", "voxcpm", "voxtral"])), "Unknown engine")
                try expect(catalog.voices.allSatisfy {
                    !$0.name.isEmpty && !$0.modelName.isEmpty && !$0.detail.isEmpty && !$0.files.isEmpty &&
                    (32...600).contains($0.preferredBytes)
                }, "Catalog has an incomplete record")
                try expect(Set(catalog.voices.filter(\.original).map(\.name)) == ["Ryan", "Aiden", "Vivian", "Serena"], "Original voice set changed")
                try expect(LocalSpeechProvider.voices == names, "Provider is not catalog ordered")
                try expect(LocalSpeechProvider.preferredBytes(for: "Heart (Kokoro)") == 600 &&
                    LocalSpeechProvider.preferredBytes(for: "Warm Male (VoxCPM)") == 360 &&
                    LocalSpeechProvider.preferredBytes(for: "Warm Female (VoxCPM)") == 360 &&
                    LocalSpeechProvider.preferredBytes(for: "Warm Male (Fish)") == 160, "Catalog chunk targets ignored")
                try expect(catalog.voice(named: "Casual Male (Voxtral)")?.pythonRelativePath == ".local-runtime/voxtral/bin/python" &&
                    catalog.voice(named: "Casual Female (Voxtral)")?.pythonRelativePath == ".local-runtime/voxtral/bin/python",
                    "Voxtral is not isolated from the baseline Python runtime")
                try expect(catalog.voices.filter { $0.engine != "voxtral" }.allSatisfy { $0.pythonRelativePath == nil },
                    "A baseline voice unexpectedly uses a separate Python runtime")
            }
            try await run("Missing local runtime fails without network fallback") {
                let provider = LocalSpeechProvider(runtime: nil)
                try expectError(.runtimeMissing) { _ = try provider.stream(text: "Hello", voice: "Ryan") }
                try expectError(.emptyText) { _ = try provider.stream(text: "  ", voice: "Ryan") }
                try expectError(.invalidResponse) { _ = try provider.stream(text: "Hello", voice: "unknown") }
            }
            try await run("Clipboard restoration preserves all representations") {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let item = NSPasteboardItem()
                let binaryType = NSPasteboard.PasteboardType("com.clearspeak.checks.binary")
                item.setString("original", forType: .string)
                item.setData(Data([1, 2, 3]), forType: binaryType)
                board.writeObjects([item])
                let snapshot = try ClipboardSnapshot(board)
                board.clearContents(); board.setString("copied selection", forType: .string)
                try expect(snapshot.restore(board, ifUnchanged: board.changeCount), "Restore failed")
                try expect(board.string(forType: .string) == "original", "String lost")
                try expect(board.data(forType: binaryType) == Data([1, 2, 3]), "Binary representation lost")
            }
            try await run("Clipboard restoration preserves a newer copy") {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                board.setString("original", forType: .string)
                let snapshot = try ClipboardSnapshot(board)
                board.clearContents(); board.setString("selection", forType: .string)
                let count = board.changeCount
                board.clearContents(); board.setString("new user copy", forType: .string)
                try expect(!snapshot.restore(board, ifUnchanged: count), "Overwrote new copy")
                try expect(board.string(forType: .string) == "new user copy", "Copy lost")
            }
            try await run("Stop rejects late local generation") {
                let controller = PlaybackController(provider: DelayedProvider())
                var errorOccurred = false
                controller.onError = { _ in errorOccurred = true }
                try controller.read("test", voice: "Ryan")
                try await Task.sleep(nanoseconds: 30_000_000)
                controller.stop()
                try await Task.sleep(nanoseconds: 400_000_000)
                try expect(!controller.isActive && controller.status == "Ready", "Stale playback")
                try expect(!errorOccurred, "Cancellation surfaced an error")
            }
            try await run("Rate-aware buffering, underrun recovery, user pause and short drain") {
                let variable = VariableThroughputProvider([[
                    TimedPacket(delay: 0, seconds: 0.05),
                    TimedPacket(delay: 50_000_000, seconds: 0.22),
                    TimedPacket(delay: 350_000_000, seconds: 0.05),
                    TimedPacket(delay: 50_000_000, seconds: 0.22)
                ]])
                let controller = PlaybackController(provider: variable, bufferWallSeconds: 0.2)
                controller.rate = 1.25
                try controller.read("Variable throughput fixture.", voice: "Ryan")
                try await waitUntil("first buffered packet") { controller.sourceChunkCount >= 1 }
                try expect(controller.isBuffering && controller.automaticStartCount == 0,
                           "Playback started on a tiny first packet")
                try await waitUntil("initial buffered start") { controller.automaticStartCount == 1 }
                try expect(!controller.isBuffering && controller.bufferedSourceSeconds >= 0.2,
                           "Playback did not start with adequate headroom")
                try await waitUntil("true underrun", timeout: 1) { controller.underrunCount == 1 }
                try expect(controller.isBuffering, "True underrun did not re-enter buffering")
                try await waitUntil("rebuffered start") { controller.automaticStartCount == 2 }
                try await waitUntil("variable stream drain") { !controller.isActive }
                try expect(controller.status == "Finished" && controller.sourceChunkCount == 4 && controller.underrunCount == 1,
                           "Variable stream did not recover and drain")

                let pausing = VariableThroughputProvider([[
                    TimedPacket(delay: 0, seconds: 0.3),
                    TimedPacket(delay: 2_000_000_000, seconds: 0.1)
                ]])
                let paused = PlaybackController(provider: pausing, bufferWallSeconds: 0.2)
                try paused.read("User pause fixture.", voice: "Ryan")
                try await waitUntil("pause fixture start") { paused.automaticStartCount == 1 }
                paused.togglePause()
                try await Task.sleep(nanoseconds: 350_000_000)
                try expect(paused.isPaused && paused.underrunCount == 0, "User pause counted as an underrun")
                paused.togglePause()
                try await waitUntil("post-pause underrun", timeout: 3) { paused.underrunCount == 1 }
                try await waitUntil("pause fixture drain") { !paused.isActive }

                let short = PlaybackController(provider: ImmediateProvider())
                try short.read("Short final fixture.", voice: "Ryan")
                try await waitUntil("short passage drain") { !short.isActive }
                try expect(short.status == "Finished" && short.automaticStartCount == 1 && short.underrunCount == 0,
                           "Finished passage below reserve did not drain")
            }
            try await run("Stop and replacement clear buffered and stale generation") {
                let stoppedProvider = VariableThroughputProvider([[
                    TimedPacket(delay: 0, seconds: 0.05),
                    TimedPacket(delay: 400_000_000, seconds: 0.3)
                ]])
                let stopped = PlaybackController(provider: stoppedProvider, bufferWallSeconds: 0.2)
                try stopped.read("Stop while buffering fixture.", voice: "Ryan")
                try await waitUntil("stop fixture packet") { stopped.sourceChunkCount == 1 }
                stopped.stop()
                try await Task.sleep(nanoseconds: 500_000_000)
                try expect(stopped.status == "Ready" && !stopped.isActive && !stopped.isBuffering &&
                    stopped.sourceChunkCount == 0 && stopped.automaticStartCount == 0 && stopped.underrunCount == 0,
                    "Stop left buffered or stale state")

                let replacementProvider = VariableThroughputProvider([
                    [TimedPacket(delay: 0, seconds: 0.05), TimedPacket(delay: 400_000_000, seconds: 0.3)],
                    [TimedPacket(delay: 0, seconds: 0.05)]
                ])
                let replacement = PlaybackController(provider: replacementProvider, bufferWallSeconds: 0.2)
                try replacement.read("Old buffered fixture.", voice: "Ryan")
                try await waitUntil("replacement old packet") { replacement.sourceChunkCount == 1 }
                try replacement.read("Replacement fixture.", voice: "Ryan")
                try await waitUntil("replacement drain") { !replacement.isActive }
                try await Task.sleep(nanoseconds: 450_000_000)
                try expect(replacement.status == "Finished" && replacement.sourceChunkCount == 1 &&
                    replacement.automaticStartCount == 1 && replacement.underrunCount == 0,
                    "Replaced generation resumed or polluted diagnostics")
            }
            try await run("Pause, resume, rate and drain streaming PCM") {
                let controller = PlaybackController(provider: ImmediateProvider())
                var errorOccurred = false
                controller.onError = { _ in errorOccurred = true }
                try controller.read("test", voice: "Ryan")
                controller.togglePause()
                try await Task.sleep(nanoseconds: 150_000_000)
                try expect(controller.isPaused && controller.isActive, "Not paused")
                controller.rate = 1.5; controller.togglePause()
                for _ in 0..<60 {
                    if !controller.isActive { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try expect(!errorOccurred && controller.status == "Finished", "Playback didn't finish")
            }
            try await run("Reject malformed PCM") {
                let controller = PlaybackController(provider: InvalidProvider())
                var rejected = false
                controller.onError = { rejected = ($0 as? SpeechError) == .invalidAudio }
                try controller.read("test", voice: "Ryan")
                try await Task.sleep(nanoseconds: 100_000_000)
                try expect(rejected && !controller.isActive, "Bad audio was accepted")
            }
            try await run("Private worker framing, model switching, warm reuse and network denial") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let qwen = directory.appendingPathComponent("models/qwen")
                try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
                let script = """
                import sys,json,base64,socket,os
                from pathlib import Path
                # This must be denied by the production provider's process sandbox.
                try:
                    s=socket.socket(); s.bind(('127.0.0.1',0))
                    print(json.dumps({'event':'error'}),flush=True); sys.exit(1)
                except PermissionError: pass
                model=Path(sys.argv[1]).name
                allowed={
                    'qwen': {'Ryan','Aiden','Vivian','Serena'},
                    'kokoro-82m-bf16': {'Heart (Kokoro)','Bella (Kokoro)','Michael (Kokoro)','Emma (Kokoro)'},
                    'voxcpm2-bf16': {'Warm Male (VoxCPM)','Warm Female (VoxCPM)'},
                    'fish-s2-pro-8bit': {'Fish','Warm Male (Fish)','Warm Female (Fish)'},
                    'voxtral-4b-4bit': {'Casual Male (Voxtral)','Casual Female (Voxtral)'},
                }
                with (Path(__file__).parent/'starts.log').open('a') as f:
                    runtime=os.environ.get('CLEARSPEAK_TEST_PYTHON',sys.executable)
                    f.write(str(os.getpid())+' '+model+' '+runtime+'\\n')
                print(json.dumps({'event':'ready'}),flush=True)
                for line in sys.stdin:
                    r=json.loads(line)
                    if r['voice'] not in allowed.get(model,set()): sys.exit(1)
                    print(json.dumps({'event':'audio','id':r['id'],'sample_rate':24000,'pcm':base64.b64encode(bytes(960)).decode()}),flush=True)
                    print(json.dumps({'event':'done','id':r['id']}),flush=True)
                """
                let worker = directory.appendingPathComponent("worker.py")
                try script.write(to: worker, atomically: true, encoding: .utf8)
                let runtime = LocalRuntime(python: "/usr/bin/python3", worker: worker.path, model: qwen.path)
                let provider = LocalSpeechProvider(runtime: runtime)
                defer { provider.cancel() }

                func install(_ voice: String, omitting: Set<String> = []) throws {
                    guard let entry = VoiceCatalog.bundled.voice(named: voice) else { throw CheckFailed("Missing catalog fixture") }
                    let base = URL(fileURLWithPath: runtime.modelPath(voice: voice))
                    for file in entry.files where !omitting.contains(file) {
                        let url = base.appendingPathComponent(file).standardizedFileURL
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data().write(to: url)
                    }
                }

                try expect(Set(provider.availableVoices) == ["Ryan", "Aiden", "Vivian", "Serena"], "Original voices were hidden without a model")
                try expect(!provider.isInstalled(voice: "Ryan"), "Missing original model appeared installed")
                try install("Ryan")
                try install("Fish", omitting: ["codec.safetensors"])
                try expect(!provider.availableVoices.contains("Fish"), "Partial model appeared installed")
                try expectError(.runtimeMissing) { _ = try provider.stream(text: "Harmless test", voice: "Fish") }
                try install("Fish")
                try expect(provider.availableVoices.contains("Fish"), "Complete model unavailable")
                try expect(!provider.availableVoices.contains("Warm Male (Fish)"), "Missing reference accepted")

                try install("Heart (Kokoro)", omitting: ["voices/af_heart.safetensors"])
                try expect(!provider.availableVoices.contains("Heart (Kokoro)"), "Missing Kokoro voice embedding accepted")
                try install("Heart (Kokoro)")
                try install("Bella (Kokoro)")
                try install("Warm Male (VoxCPM)", omitting: ["model-00002.safetensors"])
                try expect(!provider.availableVoices.contains("Warm Male (VoxCPM)"), "Missing VoxCPM shard accepted")
                try install("Warm Male (VoxCPM)")
                try install("Warm Female (VoxCPM)")
                try install("Warm Male (Fish)")
                try install("Warm Female (Fish)")
                try install("Casual Male (Voxtral)")
                try install("Casual Female (Voxtral)", omitting: ["voice_embedding/casual_female.safetensors"])
                try expect(!provider.availableVoices.contains("Casual Male (Voxtral)"), "Voxtral accepted without its isolated runtime")
                try expectError(.runtimeMissing) { _ = try provider.stream(text: "Harmless test", voice: "Casual Male (Voxtral)") }
                let voxtralPython = URL(fileURLWithPath: runtime.pythonPath(voice: "Casual Male (Voxtral)"))
                try FileManager.default.createDirectory(at: voxtralPython.deletingLastPathComponent(), withIntermediateDirectories: true)
                let wrapper = """
                #!/bin/sh
                export CLEARSPEAK_TEST_PYTHON="$0"
                exec /usr/bin/python3 "$@"
                """
                try wrapper.write(to: voxtralPython, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: voxtralPython.path)
                try expect(provider.availableVoices.contains("Casual Male (Voxtral)"), "Voxtral unavailable with complete model and runtime")
                try expect(!provider.availableVoices.contains("Casual Female (Voxtral)"), "Missing Voxtral embedding accepted")

                let sequence = ["Ryan", "Ryan", "Heart (Kokoro)", "Bella (Kokoro)",
                                "Warm Male (VoxCPM)", "Warm Female (VoxCPM)",
                                "Warm Male (Fish)", "Warm Female (Fish)", "Casual Male (Voxtral)", "Ryan"]
                for voice in sequence {
                    do {
                        var bytes = 0
                        for try await chunk in try provider.stream(text: "Harmless test", voice: voice) { bytes += chunk.samples.count }
                        try expect(bytes == 960, "Worker protocol lost audio")
                    } catch { throw CheckFailed("Worker failed for \(voice): \(error)") }
                }
                let starts = try String(contentsOf: directory.appendingPathComponent("starts.log"), encoding: .utf8)
                    .split(separator: "\n")
                try expect(starts.count == 6, "Same model reloaded, or different model reused")
                try expect(Set(starts.compactMap { $0.split(separator: " ").first }).count == 6, "Model switch reused old process")
                guard let voxtralStart = starts.first(where: { $0.contains("voxtral-4b-4bit") }) else {
                    throw CheckFailed("Voxtral worker did not start")
                }
                try expect(voxtralStart.contains(".local-runtime/voxtral/bin/python"), "Voxtral used the baseline Python runtime")
            }
            print("\(passed) offline checks passed. No cloud API requests.")
        } catch {
            print("FAIL after \(passed) checks: \(error)"); exit(1)
        }
    }

    @MainActor private static func runLiveContinuity() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = LocalRuntime(
            python: root.appendingPathComponent(".venv/bin/python").path,
            worker: root.appendingPathComponent("engine/worker.py").path,
            model: root.appendingPathComponent("models/qwen3-tts-1.7b-bf16").path
        )
        let voice = "Warm Female (VoxCPM)"
        let provider = LocalSpeechProvider(runtime: runtime)
        defer { provider.cancel() }
        try expect(provider.isInstalled(voice: voice), "Live VoxCPM model or reference is missing")
        let fixedSentence = "ClearSpeak keeps this fixed local passage steady while the listener reviews drawings, notes, and ordinary project details at a comfortable pace."
        let passage = Array(repeating: fixedSentence, count: 8).joined(separator: " ")
        let textChunks = try TextChunker.chunks(passage, preferredBytes: LocalSpeechProvider.preferredBytes(for: voice))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        try expect(passage.utf8.count >= 900 && textChunks.count >= 3, "Continuity fixture is not long enough")

        let controller = PlaybackController(provider: provider)
        controller.rate = 1.25
        var playbackError: Error?
        controller.onError = { playbackError = $0 }
        try controller.read(passage, voice: voice)
        for _ in 0..<6_000 {
            if !controller.isActive { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let playbackError { throw playbackError }
        print("LIVE continuity text_chunks=\(textChunks.count) source_chunks=\(controller.sourceChunkCount) automatic_starts=\(controller.automaticStartCount) underruns=\(controller.underrunCount)")
        try expect(controller.status == "Finished", "Live VoxCPM continuity playback did not finish")
        try expect(controller.sourceChunkCount >= textChunks.count, "Live worker omitted a generated chunk")
        try expect(controller.underrunCount == 0, "Live VoxCPM playback underrun")
        print("PASS live Warm Female (VoxCPM) continuity at 1.25×")
    }

    @MainActor private static func runLiveNarrators() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = LocalRuntime(
            python: root.appendingPathComponent(".venv/bin/python").path,
            worker: root.appendingPathComponent("engine/worker.py").path,
            model: root.appendingPathComponent("models/qwen3-tts-1.7b-bf16").path
        )
        let provider = LocalSpeechProvider(runtime: runtime)
        defer { provider.cancel() }
        let controller = PlaybackController(provider: provider)
        var playbackError: Error?
        controller.onError = { playbackError = $0 }

        func readToCompletion(_ voice: String) async throws {
            try expect(provider.isInstalled(voice: voice), "Live model missing for \(voice)")
            playbackError = nil
            try controller.read("ClearSpeak is reading a short, harmless local sample in a calm and steady voice.", voice: voice)
            for _ in 0..<2_400 {
                if !controller.isActive { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let playbackError { throw playbackError }
            try expect(controller.status == "Finished", "Live playback did not finish for \(voice)")
            print("PASS live local reading: \(voice)")
        }

        for voice in ["Heart (Kokoro)", "Warm Male (VoxCPM)", "Warm Male (Fish)", "Casual Male (Voxtral)"] {
            try await readToCompletion(voice)
        }

        playbackError = nil
        let passage = String(repeating: "This fixed local passage checks pause, resume, stop, and cancellation. ", count: 20)
        try controller.read(passage, voice: "Heart (Kokoro)")
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.togglePause()
        try expect(controller.isActive && controller.isPaused, "Live playback did not pause")
        controller.togglePause()
        try expect(!controller.isPaused, "Live playback did not resume")
        controller.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        try expect(controller.status == "Ready" && !controller.isActive && playbackError == nil, "Live cancellation left stale playback")
        try await readToCompletion("Heart (Kokoro)")
        print("5 live narrator checks passed with the real offline worker.")
    }
}
