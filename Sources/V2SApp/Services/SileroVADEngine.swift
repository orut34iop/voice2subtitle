import AVFoundation
import Foundation
import OnnxRuntimeBindings

// MARK: - VADResult

struct VADResult: Sendable {
    let speechProbability: Float
    let isSpeech: Bool
    let containsSpeechOnset: Bool
    let containsSpeechOffset: Bool
}

// MARK: - SileroVADEngine

/// Runs Silero VAD v5 inference on 16 kHz mono Float32 audio buffers.
///
/// The engine accumulates incoming samples into 512-sample chunks (32 ms at 16 kHz),
/// runs ONNX inference per chunk, and applies onset/offset hysteresis to produce a
/// stable speech/silence signal.
///
/// **Threading**: All methods must be called from the same serial queue (captureQueue).
final class SileroVADEngine {

    // MARK: - Constants

    /// Silero VAD v5 expects 512-sample chunks at 16 kHz.
    private static let chunkSize = 512
    /// The bundled model uses a combined recurrent state [2, 1, 128].
    private static let stateSize = 2 * 1 * 128
    private static let contextSize = 64

    // MARK: - ONNX Runtime objects

    private let env: ORTEnv
    private let session: ORTSession

    // MARK: - Model state

    private var state: [Float]
    /// The model expects 64 preceding samples before each 512-sample window.
    private var context: [Float]
    /// Sample-rate tensor (constant, reusable).
    private let srTensor: ORTValue
    /// Backing data for srTensor (must stay alive).
    private let srData: NSMutableData

    // MARK: - Accumulation buffer

    private var accumulationBuffer: [Float] = []

    // MARK: - Hysteresis state

    private var hysteresis = SileroVADHysteresis(
        speechOnsetThreshold: 0.5,
        speechOffsetThreshold: 0.35,
        minSpeechFrames: 3,
        minSilenceFrames: 8
    )

    var isSpeaking: Bool { hysteresis.isSpeaking }

    // MARK: - Init

    init() throws {
        env = try ORTEnv(loggingLevel: .warning)

        let sessionOptions = try ORTSessionOptions()

        guard let modelURL = Self.resourceBundle.url(forResource: "silero_vad", withExtension: "onnx") else {
            throw SileroVADError.modelNotFound
        }

        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: sessionOptions)

        state = [Float](repeating: 0, count: Self.stateSize)
        context = [Float](repeating: 0, count: Self.contextSize)

        // Pre-build the sample-rate tensor (constant Int64 = 16000).
        var sr: Int64 = 16000
        srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        srTensor = try ORTValue(tensorData: srData, elementType: .int64, shape: [])

        // Loading an ONNX file alone does not validate its inference contract.
        _ = try infer(chunk: [Float](repeating: 0, count: Self.chunkSize))
        reset()
    }

    // MARK: - Public API

    /// Process an audio buffer and return the VAD result.
    ///
    /// Accumulates samples, runs inference on complete 512-sample chunks, and applies
    /// hysteresis. Preserves the speech state when no complete chunk is available.
    /// Inference errors propagate so callers can fall back instead of treating failure as silence.
    func process(buffer: AVAudioPCMBuffer) throws -> VADResult {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return VADResult(speechProbability: 0, isSpeech: isSpeaking,
                             containsSpeechOnset: false, containsSpeechOffset: false)
        }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        accumulationBuffer.append(contentsOf: samples)

        var maxProbability: Float = 0
        var didOnset = false
        var didOffset = false

        while accumulationBuffer.count >= Self.chunkSize {
            let chunk = Array(accumulationBuffer.prefix(Self.chunkSize))
            accumulationBuffer.removeFirst(Self.chunkSize)

            let probability = try infer(chunk: chunk)
            if probability > maxProbability { maxProbability = probability }

            let transition = hysteresis.apply(probability: probability)
            if transition.didOnset { didOnset = true }
            if transition.didOffset { didOffset = true }
        }

        return VADResult(
            speechProbability: maxProbability,
            isSpeech: isSpeaking,
            containsSpeechOnset: didOnset,
            containsSpeechOffset: didOffset
        )
    }

    /// Reset LSTM state and hysteresis. Call when starting a new recognition session.
    func reset() {
        state = [Float](repeating: 0, count: Self.stateSize)
        context = [Float](repeating: 0, count: Self.contextSize)
        accumulationBuffer.removeAll()
        hysteresis.reset()
    }

    // MARK: - Private

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }

    private func infer(chunk: [Float]) throws -> Float {
        // Match the bundled state/stateN model contract (576 input samples at 16 kHz).
        var audioSamples = context + chunk
        let audioData = NSMutableData(
            bytes: &audioSamples,
            length: audioSamples.count * MemoryLayout<Float>.size
        )
        let audioTensor = try ORTValue(
            tensorData: audioData,
            elementType: .float,
            shape: [1, NSNumber(value: audioSamples.count)]
        )
        let stateData = NSMutableData(
            bytes: &state,
            length: state.count * MemoryLayout<Float>.size
        )
        let stateTensor = try ORTValue(
            tensorData: stateData,
            elementType: .float,
            shape: [2, 1, 128]
        )
        let outputs = try session.run(
            withInputs: ["input": audioTensor, "sr": srTensor, "state": stateTensor],
            outputNames: Set(["output", "stateN"]),
            runOptions: try ORTRunOptions()
        )
        guard let outputValue = outputs["output"] else {
            throw SileroVADError.missingOutput("output")
        }
        guard let nextState = outputs["stateN"] else {
            throw SileroVADError.missingOutput("stateN")
        }
        let outputData = try outputValue.tensorData() as Data
        let nextStateData = try nextState.tensorData() as Data
        guard outputData.count == MemoryLayout<Float>.size,
              nextStateData.count == Self.stateSize * MemoryLayout<Float>.size else {
            throw SileroVADError.invalidOutput
        }
        let probability = outputData.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        guard probability.isFinite, (0...1).contains(probability) else {
            throw SileroVADError.invalidOutput
        }
        state = nextStateData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        context = Array(chunk.suffix(Self.contextSize))

        return probability
    }
}

// MARK: - Errors

enum SileroVADError: LocalizedError {
    case modelNotFound
    case missingOutput(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Silero VAD model (silero_vad.onnx) not found in app bundle."
        case .invalidOutput:
            return "Silero VAD inference returned an invalid probability or recurrent state."
        case .missingOutput(let name):
            return "Silero VAD inference missing expected output: \(name)"
        }
    }
}
