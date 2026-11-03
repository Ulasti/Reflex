import Foundation

/// Typed music intent extracted from a transcript.
public struct MusicIntent: Sendable, Equatable {
    public enum EntityType: String, Sendable { case artist, album, track, playlist, unknown }
    public enum Operation: String, Sendable { case play, pause, next, previous, search }

    public let entityType: EntityType
    public let query: String
    public let operation: Operation
    public let confidence: Double

    public init(entityType: EntityType, query: String, operation: Operation = .play, confidence: Double = 0) {
        self.entityType = entityType
        self.query = query
        self.operation = operation
        self.confidence = confidence
    }
}

/// A candidate resolved from a music source.
public struct MusicEntity: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let artist: String?
    public let album: String?
    public let source: String
    public var score: Double

    public init(id: String, name: String, artist: String? = nil, album: String? = nil, source: String, score: Double = 0) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.source = source
        self.score = score
    }
}

/// Ranked resolution result.
public enum MusicResolution: Sendable, Equatable {
    case resolved(MusicEntity)
    case ambiguous([MusicEntity])
    case noMatch
}

/// Abstraction over a music data source (local library, account, catalog).
public protocol MusicSourceProvider: Sendable {
    func search(query: String, entityType: MusicIntent.EntityType) async -> [MusicEntity]
}

/// Adapter that actually plays a resolved entity.
public protocol MusicPlaybackAdapter: Sendable {
    func play(_ entity: MusicEntity) async throws -> Bool
}

/// Resolves a spoken music query to a ranked candidate set.
public struct MusicEntityResolver: Sendable {
    public init() {}

    /// Normalize a spoken query: lowercase, trim, collapse whitespace, strip
    /// common filler, and apply alias substitutions.
    public func normalize(_ raw: String) -> String {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse multiple spaces.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        // Common spoken aliases / misrecognitions.
        let aliases: [String: String] = [
            "weekend": "the weeknd",
            "the weekend": "the weeknd",
            "weezer": "weezer"
        ]
        if let a = aliases[t] { t = a }
        return t
    }

    /// Phonetic-ish similarity: lowercase, strip non-alphanumerics, compare.
    public func similarity(_ a: String, _ b: String) -> Double {
        let na = normalizeForCompare(a)
        let nb = normalizeForCompare(b)
        if na == nb { return 1.0 }
        if na.isEmpty || nb.isEmpty { return 0.0 }
        // Levenshtein-based similarity.
        let dist = levenshtein(na, nb)
        let maxLen = max(na.count, nb.count)
        return 1.0 - (Double(dist) / Double(maxLen))
    }

    private func normalizeForCompare(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() {
                let cost = (ca == cb) ? 0 : 1
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost))
            }
            prev = cur
        }
        return prev.last ?? 0
    }

    /// Rank candidates by similarity to the query, returning a resolution.
    public func resolve(query: String, candidates: [MusicEntity], ambiguityThreshold: Double = 0.15) -> MusicResolution {
        let nq = normalize(query)
        guard !candidates.isEmpty else { return .noMatch }
        var scored = candidates
        for i in scored.indices {
            let sim = similarity(nq, scored[i].name)
            let artistSim = scored[i].artist.map { similarity(nq, $0) } ?? 0
            scored[i].score = max(sim, artistSim)
        }
        scored.sort { $0.score > $1.score }
        guard let top = scored.first, top.score >= 0.5 else { return .noMatch }
        // Ambiguity: second candidate within threshold of top.
        if scored.count > 1, let second = scored.dropFirst().first,
           top.score - second.score < ambiguityThreshold {
            return .ambiguous(Array(scored.prefix(3)))
        }
        return .resolved(top)
    }
}

/// In-memory provider for tests and previews.
public struct InMemoryMusicSourceProvider: MusicSourceProvider {
    public let entities: [MusicEntity]
    public init(entities: [MusicEntity]) { self.entities = entities }
    public func search(query: String, entityType: MusicIntent.EntityType) async -> [MusicEntity] {
        entities
    }
}
