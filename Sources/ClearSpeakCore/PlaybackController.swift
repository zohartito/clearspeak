import AVFoundation
import Foundation

@MainActor public final class PlaybackController {
    public private(set) var status = "Ready" { didSet { onChange?() } }
    public private(set) var isActive = false
    public private(set) var isPaused = false
    public private(set) var isBuffering = false
    public private(set) var sourceChunkCount = 0
    public private(set) var underrunCount = 0
    public private(set) var automaticStartCount = 0
    public private(set) var bufferedSourceSeconds: Double = 0
    public var onChange: (() -> Void)?
    public var onError: ((Error) -> Void)?
    public var rate: Float = 1 {
        didSet {
            pitch.rate = effectiveRate
            if isActive && isBuffering && !isPaused { startIfReady(force: generationFinished) }
        }
    }
    private let provider: SpeechProvider
    private let bufferWallSeconds: Double
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var queuedBuffers = 0
    private var generationFinished = false
    private var receivedAudio = false
    private let maximumScheduledSourceSeconds = 30.0
    private let maximumBufferSourceSeconds = 5.0
    private var effectiveRate: Float { min(2, max(0.5, rate)) }
    private var targetSourceSeconds: Double { bufferWallSeconds * Double(effectiveRate) }

    public init(provider: SpeechProvider? = nil, bufferWallSeconds: Double = 4) {
        self.provider = provider ?? LocalSpeechProvider()
        self.bufferWallSeconds = min(10, max(0.05, bufferWallSeconds))
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
    }
    public func read(_ text: String, voice: String) throws {
        let chunks = try TextChunker.chunks(text, preferredBytes: LocalSpeechProvider.preferredBytes(for: voice))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // A completed worker stays warm; an active reading is cancelled before replacement.
        if isActive { stop() }
        let id = UUID()
        generation = id
        generationFinished = false; receivedAudio = false
        bufferedSourceSeconds = 0; queuedBuffers = 0
        sourceChunkCount = 0; underrunCount = 0; automaticStartCount = 0
        isBuffering = true
        isActive = true; isPaused = false
        status = "Preparing local speech…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for text in chunks {
                    try Task.checkCancellation()
                    for try await chunk in try self.provider.stream(text: text, voice: voice) {
                        try Task.checkCancellation()
                        guard self.generation == id else { return }
                        try await self.enqueue(chunk, id: id)
                    }
                }
                guard self.generation == id else { return }
                guard self.receivedAudio else { throw SpeechError.invalidAudio }
                self.generationFinished = true
                self.task = nil
                self.startIfReady(force: true)
                self.finishIfDrained()
            } catch {
                guard self.generation == id else { return }
                self.stop()
                if !(error is CancellationError) {
                    self.status = "Couldn't read text"
                    self.onError?(error)
                }
            }
        }
    }
    private func enqueue(_ chunk: SpeechChunk, id: UUID) async throws {
        guard !chunk.samples.isEmpty, chunk.samples.count % 4 == 0,
              chunk.samples.count <= 4_000_000 else { throw SpeechError.invalidAudio }
        sourceChunkCount += 1
        let bytesPerSecond = 24_000 * 4
        let maximumBytes = Int(maximumBufferSourceSeconds * Double(bytesPerSecond))
        var offset = 0
        while offset < chunk.samples.count {
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            let end = min(chunk.samples.count, offset + maximumBytes)
            let samples = Data(chunk.samples[offset..<end])
            let duration = Double(samples.count / 4) / 24_000
            // Bound scheduled source audio even during a long user pause.
            while queuedBuffers > 0 && bufferedSourceSeconds + duration > maximumScheduledSourceSeconds {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard generation == id else { throw CancellationError() }
            }
            try schedule(samples, duration: duration, id: id)
            offset = end
        }
    }
    private func schedule(_ samples: Data, duration: Double, id: UUID) throws {
        let frames = AVAudioFrameCount(samples.count / 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { throw SpeechError.invalidAudio }
        buffer.frameLength = frames
        samples.withUnsafeBytes { source in
            _ = memcpy(channel, source.baseAddress!, samples.count)
        }
        for index in 0..<Int(frames) where !channel[index].isFinite { throw SpeechError.invalidAudio }
        if !engine.isRunning {
            do { try engine.start() } catch { throw SpeechError.invalidAudio }
        }
        receivedAudio = true
        bufferedSourceSeconds += duration; queuedBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.bufferedSourceSeconds = max(0, self.bufferedSourceSeconds - duration)
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                if self.queuedBuffers == 0 && !self.generationFinished && !self.isPaused && !self.isBuffering {
                    self.underrunCount += 1
                    self.isBuffering = true
                    self.node.stop()
                    self.status = "Buffering local speech…"
                }
                self.finishIfDrained()
            }
        }
        startIfReady()
    }
    private func startIfReady(force: Bool = false) {
        guard isActive, isBuffering, !isPaused, queuedBuffers > 0 else { return }
        guard force || bufferedSourceSeconds >= targetSourceSeconds else {
            status = "Buffering local speech…"
            return
        }
        node.play()
        isBuffering = false
        automaticStartCount += 1
        status = "Reading locally"
    }
    private func finishIfDrained() {
        if generationFinished && queuedBuffers == 0 {
            node.stop(); engine.stop()
            isActive = false; isPaused = false; isBuffering = false
            status = "Finished"
        }
    }
    public func togglePause() {
        guard isActive else { return }
        isPaused.toggle()
        if isPaused { node.pause(); status = "Paused" }
        else {
            if queuedBuffers == 0 {
                if generationFinished { finishIfDrained() }
                else { isBuffering = true; status = receivedAudio ? "Buffering local speech…" : "Preparing local speech…" }
            } else if isBuffering {
                startIfReady(force: generationFinished)
            } else {
                if engine.isRunning { node.play() }
                status = "Reading locally"
            }
        }
    }
    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        provider.cancel()
        node.stop(); engine.stop()
        queuedBuffers = 0; bufferedSourceSeconds = 0
        generationFinished = false; receivedAudio = false
        sourceChunkCount = 0; underrunCount = 0; automaticStartCount = 0
        isActive = false; isPaused = false; isBuffering = false
        status = "Ready"
    }
}
