import Foundation
import Accelerate
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation

// Captures the microphone and emits buffers already converted to the transcriber's format.
// Lifecycle calls are serialized by AppController.audioQueue; AVAudioEngine owns the tap callback.
final class MicRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var recoveryFile: AVAudioFile?
    private(set) var recoveryURL: URL?
    private let spectrum = SpectrumAnalyzer()
    private(set) var peakLevel: Float = 0
    private(set) var isRunning = false
    private(set) var isPaused = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevels: ((Float, [Float]) -> Void)?

    func start(targetFormat: AVAudioFormat) throws {
        guard !isRunning else { return }
        self.targetFormat = targetFormat

        let recoveryDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/Dictation Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let recoveryURL = recoveryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
        recoveryFile = try AVAudioFile(forWriting: recoveryURL, settings: targetFormat.settings,
                                       commonFormat: targetFormat.commonFormat, interleaved: targetFormat.isInterleaved)
        self.recoveryURL = recoveryURL
        Log.info("dictation recovery file created: \(recoveryURL.lastPathComponent)")

        // Fresh engine every session. Reusing one instance throws -10868 (format not supported)
        // when the mic's hardware format changes between recordings — e.g. after a call drops
        // the input to 24 kHz — and a start failure on a shared engine leaves a dangling tap.
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        // Force the engine to use the system DEFAULT input device. A fresh engine can otherwise
        // bind to the built-in mic even when AirPods are the chosen input — and macOS keeps the
        // built-in mic silent while a Bluetooth headset is active, so we'd capture pure silence.
        if let deviceID = Self.defaultInputDeviceID(), let unit = input.audioUnit {
            var dev = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("could not set default input device: OSStatus \(status)") }
        }
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            self.engine = nil
            throw NSError(domain: "Murmur.Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input format"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, inFormat: inFormat)
        }
        peakLevel = 0
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            converter = nil
            throw error
        }
        isRunning = true
        isPaused = false
        Log.info("recorder started (input \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch → \(Int(targetFormat.sampleRate))Hz)")
    }

    func pause() {
        guard isRunning, !isPaused, let engine else { return }
        engine.pause()
        isPaused = true
        Log.info("recorder paused")
    }

    func resume() throws {
        guard isRunning, isPaused, let engine else { return }
        try engine.start()
        isPaused = false
        Log.info("recorder resumed")
    }

    func stop() {
        guard let engine else { isRunning = false; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        recoveryFile = nil
        isRunning = false
        isPaused = false
        Log.info(String(format: "recorder stopped (peak mic level %.4f)", peakLevel))
    }

    func discardRecovery() {
        recoveryFile = nil
        guard let url = recoveryURL else { return }
        try? FileManager.default.removeItem(at: url)
        recoveryURL = nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer, inFormat: AVAudioFormat) {
        guard let converter, let targetFormat else { return }

        if let channel = buffer.floatChannelData, buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channel[0], 1, &rms, vDSP_Length(buffer.frameLength))
            if rms > peakLevel { peakLevel = rms }
            if onLevels != nil {
                let bandCount = Config.barCount / 2 + 1
                let bands = spectrum?.analyze(channel[0], count: Int(buffer.frameLength), bandCount: bandCount) ?? []
                DispatchQueue.main.async { self.onLevels?(rms, bands) }
            }
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
            do { try recoveryFile?.write(from: out) }
            catch { Log.error("dictation recovery write failed: \(error.localizedDescription)") }
            onBuffer?(out)
        }
    }
}
