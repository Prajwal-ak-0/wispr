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
    private var assetsInstalled = false

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
        assetsInstalled = true
    }

    // Begin a new transcription session. Returns the audio format buffers must be fed in.
    func startSession() async throws -> AVAudioFormat {
        let t = SpeechTranscriber(locale: Locale(identifier: Config.localeID),
                                  transcriptionOptions: [],
                                  reportingOptions: [],
                                  attributeOptions: [])
        if !assetsInstalled, let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
        assetsInstalled = true

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

    // Finish the stream, finalize, and return the transcript. Bounded so it can NEVER hang the UI:
    // if finalization stalls (rare — e.g. an unusual input format), it gives up after a timeout
    // and returns what it has (or empty), letting the app return to idle.
    func finish() async -> String {
        let analyzer = self.analyzer
        let collector = self.collector
        inputCont?.finish()
        reset()
        guard analyzer != nil || collector != nil else { return "" }

        let (completed, text) = await withTaskGroup(of: (Bool, String).self) { group -> (Bool, String) in
            group.addTask {
                do {
                    if let analyzer { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                    return (true, (try await collector?.value) ?? "")
                } catch {
                    return (true, "")
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return (false, "")   // timed out
            }
            defer { group.cancelAll() }
            return await group.next() ?? (false, "")
        }
        if !completed, let analyzer {
            // finalize stalled — force the analyzer to release the on-device speech pipeline
            Task.detached { try? await analyzer.cancelAndFinishNow() }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Tear down the current session immediately without waiting — used by the universal reset.
    func cancel() {
        let analyzer = self.analyzer
        inputCont?.finish()
        collector?.cancel()
        reset()
        if let analyzer {
            Task.detached { try? await analyzer.cancelAndFinishNow() }
        }
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
        return await finish()
    }
}
