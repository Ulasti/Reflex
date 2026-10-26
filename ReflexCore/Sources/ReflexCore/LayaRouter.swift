@preconcurrency import CoreML
import Foundation
import os

/// The routed answers for a single transcript, one per schema question.
public struct LayaRouting: Sendable {
    public let transcript: String
    public let answers: [LayaAnswer]

    public func answer(_ id: String) -> LayaAnswer? {
        answers.first { $0.id == id }
    }
}

public struct LayaAnswer: Sendable {
    public let id: String
    public let type: LayaQuestion.Kind
    public let value: LayaAnswerValue
    public let probabilities: [Double]
    public let confidence: Double
    public let temperature: Double
    public let actProbability: Double
    public let actLogits: [Double]
    public let logits: [Double]
}

public enum LayaAnswerValue: Sendable {
    case choice(label: String, index: Int)
    case score(expected: Double)
    case noul(probability: Double)
}

/// Runs the non-autoregressive Laya router: one forward pass evaluates every
/// typed question in parallel, returning per-option logits plus an act gate.
///
/// `MLModel` is not `Sendable`, so this is an `@unchecked Sendable` reference
/// type with lock-guarded (re)loading, matching `WhisperTranscriber`.
public final class LayaRouter: @unchecked Sendable {
    private struct LoadedModel: @unchecked Sendable {
        var model: MLModel?
        var inFlight: Task<Void, Error>?
    }

    private let modelDirectory: URL
    private let computeUnits: MLComputeUnits
    private let tokenizer: LayaTokenizer
    private let config: LayaRuntimeConfig
    private let state = OSAllocatedUnfairLock(initialState: LoadedModel())

    public let questions: [LayaQuestion]

    public init(
        modelDirectory: URL,
        computeUnits: MLComputeUnits = .cpuAndGPU
    ) throws {
        guard
            let configURL = Bundle.module.url(forResource: "laya-config", withExtension: "json"),
            let schemaURL = Bundle.module.url(forResource: "reflex-questions", withExtension: "json")
        else {
            throw LayaRouterError.missingResource
        }
        self.modelDirectory = modelDirectory
        self.computeUnits = computeUnits
        self.tokenizer = try LayaTokenizer()
        self.config = try JSONDecoder().decode(LayaRuntimeConfig.self, from: Data(contentsOf: configURL))
        self.questions = try JSONDecoder().decode(LayaSchema.self, from: Data(contentsOf: schemaURL)).questions
    }

    /// Compiles and warms the router into memory.
    public func preload() async throws {
        try await ensureLoaded()
        _ = try await route(transcript: "")
    }

    public func unload() {
        state.withLock { $0.model = nil }
    }

    public func route(transcript: String) async throws -> LayaRouting {
        try await ensureLoaded()
        guard let model = state.withLock({ $0.model }) else {
            throw LayaRouterError.modelUnavailable
        }

        let inputs = try buildInputs(transcript: transcript)
        let output = try await model.prediction(from: try MLDictionaryFeatureProvider(dictionary: inputs))
        guard
            let logits = output.featureValue(for: "logits")?.multiArrayValue,
            let actLogits = output.featureValue(for: "act_logits")?.multiArrayValue
        else {
            throw LayaRouterError.unexpectedOutput
        }
        return postProcess(transcript: transcript, logits: logits, actLogits: actLogits)
    }

    // MARK: - Input assembly

    /// The five int32 tensors the Laya graph consumes, in declaration order:
    /// input_ids, attention_mask, marker_pos, marker_mask, qtype.
    public struct InputTensors: Sendable {
        public let rows: Int
        public let maxLen: Int
        public let options: Int
        public let inputIds: [Int32]
        public let attentionMask: [Int32]
        public let markerPos: [Int32]
        public let markerMask: [Int32]
        public let qtype: [Int32]
    }

    /// Diagnostic hook for parity tests: exposes the exact tensors `route`
    /// feeds the model without running it.
    public func inputTensors(transcript: String) -> InputTensors {
        let nQ = config.questions
        let nOpt = config.options
        let maxLen = config.maxLen

        let stateIds = tokenizer.encode(transcript)

        var inputIds = [Int32](repeating: Int32(tokenizer.specials.pad), count: nQ * maxLen)
        var attention = [Int32](repeating: 0, count: nQ * maxLen)
        var markerPos = [Int32](repeating: 0, count: nQ * nOpt)
        var markerMask = [Int32](repeating: 0, count: nQ * nOpt)
        var qtype = [Int32](repeating: 0, count: nQ)

        for (row, question) in questions.enumerated() where row < nQ {
            var sequence = question.prefixTokens
            let room = max(0, maxLen - sequence.count - 1)
            sequence.append(contentsOf: stateIds.prefix(room))
            sequence.append(tokenizer.specials.sep)
            if sequence.count > maxLen {
                sequence.removeLast(sequence.count - maxLen)
            }
            for (offset, id) in sequence.enumerated() {
                inputIds[row * maxLen + offset] = Int32(id)
                attention[row * maxLen + offset] = 1
            }
            for (slot, position) in question.markers.enumerated() where slot < nOpt {
                markerPos[row * nOpt + slot] = Int32(position)
                markerMask[row * nOpt + slot] = 1
            }
            qtype[row] = Int32(question.qtype)
        }

        return InputTensors(
            rows: nQ,
            maxLen: maxLen,
            options: nOpt,
            inputIds: inputIds,
            attentionMask: attention,
            markerPos: markerPos,
            markerMask: markerMask,
            qtype: qtype
        )
    }

    private func buildInputs(transcript: String) throws -> [String: MLFeatureValue] {
        let tensors = inputTensors(transcript: transcript)
        return [
            "input_ids": MLFeatureValue(multiArray: try makeArray(tensors.inputIds, shape: [tensors.rows, tensors.maxLen])),
            "attention_mask": MLFeatureValue(multiArray: try makeArray(tensors.attentionMask, shape: [tensors.rows, tensors.maxLen])),
            "marker_pos": MLFeatureValue(multiArray: try makeArray(tensors.markerPos, shape: [tensors.rows, tensors.options])),
            "marker_mask": MLFeatureValue(multiArray: try makeArray(tensors.markerMask, shape: [tensors.rows, tensors.options])),
            "qtype": MLFeatureValue(multiArray: try makeArray(tensors.qtype, shape: [tensors.rows])),
        ]
    }

    private func makeArray(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .int32)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        values.withUnsafeBufferPointer { source in
            pointer.update(from: source.baseAddress!, count: values.count)
        }
        return array
    }

    // MARK: - Post-processing

    private func postProcess(
        transcript: String,
        logits: MLMultiArray,
        actLogits: MLMultiArray
    ) -> LayaRouting {
        let nOpt = config.options
        let actCount = actLogits.shape.last!.intValue
        var answers: [LayaAnswer] = []

        for (row, question) in questions.enumerated() {
            let k = min(question.markers.count, nOpt)
            guard k > 0 else { continue }

            let raw = logits.floatValues(row: row, count: nOpt).prefix(k).map(Double.init)
            let temperature = config.temperatureByOptions[tempBucket(question.type, k)]
                ?? config.temperature[question.qtype]
            let probabilities = softmax(raw.map { $0 / max(1e-3, temperature) })
            let confidence = normalizedEntropyConfidence(probabilities)

            let value: LayaAnswerValue
            switch question.type {
            case .choice:
                let index = argmax(probabilities)
                value = .choice(label: optionLabel(question.options[index]), index: index)
            case .score:
                let expected = probabilities.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
                value = .score(expected: expected)
            case .noul:
                value = .noul(probability: probabilities.count > 1 ? probabilities[1] : 0)
            }

            let actRaw = actLogits.floatValues(row: row, count: actCount).map(Double.init)
            let act = softmax(actRaw)
            answers.append(
                LayaAnswer(
                    id: question.id,
                    type: question.type,
                    value: value,
                    probabilities: probabilities,
                    confidence: confidence,
                    temperature: temperature,
                    actProbability: act.first ?? 0,
                    actLogits: actRaw,
                    logits: Array(raw)
                )
            )
        }
        return LayaRouting(transcript: transcript, answers: answers)
    }

    private func tempBucket(_ type: LayaQuestion.Kind, _ k: Int) -> String {
        let size: String
        switch k {
        case ...2: size = "2"
        case ...5: size = "3-5"
        case ...10: size = "6-10"
        default: size = "11+"
        }
        return "\(type.rawValue):\(size)"
    }

    private func optionLabel(_ option: String) -> String {
        option.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? option
    }

    private func softmax(_ values: [Double]) -> [Double] {
        guard let maxValue = values.max() else { return [] }
        let exps = values.map { exp($0 - maxValue) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    }

    private func normalizedEntropyConfidence(_ probabilities: [Double]) -> Double {
        guard probabilities.count >= 2 else { return 1 }
        let entropy = -probabilities.reduce(0.0) { $0 + $1 * log(max($1, 1e-12)) }
        return min(1, max(0, 1 - entropy / log(Double(probabilities.count))))
    }

    private func argmax(_ values: [Double]) -> Int {
        var best = 0
        for (index, value) in values.enumerated() where value > values[best] { best = index }
        return best
    }

    // MARK: - Model lifecycle

    private func ensureLoaded() async throws {
        let task: Task<Void, Error> = state.withLock {
            if $0.model != nil { return Task<Void, Error> {} }
            if let inFlight = $0.inFlight { return inFlight }
            let task = Task<Void, Error> { [modelDirectory, computeUnits] in
                do {
                    let url = modelDirectory.appendingPathComponent("laya").appendingPathExtension("mlpackage")
                    let model = try await CoreMLLoader.load(packageURL: url, computeUnits: computeUnits)
                    self.state.withLock {
                        $0.model = model
                        $0.inFlight = nil
                    }
                } catch {
                    self.state.withLock { $0.inFlight = nil }
                    throw error
                }
            }
            $0.inFlight = task
            return task
        }
        try await task.value
    }
}

public enum LayaRouterError: LocalizedError {
    case missingResource
    case modelUnavailable
    case unexpectedOutput

    public var errorDescription: String? {
        switch self {
        case .missingResource: "Laya router resources are missing from the bundle."
        case .modelUnavailable: "Laya model failed to load."
        case .unexpectedOutput: "Laya model did not produce 'logits'/'act_logits'."
        }
    }
}
