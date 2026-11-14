import Foundation

public enum SpeechError: Error, LocalizedError, Equatable {
    case emptyText, tooLong, runtimeMissing, unavailable, invalidAudio, invalidResponse, busy
    public var errorDescription: String? {
        switch self {
        case .emptyText: return "No text found. Select some text, or paste it into ClearSpeak."
        case .tooLong: return "Read a smaller section (up to 50 KB) at a time."
        case .runtimeMissing: return "The selected local voice or engine is missing. Follow the setup instructions in the ClearSpeak README, then reopen the app."
        case .unavailable: return "The local speech engine couldn't finish. Try again, or unload the model and retry."
        case .invalidAudio: return "The local audio could not be played. Try reading again."
        case .invalidResponse: return "The local speech engine returned an unexpected response."
        case .busy: return "A reading is already being prepared. Stop it first."
        }
    }
}

public enum TextChunker {
    // Bound generation length while preserving Unicode and selected wording.
    public static func chunks(_ text: String, maxBytes: Int = 600, preferredBytes: Int? = nil) throws -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechError.emptyText }
        guard text.utf8.count <= 50_000 else { throw SpeechError.tooLong }
        guard maxBytes >= 32 else { throw SpeechError.tooLong }
        let target = min(maxBytes, max(32, preferredBytes ?? maxBytes))
        // Apple's sentence tokenizer handles abbreviations, decimals and Unicode.
        // A short target is soft: finish the sentence if it fits the hard limit.
        var sentenceEnds = Set<String.Index>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            sentenceEnds.insert(enclosing.upperBound)
        }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            var boundary: String.Index?
            var sentenceBoundary: String.Index?
            var bytes = 0
            while end < text.endIndex {
                let character = text[end]
                let size = String(character).utf8.count
                guard bytes + size <= maxBytes else { break }
                bytes += size
                end = text.index(after: end)
                if character.isWhitespace { boundary = end }
                if sentenceEnds.contains(end) {
                    sentenceBoundary = end
                    if bytes >= target { break }
                }
            }
            guard end > start else { throw SpeechError.tooLong }
            if end < text.endIndex {
                if let sentenceBoundary, sentenceBoundary > start { end = sentenceBoundary }
                else if let boundary, boundary > start { end = boundary }
            }
            let chunk = String(text[start..<end])
            // Preserve all internal whitespace, including chunk boundaries.
            result.append(chunk)
            start = end
        }
        return result
    }
}

public struct SpeechChunk: Sendable {
    public let samples: Data // Mono, 24 kHz, Float32 little endian.
    public init(samples: Data) { self.samples = samples }
}

@MainActor public protocol SpeechProvider {
    func stream(text: String, voice: String) throws -> AsyncThrowingStream<SpeechChunk, Error>
    func cancel()
}

public extension SpeechProvider {
    func cancel() {}
}
