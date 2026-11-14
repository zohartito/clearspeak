import Foundation

public struct VoiceCatalog: Codable, Sendable {
    public struct Voice: Codable, Sendable {
        public let name: String
        public let engine: String
        public let directory: String
        public let files: [String]
        public let modelName: String
        public let detail: String
        public let preferredBytes: Int
        public let original: Bool
        public let pythonRelativePath: String?
    }

    public let voices: [Voice]

    public init(from decoder: Decoder) throws {
        voices = try decoder.singleValueContainer().decode([Voice].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(voices)
    }

    public static let bundled: VoiceCatalog = {
        guard let url = Bundle.module.url(forResource: "voices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(VoiceCatalog.self, from: data) else {
            preconditionFailure("ClearSpeak voice catalog is missing or invalid")
        }
        return catalog
    }()

    public func voice(named name: String) -> Voice? {
        voices.first { $0.name == name }
    }
}

public struct LocalRuntime: Codable {
    public let python: String
    public let worker: String
    public let model: String
    public init(python: String, worker: String, model: String) {
        self.python = python; self.worker = worker; self.model = model
    }
    public static func bundled() -> LocalRuntime? {
        guard let url = Bundle.main.url(forResource: "local-runtime", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var isInstalled: Bool {
        isInstalled(voice: "Ryan")
    }
    public func modelPath(voice: String) -> String {
        guard let entry = VoiceCatalog.bundled.voice(named: voice), !entry.directory.isEmpty else { return model }
        return URL(fileURLWithPath: model).deletingLastPathComponent()
            .appendingPathComponent(entry.directory).standardizedFileURL.path
    }
    public func pythonPath(voice: String) -> String {
        guard let path = VoiceCatalog.bundled.voice(named: voice)?.pythonRelativePath else { return python }
        return URL(fileURLWithPath: model).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path).standardizedFileURL.path
    }
    public func isInstalled(voice: String) -> Bool {
        guard let entry = VoiceCatalog.bundled.voice(named: voice) else { return false }
        let path = modelPath(voice: voice)
        return FileManager.default.isExecutableFile(atPath: pythonPath(voice: voice)) &&
        FileManager.default.fileExists(atPath: worker) &&
        entry.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: path)
                .appendingPathComponent(file).standardizedFileURL.path)
        }
    }
}

/// Private child process, with network access denied by a per-process macOS sandbox.
/// The model stays warm between readings; cancel kills the worker to halt GPU work.
@MainActor public final class LocalSpeechProvider: SpeechProvider {
    public static let voices = VoiceCatalog.bundled.voices.map(\.name)
    public static func preferredBytes(for voice: String) -> Int {
        VoiceCatalog.bundled.voice(named: voice)?.preferredBytes ?? 600
    }
    public static func modelName(for voice: String) -> String {
        VoiceCatalog.bundled.voice(named: voice)?.modelName ?? "Local voice"
    }
    public static func detail(for voice: String) -> String {
        VoiceCatalog.bundled.voice(named: voice)?.detail ?? "This local voice is not in the bundled catalog."
    }
    private let runtime: LocalRuntime?
    private var process: Process?
    private var activeModelPath: String?
    private var activePythonPath: String?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<SpeechChunk, Error>.Continuation?
    private var requestID: String?
    private var processID = UUID()
    private var watchdog: Task<Void, Never>?
    public var isInstalled: Bool { runtime?.isInstalled ?? false }
    public func isInstalled(voice: String) -> Bool {
        (runtime?.isInstalled(voice: voice) ?? false) && availableVoices.contains(voice)
    }
    public var availableVoices: [String] {
        let original = Set(VoiceCatalog.bundled.voices.filter(\.original).map(\.name))
        guard let runtime else { return Self.voices.filter(original.contains) }
        return Self.voices.filter { voice in
            original.contains(voice) || runtime.isInstalled(voice: voice)
        }
    }

    public init(runtime: LocalRuntime? = LocalRuntime.bundled()) { self.runtime = runtime }

    public func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechError.emptyText }
        guard text.utf8.count <= 1_400 else { throw SpeechError.tooLong }
        guard Self.voices.contains(voice) else { throw SpeechError.invalidResponse }
        guard availableVoices.contains(voice) else { throw SpeechError.runtimeMissing }
        guard continuation == nil else { throw SpeechError.busy }
        try startWorker(voice: voice)
        let id = UUID().uuidString
        requestID = id
        let stream = AsyncThrowingStream<SpeechChunk, Error> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    Task { @MainActor in
                        guard self?.requestID == id else { return }
                        self?.cancel()
                    }
                }
            }
        }
        armWatchdog()
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "text": text, "voice": voice])
            data.append(10)
            try input?.fileHandleForWriting.write(contentsOf: data)
        } catch { fail(SpeechError.unavailable) }
        return stream
    }

    private func startWorker(voice: String) throws {
        guard let runtime, runtime.isInstalled(voice: voice) else { throw SpeechError.runtimeMissing }
        let modelPath = runtime.modelPath(voice: voice)
        let pythonPath = runtime.pythonPath(voice: voice)
        if process?.isRunning == true, activeModelPath == modelPath, activePythonPath == pythonPath { return }
        // Model switches release the previous process and its GPU allocations.
        cancel()
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        processID = token
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", "(version 1)(allow default)(deny network*)", pythonPath, runtime.worker, modelPath]
        // No API keys or other app credentials are inherited.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                             "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1",
                             "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                             "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.processID == token else { return }
                if data.isEmpty {
                    if self.continuation != nil { self.fail(SpeechError.unavailable) }
                    return
                }
                self.consume(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processID == token else { return }
                self.fail(SpeechError.unavailable)
            }
        }
        process = child; input = stdin; output = stdout
        activeModelPath = modelPath; activePythonPath = pythonPath
        do { try child.run() }
        catch { cancel(); throw SpeechError.unavailable }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8_000_000 else { fail(SpeechError.invalidResponse); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = message["event"] as? String else { fail(SpeechError.invalidResponse); return }
            if event == "ready" { continue }
            if event == "error" { fail(SpeechError.unavailable); return }
            guard let id = message["id"] as? String, id == requestID else { continue }
            switch event {
            case "audio":
                guard message["sample_rate"] as? Int == 24_000,
                      let encoded = message["pcm"] as? String, let samples = Data(base64Encoded: encoded),
                      !samples.isEmpty, samples.count % 4 == 0 else { fail(SpeechError.invalidAudio); return }
                continuation?.yield(SpeechChunk(samples: samples))
                armWatchdog()
            case "done":
                watchdog?.cancel(); watchdog = nil
                let finished = continuation
                continuation = nil; requestID = nil
                finished?.finish()
            default: fail(SpeechError.invalidResponse); return
            }
        }
    }
    private func armWatchdog() {
        watchdog?.cancel()
        let id = requestID
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            guard let self, self.requestID == id else { return }
            self.fail(SpeechError.unavailable)
        }
    }
    private func fail(_ error: Error) {
        let failed = continuation
        continuation = nil
        cancel()
        failed?.finish(throwing: error)
    }
    public func cancel() {
        processID = UUID()
        watchdog?.cancel(); watchdog = nil
        let cancelled = continuation
        continuation = nil; requestID = nil
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let child = process, child.isRunning {
            child.terminate()
            // A stuck native operation must not leave GPU work running indefinitely.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil
        activeModelPath = nil; activePythonPath = nil; buffer.removeAll()
        cancelled?.finish(throwing: CancellationError())
    }
}
