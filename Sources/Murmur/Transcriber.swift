import Foundation
@preconcurrency import AVFoundation
import Speech

// Wraps the on-device SpeechAnalyzer/SpeechTranscriber (macOS 26) for live dictation.
// A fresh session is created per recording; assets are installed once.
final class LiveTranscriber {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<String, Error>?

    private(set) var analyzerFormat: AVAudioFormat?

    // Install the language model assets up front so the first recording is instant.
    func prepareAssets() async throws {
        let t = SpeechTranscriber(locale: Locale(identifier: Config.localeID),
                                  transcriptionOptions: [],
                                  reportingOptions: [],
                                  attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            Log.info("downloading speech model assets…")
            try await request.downloadAndInstall()
            Log.info("speech assets installed")
        } else {
            Log.info("speech assets already present")
        }
    }

    // Begin a new transcription session. Returns the audio format buffers must be fed in.
    func startSession() async throws -> AVAudioFormat {
        let t = SpeechTranscriber(locale: Locale(identifier: Config.localeID),
                                  transcriptionOptions: [],
                                  reportingOptions: [],
                                  attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }

        let a = SpeechAnalyzer(modules: [t])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "Murmur.Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no compatible audio format"])
        }

        let collectorTask = Task { () -> String in
            var attributed = AttributedString()
            for try await result in t.results {
                attributed.append(result.text)
            }
            return String(attributed.characters)
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await a.start(inputSequence: stream)

        self.transcriber = t
        self.analyzer = a
        self.inputCont = cont
        self.collector = collectorTask
        self.analyzerFormat = format
        return format
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputCont?.yield(AnalyzerInput(buffer: buffer))
    }

    // Finish the stream, finalize, and return the full transcript.
    func finish() async throws -> String {
        inputCont?.finish()
        if let a = analyzer {
            try await a.finalizeAndFinishThroughEndOfInput()
        }
        let text = (try await collector?.value) ?? ""
        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reset() {
        transcriber = nil
        analyzer = nil
        inputCont = nil
        collector = nil
        analyzerFormat = nil
    }

    // Convenience used by --selftest: transcribe a whole audio file.
    func transcribe(fileURL: URL) async throws -> String {
        let format = try await startSession()
        let file = try AVAudioFile(forReading: fileURL)
        let srcFormat = file.processingFormat
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Murmur.Transcriber", code: 2)
        }
        try file.read(into: srcBuf)

        guard let converter = AVAudioConverter(from: srcFormat, to: format) else {
            throw NSError(domain: "Murmur.Transcriber", code: 3)
        }
        let cap = AVAudioFrameCount(Double(srcBuf.frameLength) * format.sampleRate / srcFormat.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else {
            throw NSError(domain: "Murmur.Transcriber", code: 4)
        }
        var err: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return srcBuf
        }
        if let err { throw err }
        feed(outBuf)
        return try await finish()
    }
}
