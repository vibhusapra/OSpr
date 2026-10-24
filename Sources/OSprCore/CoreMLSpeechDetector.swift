import Foundation
import CoreML

/// Serial, explicitly reset Silero-compatible recurrent inference. Call off the
/// audio callback and main actor. OSpr uses supplied compiled assets with no
/// application-managed model download or conversion step.
public final class CoreMLSpeechDetector {
    public let chunkSamples: Int
    private let model: MLModel
    private let audio: MLMultiArray
    private let hidden: MLMultiArray
    private let cell: MLMultiArray
    private let input: MLDictionaryFeatureProvider
    private var context = [Float](repeating: 0, count: 64)
    private var failed = false
    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let config = MLModelConfiguration(); config.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: config)
        let description = model.modelDescription
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        guard Set(inputs.keys) == ["audio_input", "hidden_state", "cell_state"],
              Set(outputs.keys) == ["vad_output", "new_hidden_state", "new_cell_state"],
              let shape = inputs["audio_input"]?.multiArrayConstraint?.shape.map(\.intValue),
              shape.count == 2, shape[0] == 1, [576, 4160].contains(shape[1]) else {
            throw OSprError.message("Unsupported speech detector input/output contract.")
        }
        chunkSamples = shape[1] - 64
        for (name, expected) in [("audio_input", shape), ("hidden_state", [1, 128]), ("cell_state", [1, 128])] {
            guard inputs[name]?.multiArrayConstraint?.dataType == .float32,
                  inputs[name]?.multiArrayConstraint?.shape.map(\.intValue) == expected else {
                throw OSprError.message("Unsupported speech detector input shape or precision.")
            }
        }
        for (name, expected) in [("vad_output", [1, 1, 1]), ("new_hidden_state", [1, 128]), ("new_cell_state", [1, 128])] {
            guard outputs[name]?.multiArrayConstraint?.dataType == .float32,
                  outputs[name]?.multiArrayConstraint?.shape.map(\.intValue) == expected else {
                throw OSprError.message("Unsupported speech detector output shape or precision.")
            }
        }
        audio = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        input = try MLDictionaryFeatureProvider(dictionary: ["audio_input": audio, "hidden_state": hidden, "cell_state": cell])
        reset()
    }
    public func reset() {
        failed = false
        context = [Float](repeating: 0, count: 64)
        for array in [audio, hidden, cell] {
            array.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: array.count)
        }
    }
    /// Evaluate an incomplete live tail without committing recurrent/context
    /// state. The next complete frame still starts at the original frontier.
    /// Like predict, this must run on the detector's single owning queue.
    public func probe(_ samples: ArraySlice<Float>) throws -> Double {
        guard !failed else { throw OSprError.message("Reset the failed speech detector before probing.") }
        let oldContext = context
        let oldHidden = Array(UnsafeBufferPointer(start: hidden.dataPointer.assumingMemoryBound(to: Float.self), count: 128))
        let oldCell = Array(UnsafeBufferPointer(start: cell.dataPointer.assumingMemoryBound(to: Float.self), count: 128))
        do {
            let value = try predict(samples)
            context = oldContext
            oldHidden.withUnsafeBufferPointer { hidden.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: 128) }
            oldCell.withUnsafeBufferPointer { cell.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: 128) }
            return value
        } catch {
            // Prediction failures stay poisoned, even though successful probes
            // restore state. The live owner must disable automatic finishing.
            throw error
        }
    }
    /// Last partial chunk is zero-padded; callers retain its real sample count.
    public func predict(_ samples: ArraySlice<Float>) throws -> Double {
        guard !failed, !samples.isEmpty, samples.count <= chunkSamples, samples.allSatisfy(\.isFinite) else {
            failed = true
            throw OSprError.message("Speech detection requires a finite mono audio chunk.")
        }
        do { return try autoreleasepool {
            let buffer = audio.dataPointer.assumingMemoryBound(to: Float.self)
            buffer.update(repeating: 0, count: audio.count)
            context.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: 64) }
            samples.withUnsafeBufferPointer { buffer.advanced(by: 64).update(from: $0.baseAddress!, count: $0.count) }
            let result = try model.prediction(from: input)
            guard let probability = result.featureValue(for: "vad_output")?.multiArrayValue,
                  let nextHidden = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let nextCell = result.featureValue(for: "new_cell_state")?.multiArrayValue,
                  probability.dataType == .float32, probability.count == 1 else {
                throw OSprError.message("Speech detector returned an invalid probability.")
            }
            let value = probability[0].doubleValue
            guard value.isFinite, (0...1).contains(value) else { throw OSprError.message("Speech detector returned a non-finite probability.") }
            for (source, destination) in [(nextHidden, hidden), (nextCell, cell)] {
                guard source.dataType == .float32, source.shape.map(\.intValue) == [1, 128],
                      source.strides.last?.intValue == 1 else {
                    throw OSprError.message("Speech detector returned an incompatible recurrent state.")
                }
                let values = source.dataPointer.assumingMemoryBound(to: Float.self)
                guard UnsafeBufferPointer(start: values, count: 128).allSatisfy(\.isFinite) else {
                    throw OSprError.message("Speech detector returned a non-finite recurrent state.")
                }
                destination.dataPointer.assumingMemoryBound(to: Float.self).update(from: values, count: 128)
            }
            // Preserve the padded stream context, matching the reference protocol.
            context.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: buffer.advanced(by: audio.count - 64), count: 64)
            }
            return value
        } } catch { failed = true; throw error }
    }
}
