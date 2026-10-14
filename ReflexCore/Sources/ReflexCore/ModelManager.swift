import Foundation
import CoreML

/// The discrete Reflex model roster. Kept as a pure enum so the rest of the
/// core can reference models without hardcoding bundle paths.
public enum ReflexModelKind: String, CaseIterable, Sendable {
    case whisperBase = "whisper-base"
    case whisperSmall = "whisper-small"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case laya

    public var displayName: String {
        switch self {
        case .whisperBase: "Whisper Base"
        case .whisperSmall: "Whisper Small"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        case .laya: "Laya"
        }
    }
}

/// Owns the full CoreML lifecycle: model lookup, on-disk compilation,
/// Neural Engine pinning, and staged loading/unloading under memory pressure.
public actor ModelManager {
    private var loadedModels: [ReflexModelKind: MLModel] = [:]
    private let computeUnits: MLComputeUnits
    private let modelDirectory: URL

    /// - Parameters:
    ///   - computeUnits: Hardware routing for every model. Defaults to the
    ///     Apple Neural Engine (`.cpuAndNeuralEngine`) per the Phase 1 spec.
    ///   - modelDirectory: Directory containing `.mlpackage` bundles.
    public init(
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        modelDirectory: URL
    ) {
        self.computeUnits = computeUnits
        self.modelDirectory = modelDirectory
    }

    /// Locates and compiles the package for `kind`, then loads it once.
    /// Subsequent calls return the already-pinned instance.
    public func load(_ kind: ReflexModelKind) async throws -> MLModel {
        if let cached = loadedModels[kind] {
            return cached
        }

        let packageURL = modelDirectory
            .appendingPathComponent(kind.bundleName)
            .appendingPathExtension("mlpackage")

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ReflexModelError.packageNotFound(packageURL)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        let compiledURL = try await MLModel.compileModel(at: packageURL)
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)

        loadedModels[kind] = model
        return model
    }

    /// Ensures `kind` is loaded, discarding the handle. Safe to call from
    /// other actors since `MLModel` is not `Sendable`.
    public func ensureLoaded(_ kind: ReflexModelKind) async throws {
        _ = try await load(kind)
    }

    /// Releases the loaded instance so its memory can be reclaimed.
    public func unload(_ kind: ReflexModelKind) {
        loadedModels.removeValue(forKey: kind)
    }

    /// Releases everything. Used by the engine when backgrounding on iOS.
    public func unloadAll() {
        loadedModels.removeAll()
    }

    /// Optional preflight: verifies every package on disk compiles cleanly
    /// without loading it into memory.
    public func verifyCompilation() async throws {
        // Count what actually got verified. A previous version silently
        // `continue`d past missing packages and reported success even when
        // zero models existed, which made `--verify` worthless as evidence.
        var verified = 0
        var missing: [String] = []
        for kind in ReflexModelKind.allCases {
            let packageURL = modelDirectory
                .appendingPathComponent(kind.bundleName)
                .appendingPathExtension("mlpackage")
            guard FileManager.default.fileExists(atPath: packageURL.path) else {
                missing.append(kind.bundleName)
                continue
            }
            _ = try await MLModel.compileModel(at: packageURL)
            verified += 1
        }
        guard verified > 0 else {
            throw ReflexModelError.noPackagesFound(modelDirectory)
        }
        if !missing.isEmpty {
            throw ReflexModelError.somePackagesMissing(
                missing: missing, verified: verified, directory: modelDirectory
            )
        }
    }
}

public enum ReflexModelError: LocalizedError {
    case packageNotFound(URL)
    case noPackagesFound(URL)
    case somePackagesMissing(missing: [String], verified: Int, directory: URL)

    public var errorDescription: String? {
        switch self {
        case .packageNotFound(let url):
            "No .mlpackage found at \(url.path). Run the conversion toolchain (tools/) first."
        case .noPackagesFound(let dir):
            "No model packages found in \(dir.path) — nothing was verified. "
                + "Run the conversion toolchain (see Models/MANIFEST.md)."
        case .somePackagesMissing(let missing, let verified, let dir):
            "Verified \(verified) model package(s) in \(dir.path), but these are missing: "
                + "\(missing.joined(separator: ", ")). "
                + "Run tools/convert.py to rebuild them (see Models/MANIFEST.md)."
        }
    }
}

extension ReflexModelKind {
    var bundleName: String { whisperBundleName }

    var whisperBundleName: String {
        switch self {
        case .whisperBase: "whisper-base"
        case .whisperSmall: "whisper-small"
        case .whisperLargeV3Turbo: "whisper-large-v3-turbo"
        case .laya: "laya"
        }
    }

    var whisperMelCount: Int {
        self == .whisperLargeV3Turbo ? 128 : 80
    }

    var whisperEncoderDim: Int {
        switch self {
        case .whisperBase: 512
        case .whisperSmall: 768
        case .whisperLargeV3Turbo: 1280
        case .laya: 0
        }
    }
}
