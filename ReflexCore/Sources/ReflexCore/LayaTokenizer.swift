import Foundation

/// ByteLevel BPE encoder for the Laya checkpoint (ModernBERT backbone), backed
/// by the exported `laya-tokenizer.json` resource.
///
/// This is the same tokenizer family as Whisper's, but the vocab and merge
/// table differ, so it lives in its own type. Only `encode` is needed: Laya's
/// questions are pre-tokenized at export time and only the transcript state is
/// tokenized at runtime.
public struct LayaTokenizer: Sendable {
    public struct Specials: Sendable, Decodable {
        public let unk: Int
        public let cls: Int
        public let sep: Int
        public let pad: Int
        public let mask: Int
    }

    private struct Resource: Decodable {
        let vocab: [String: Int]
        let merges: [[String]]
        let specials: Specials
        let added_tokens: [AddedToken]
        let byte_level_regex: String
        let add_prefix_space: Bool
    }

    private struct AddedToken: Decodable {
        let id: Int
        let content: String
        let normalized: Bool
        let special: Bool
    }

    public let specials: Specials

    private let vocab: [String: Int]
    private let ranks: [String: Int]
    private let regex: NSRegularExpression
    private let byteToScalar: [Character]
    private let addedByLength: [Int: [String: Int]]
    private let addedLengths: [Int]

    public init() throws {
        guard let url = Bundle.module.url(forResource: "laya-tokenizer", withExtension: "json") else {
            throw LayaTokenizerError.missingResource
        }
        let resource = try JSONDecoder().decode(Resource.self, from: Data(contentsOf: url))
        self.specials = resource.specials
        self.vocab = resource.vocab

        var ranks = [String: Int](minimumCapacity: resource.merges.count)
        for (rank, pair) in resource.merges.enumerated() where pair.count == 2 {
            ranks[pair[0] + " " + pair[1]] = rank
        }
        self.ranks = ranks

        self.regex = try NSRegularExpression(pattern: resource.byte_level_regex)
        self.byteToScalar = LayaTokenizer.makeByteToScalar()

        // HuggingFace splits registered added tokens (notably runs of two or
        // more spaces) out of the raw text before byte-level BPE, longest
        // match first. Reproduce that so transcripts tokenize identically.
        var byLength: [Int: [String: Int]] = [:]
        for token in resource.added_tokens where !token.content.isEmpty {
            byLength[token.content.utf16.count, default: [:]][token.content] = token.id
        }
        self.addedByLength = byLength
        self.addedLengths = byLength.keys.sorted(by: >)
    }

    /// Tokenizes `text` into Laya vocabulary ids. `[MASK]` is stripped the way
    /// `build_sequence` strips it from the state before encoding.
    public func encode(_ text: String, addPrefixSpace: Bool = false) -> [Int] {
        let mask = "[MASK]"
        var prepared = text.replacingOccurrences(of: mask, with: " ")
        if addPrefixSpace, !prepared.hasPrefix(" ") {
            prepared = " " + prepared
        }
        prepared = prepared.precomposedStringWithCanonicalMapping

        var ids = [Int]()
        let ns = prepared as NSString
        var segmentStart = 0
        var cursor = 0
        while cursor < ns.length {
            if let (token, id) = longestAddedToken(in: ns, at: cursor) {
                if cursor > segmentStart {
                    encodeSegment(ns.substring(with: NSRange(location: segmentStart, length: cursor - segmentStart)), into: &ids)
                }
                ids.append(id)
                cursor += (token as NSString).length
                segmentStart = cursor
            } else {
                cursor += 1
            }
        }
        if segmentStart < ns.length {
            encodeSegment(ns.substring(with: NSRange(location: segmentStart, length: ns.length - segmentStart)), into: &ids)
        }
        return ids
    }

    private func longestAddedToken(in text: NSString, at location: Int) -> (String, Int)? {
        for length in addedLengths where location + length <= text.length {
            let candidate = text.substring(with: NSRange(location: location, length: length))
            if let id = addedByLength[length]?[candidate] {
                return (candidate, id)
            }
        }
        return nil
    }

    private func encodeSegment(_ segment: String, into ids: inout [Int]) {
        guard !segment.isEmpty else { return }
        let ns = segment as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cursor = 0
        for match in regex.matches(in: segment, range: full) {
            if match.range.location > cursor {
                append(piece: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), into: &ids)
            }
            append(piece: ns.substring(with: match.range), into: &ids)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            append(piece: ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)), into: &ids)
        }
    }

    private func append(piece: String, into ids: inout [Int]) {
        guard !piece.isEmpty else { return }
        var mapped = String()
        mapped.reserveCapacity(piece.utf8.count)
        for byte in piece.utf8 {
            mapped.append(byteToScalar[Int(byte)])
        }
        for symbol in Self.bpe(mapped, ranks: ranks) {
            ids.append(vocab[symbol] ?? specials.unk)
        }
    }

    private static func bpe(_ token: String, ranks: [String: Int]) -> [String] {
        var symbols = token.map { String($0) }
        guard symbols.count > 1 else { return symbols }

        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for index in 0..<(symbols.count - 1) {
                if let rank = ranks[symbols[index] + " " + symbols[index + 1]], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            symbols.replaceSubrange(
                bestIndex...(bestIndex + 1),
                with: [symbols[bestIndex] + symbols[bestIndex + 1]]
            )
        }
        return symbols
    }

    /// The GPT-2 byte-to-unicode table: printable Latin-1 bytes map to
    /// themselves, every other byte maps into the U+0100+ private range.
    private static func makeByteToScalar() -> [Character] {
        var printable = Set<Int>()
        for range in [33...126, 161...172, 174...255] {
            for value in range { printable.insert(value) }
        }
        var table = [Character](repeating: " ", count: 256)
        var offset = 0
        for byte in 0..<256 {
            if printable.contains(byte) {
                table[byte] = Character(UnicodeScalar(byte)!)
            } else {
                table[byte] = Character(UnicodeScalar(256 + offset)!)
                offset += 1
            }
        }
        return table
    }
}

public enum LayaTokenizerError: LocalizedError {
    case missingResource

    public var errorDescription: String? {
        switch self {
        case .missingResource: "laya-tokenizer.json is missing from the bundle."
        }
    }
}
