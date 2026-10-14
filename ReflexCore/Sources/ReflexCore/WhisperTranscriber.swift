@preconcurrency import CoreML
import Foundation
import os

/// Owns the Whisper CoreML pair (encoder + fixed-window decoder) and runs
/// greedy decoding. `MLModel` is not `Sendable`, so this type is an
/// `@unchecked Sendable` reference type rather than an actor: `MLModel`
/// predictions are documented thread-safe, and model (re)loading is guarded
/// by a lock.
public final class WhisperTranscriber: @unchecked Sendable {
    /// Token window the decoder was exported with. Causal masking makes the
    /// zero-padded tail inert, so one call per step stays correct.
    public static let maxTokens = 128

    private struct LoadedModels: @unchecked Sendable {
        var encoder: MLModel?
        var decoder: MLModel?
        var kind: ReflexModelKind?
        var inFlight: (kind: ReflexModelKind, task: Task<Void, Error>)?
    }

    private let modelDirectory: URL
    private let computeUnits: MLComputeUnits
    private let tokenizer: WhisperTokenizer
    private let state = OSAllocatedUnfairLock(initialState: LoadedModels())

    public init(
        modelDirectory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) throws {
        self.modelDirectory = modelDirectory
        self.computeUnits = computeUnits
        self.tokenizer = try WhisperTokenizer()
    }

    public var promptMetadata: WhisperTokenizer.Metadata { tokenizer.metadata }

    public func unload() {
        state.withLock { $0 = LoadedModels() }
    }

    /// The variant currently resident in memory, if any.
    public var loadedKind: ReflexModelKind? {
        state.withLock { $0.kind }
    }

    /// Compiles and loads `kind` into memory, then runs a silent warm-up pass so
    /// the Neural Engine specializes both graphs. Call at boot or on model
    /// switch to keep the first real `transcribe` off the cold path.
    public func preload(_ kind: ReflexModelKind) async throws {
        try await ensureLoaded(kind)
        await warmUp(kind)
    }

    private func warmUp(_ kind: ReflexModelKind) async {
        let models = state.withLock { $0 }
        guard let encoder = models.encoder, let decoder = models.decoder else { return }
        do {
            let silence = [Float](repeating: 0, count: 16_000)
            let melArray = try makeMelArray(samples: silence, nMel: kind.whisperMelCount)
            let encodedArray = try await encode(
                melArray: melArray,
                encoder: encoder,
                dim: kind.whisperEncoderDim
            )
            var tokens = [Int32](repeating: 0, count: Self.maxTokens)
            for (index, token) in tokenizer.englishPrompt.enumerated() where index < Self.maxTokens {
                tokens[index] = Int32(token)
            }
            let tokenArray = try MLMultiArray(
                shape: [1, NSNumber(value: Self.maxTokens)],
                dataType: .int32
            )
            copy(tokens, into: tokenArray)
            _ = try await decoder.prediction(from: try MLDictionaryFeatureProvider(
                dictionary: [
                    "tokens": MLFeatureValue(multiArray: tokenArray),
                    "encoded_audio": MLFeatureValue(multiArray: encodedArray)
                ]
            ))
        } catch {
            // Warm-up is best-effort; a real transcribe will surface any error.
        }
    }

    public func transcribe(
        samples: [Float],
        modelKind: ReflexModelKind,
        language: String = "en"
    ) async throws -> String {
        try await ensureLoaded(modelKind)

        guard let conditioned = AudioPreflight.condition(samples) else {
            throw WhisperTranscriberError.noSpeech
        }

        let models = state.withLock { $0 }
        guard let encoder = models.encoder,
              let decoder = models.decoder
        else {
            throw WhisperTranscriberError.modelsUnavailable
        }

        let melArray = try makeMelArray(samples: conditioned, nMel: modelKind.whisperMelCount)
        let encodedArray = try await encode(
            melArray: melArray,
            encoder: encoder,
            dim: modelKind.whisperEncoderDim
        )

        let metadata = tokenizer.metadata
        let prompt = language == "en"
            ? tokenizer.englishPrompt
            : [metadata.sot, metadata.language_token_en, metadata.transcribe, metadata.no_timestamps]
        var tokens = [Int32](repeating: 0, count: Self.maxTokens)
        for (index, token) in prompt.enumerated() where index < Self.maxTokens {
            tokens[index] = Int32(token)
        }

        let tokenArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.maxTokens)],
            dataType: .int32
        )

        var generated: [Int] = []
        for step in 0..<(Self.maxTokens - prompt.count) {
            copy(tokens, into: tokenArray)
            let output = try await decoder.prediction(from: try MLDictionaryFeatureProvider(
                dictionary: [
                    "tokens": MLFeatureValue(multiArray: tokenArray),
                    "encoded_audio": MLFeatureValue(multiArray: encodedArray)
                ]
            ))
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw WhisperTranscriberError.unexpectedOutput("logits")
            }
            let next = logits.argmax(indices: [0, prompt.count - 1 + step])
            if next == metadata.eot { break }
            tokens[prompt.count + step] = Int32(next)
            generated.append(next)
        }

        return tokenizer.decode(generated)
    }

    private func ensureLoaded(_ kind: ReflexModelKind) async throws {
        // Coalesce concurrent loads of the same variant so boot preload and an
        // in-flight transcribe can't compile/load the pair twice.
        let task: Task<Void, Error> = state.withLock {
            if $0.kind == kind {
                return Task<Void, Error> {}
            }
            if let inFlight = $0.inFlight, inFlight.kind == kind {
                return inFlight.task
            }
            let task = Task<Void, Error> { [modelDirectory, computeUnits] in
                do {
                    let encoderURL = modelDirectory
                        .appendingPathComponent(kind.whisperBundleName)
                        .appendingPathExtension("mlpackage")
                    let decoderURL = modelDirectory
                        .appendingPathComponent(kind.whisperBundleName + "-decoder")
                        .appendingPathExtension("mlpackage")
                    let encoder = try await CoreMLLoader.load(
                        packageURL: encoderURL, computeUnits: computeUnits
                    )
                    let decoder = try await CoreMLLoader.load(
                        packageURL: decoderURL, computeUnits: computeUnits
                    )
                    self.state.withLock {
                        $0.encoder = encoder
                        $0.decoder = decoder
                        $0.kind = kind
                        $0.inFlight = nil
                    }
                } catch {
                    self.state.withLock { $0.inFlight = nil }
                    throw error
                }
            }
            $0.inFlight = (kind, task)
            return task
        }
        try await task.value
    }

    private func makeMelArray(samples: [Float], nMel: Int) throws -> MLMultiArray {
        let mel = try WhisperMel(nMel: nMel)
        let values = mel.logMel(samples: samples)
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: nMel), NSNumber(value: WhisperMel.chunkFrames)],
            dataType: .float32
        )
        copy(values, into: array)
        return array
    }

    private func encode(
        melArray: MLMultiArray,
        encoder: MLModel,
        dim: Int
    ) async throws -> MLMultiArray {
        let output = try await encoder.prediction(from: try MLDictionaryFeatureProvider(
            dictionary: ["audio_features": MLFeatureValue(multiArray: melArray)]
        ))
        guard let encoded = output.featureValue(for: "encoded_audio")?.multiArrayValue else {
            throw WhisperTranscriberError.unexpectedOutput("encoded_audio")
        }
        let frames = encoded.shape[1].intValue
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: frames), NSNumber(value: dim)],
            dataType: .float32
        )
        copy(encoded.toFloatArray(), into: array)
        return array
    }

    private func copy(_ values: [Float], into array: MLMultiArray) {
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        values.withUnsafeBufferPointer { source in
            pointer.update(from: source.baseAddress!, count: values.count)
        }
    }

    private func copy(_ values: [Int32], into array: MLMultiArray) {
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        values.withUnsafeBufferPointer { source in
            pointer.update(from: source.baseAddress!, count: values.count)
        }
    }
}

public enum WhisperTranscriberError: LocalizedError {
    case modelsUnavailable
    case noSpeech
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .modelsUnavailable: "Whisper encoder/decoder failed to load."
        case .noSpeech: "No audible speech detected in the recording."
        case .unexpectedOutput(let name): "CoreML model did not produce '\(name)'."
        }
    }
}
