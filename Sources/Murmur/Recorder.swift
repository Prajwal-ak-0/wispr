import Foundation
import Accelerate
@preconcurrency import AVFoundation

// Captures the microphone and emits buffers already converted to the transcriber's format.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let spectrum = SpectrumAnalyzer()
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevels: ((Float, [Float]) -> Void)?

    func start(targetFormat: AVAudioFormat) throws {
        guard !isRunning else { return }
        self.targetFormat = targetFormat

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "Murmur.Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input format"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, inFormat: inFormat)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Log.info("recorder started (input \(Int(inFormat.sampleRate))Hz → \(Int(targetFormat.sampleRate))Hz)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        Log.info("recorder stopped")
    }

    private func handle(_ buffer: AVAudioPCMBuffer, inFormat: AVAudioFormat) {
        guard let converter, let targetFormat else { return }

        if onLevels != nil, let channel = buffer.floatChannelData, buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channel[0], 1, &rms, vDSP_Length(buffer.frameLength))
            let bandCount = Config.barCount / 2 + 1
            let bands = spectrum?.analyze(channel[0], count: Int(buffer.frameLength), bandCount: bandCount) ?? []
            DispatchQueue.main.async { self.onLevels?(rms, bands) }
        }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }

        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0 {
            onBuffer?(out)
        }
    }
}
