import CoreML
import Foundation

/// Stateless CoreML bundle loading. Kept `nonisolated` so actor-confined
/// owners (transcriber, evaluator) can compile and pin their own models
/// without shipping a non-`Sendable` `MLModel` across isolation domains.
enum CoreMLLoader {
    static func load(packageURL: URL, computeUnits: MLComputeUnits) async throws -> MLModel {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ReflexModelError.packageNotFound(packageURL)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiledURL = try await MLModel.compileModel(at: packageURL)
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }
}

extension MLMultiArray {
    /// Row-major `Float` copy of the array, converting from fp16 when needed.
    func toFloatArray() -> [Float] {
        let count = self.count
        var out = [Float](repeating: 0, count: count)
        switch dataType {
        case .float16:
            let src = dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count {
                out[i] = Float(Float16(bitPattern: src[i]))
            }
        case .double:
            let src = dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { out[i] = Float(src[i]) }
        default:
            let src = dataPointer.bindMemory(to: Float.self, capacity: count)
            out.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: src, count: count)
            }
        }
        return out
    }

    /// `count` values from `row` of a 2-D array, honoring the array's strides.
    func floatValues(row: Int, count: Int) -> [Float] {
        let rowStride = strides[0].intValue
        let colStride = strides.count > 1 ? strides[1].intValue : 1
        let base = row * rowStride
        var out = [Float](repeating: 0, count: count)
        switch dataType {
        case .float16:
            let p = dataPointer.bindMemory(to: UInt16.self, capacity: self.count)
            for k in 0..<count { out[k] = Float(Float16(bitPattern: p[base + k * colStride])) }
        case .double:
            let p = dataPointer.bindMemory(to: Double.self, capacity: self.count)
            for k in 0..<count { out[k] = Float(p[base + k * colStride]) }
        default:
            let p = dataPointer.bindMemory(to: Float.self, capacity: self.count)
            for k in 0..<count { out[k] = p[base + k * colStride] }
        }
        return out
    }

    /// Index of the maximum value along the last axis, at the given leading
    /// indices (row-major, honoring the array's strides).
    func argmax(indices: [Int]) -> Int {
        let lastDim = shape.last!.intValue
        let lastStride = strides.last!.intValue
        var base = 0
        for (axis, index) in indices.enumerated() {
            base += index * strides[axis].intValue
        }
        var best = 0
        var bestValue = -Float.greatestFiniteMagnitude
        let count = self.count
        switch dataType {
        case .float16:
            let p = dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for k in 0..<lastDim {
                let value = Float(Float16(bitPattern: p[base + k * lastStride]))
                if value > bestValue { bestValue = value; best = k }
            }
        case .double:
            let p = dataPointer.bindMemory(to: Double.self, capacity: count)
            for k in 0..<lastDim {
                let value = Float(p[base + k * lastStride])
                if value > bestValue { bestValue = value; best = k }
            }
        default:
            let p = dataPointer.bindMemory(to: Float.self, capacity: count)
            for k in 0..<lastDim {
                let value = p[base + k * lastStride]
                if value > bestValue { bestValue = value; best = k }
            }
        }
        return best
    }
}
