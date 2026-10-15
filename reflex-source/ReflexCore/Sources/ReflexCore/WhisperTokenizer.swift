import Foundation

/// Whisper multilingual tokenizer, backed by a compact exported resource
/// (`whisper-tokens.bin` + `whisper-tokenizer.json`). Decoding concatenates
/// each id's raw token bytes and UTF-8 decodes, skipping special tokens.
public struct WhisperTokenizer: Sendable {
    public struct Metadata: Sendable, Decodable {
        public let n_vocab: Int
        public let sot: Int
        public let eot: Int
        public let transcribe: Int
        public let translate: Int
        public let no_timestamps: Int
        public let language_token_en: Int
        public let special_ids: [Int]
    }

    public let metadata: Metadata
    private let blob: [UInt8]
    private let offsets: [Int]
    private let lengths: [Int]
    private let special: Set<Int>

    public init() throws {
        guard
            let jsonURL = Bundle.module.url(forResource: "whisper-tokenizer", withExtension: "json"),
            let binURL = Bundle.module.url(forResource: "whisper-tokens", withExtension: "bin")
        else {
            throw WhisperTokenizerError.missingResource
        }
        metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: jsonURL))
        let data = try Data(contentsOf: binURL)
        blob = [UInt8](data)

        var offsets = [Int](repeating: 0, count: metadata.n_vocab)
        var lengths = [Int](repeating: 0, count: metadata.n_vocab)
        var cursor = 0
        for id in 0..<metadata.n_vocab {
            guard cursor + 4 <= blob.count else { throw WhisperTokenizerError.corruptTokenBlob }
            let len = Int(blob[cursor])
                | Int(blob[cursor + 1]) << 8
                | Int(blob[cursor + 2]) << 16
                | Int(blob[cursor + 3]) << 24
            cursor += 4
            offsets[id] = cursor
            lengths[id] = len
            cursor += len
        }
        self.offsets = offsets
        self.lengths = lengths
        self.special = Set(metadata.special_ids)
    }

    /// The deterministic English prefix: SOT, `<|en|>`, `<|transcribe|>`, `<|notimestamps|>`.
    public var englishPrompt: [Int] {
        [metadata.sot, metadata.language_token_en, metadata.transcribe, metadata.no_timestamps]
    }

    public func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(ids.count * 2)
        for id in ids where id >= 0 && id < lengths.count && !special.contains(id) {
            let start = offsets[id]
            bytes.append(contentsOf: blob[start..<(start + lengths[id])])
        }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WhisperTokenizerError: LocalizedError {
    case missingResource
    case corruptTokenBlob

    public var errorDescription: String? {
        switch self {
        case .missingResource: "Whisper tokenizer resources are missing from the bundle."
        case .corruptTokenBlob: "whisper-tokens.bin is malformed."
        }
    }
}
