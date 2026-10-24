import Foundation

/// One typed question in the Reflex routing schema. Mirrors Laya's
/// `choice` / `score` / `noul` primitives.
///
/// `prefixTokens` and `markers` are precomputed at export time: the head
/// (`<type> question: <instructions>`) plus the option markers are constant, so
/// only the transcript has to be tokenized at runtime.
public struct LayaQuestion: Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable {
        case choice
        case score
        case noul
    }

    public let id: String
    public let type: Kind
    public let qtype: Int
    public let instructions: String
    public let options: [String]
    public let prefixTokens: [Int]
    public let markers: [Int]

    enum CodingKeys: String, CodingKey {
        case id, type, qtype, instructions, options, markers
        case prefixTokens = "prefix_tokens"
    }
}

/// Sequence budgets and the calibrated temperatures from the Laya checkpoint.
struct LayaRuntimeConfig: Sendable, Decodable {
    let maxLen: Int
    let headMaxLen: Int
    let questions: Int
    let options: Int
    let qtypes: [String: Int]
    let temperature: [Double]
    let temperatureByOptions: [String: Double]

    enum CodingKeys: String, CodingKey {
        case questions, options, qtypes, temperature
        case maxLen = "max_len"
        case headMaxLen = "head_max_len"
        case temperatureByOptions = "temperature_by_options"
    }
}

struct LayaSchema: Decodable {
    let questions: [LayaQuestion]
}
