import Foundation
@preconcurrency import AVFoundation
import Speech

struct TimedTranscriptSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

// Lets exactly one of several racing tasks resume a continuation; the rest are no-ops.
private final class ResumeOnce {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// File-based on-device transcription used by the meeting pipeline.
// A fresh SpeechAnalyzer session is created for each recorded audio chunk.
//
// Cross-thread state (feed() runs on the real-time audio thread; finish/cancel/reset run on the
// main actor) is guarded by stateLock. Whoever CLAIMS the analyzer owns its teardown, so a
// finalize and a force-cancel can never run against the same analyzer at the same time.
final class OnDeviceTranscriber: @unchecked Sendable {
    private let stateLock = NSLock()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?

    private var collector: Task<Void, Never>?
    private(set) var analyzerFormat: AVAudioFormat?
    private var assetsInstalled = false

    // Final results stream in continuously and are banked here, so we never depend on the results
    // sequence terminating — with live mic input it reliably does NOT close after finalize.
    private let textLock = NSLock()
    private var collectedText = ""
    private var collectedSegments: [TimedTranscriptSegment] = []
    private var lastFinishedSegments: [TimedTranscriptSegment] = []
    private func appendText(_ s: String) { textLock.lock(); collectedText += s; textLock.unlock() }
    private func appendSegment(_ result: SpeechTranscriber.Result) {
        let value = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let start = result.range.start.seconds
        let end = CMTimeRangeGetEnd(result.range).seconds
        textLock.withLock {
            collectedText += value
            collectedSegments.append(TimedTranscriptSegment(start: start, end: end, text: value))
        }
    }
    private func currentText() -> String { textLock.lock(); defer { textLock.unlock() }; return collectedText }
    private func snapshotSegments() -> [TimedTranscriptSegment] { textLock.withLock { collectedSegments } }
    private func resetText() { textLock.withLock { collectedText = ""; collectedSegments = [] } }

    private func claimAnalyzer() -> SpeechAnalyzer? {
        stateLock.lock(); defer { stateLock.unlock() }
        let claimed = analyzer
        analyzer = nil
        return claimed
    }
    private func currentStream() -> AsyncStream<AnalyzerInput>.Continuation? {
        stateLock.lock(); defer { stateLock.unlock() }
        return inputCont
    }

    private func startSession() async throws -> AVAudioFormat {
        let t = SpeechTranscriber(locale: Locale(identifier: Config.localeID),
                                  transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if !assetsInstalled, let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
        assetsInstalled = true

        let a = SpeechAnalyzer(modules: [t])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "Murmur.Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no compatible audio format"])
        }

        resetText()
        let collectorTask = Task { [weak self] in
            do {
                for try await result in t.results {
                    self?.appendSegment(result)
                }
            } catch { }
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        // Publish state BEFORE start(), so a start() failure is still cleaned up by cancel().
        stateLock.withLock {
            transcriber = t
            analyzer = a
            inputCont = cont
        }
        collector = collectorTask
        analyzerFormat = format

        do {
            try await a.start(inputSequence: stream)
        } catch {
            cancel()
            throw error
        }
        return format
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        currentStream()?.yield(AnalyzerInput(buffer: buffer))
    }

    // Returns in ≤6s no matter what. We bank final results as they arrive and return the banked
    // text — never waiting for the results sequence to close (it doesn't, with live mic). A wedged
    // finalize is abandoned and force-stopped, so finish() can never hang the UI.
    private func finish() async -> String {
        let analyzer = claimAnalyzer()           // exclusive teardown ownership
        let hadCollector = collector != nil
        currentStream()?.finish()
        guard analyzer != nil || hadCollector else { reset(); return "" }

        let box = ResumeOnce()
        let text: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let work = Task {
                if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
                try? await Task.sleep(nanoseconds: 500_000_000)   // grace for trailing finals
                if box.claim() { cont.resume(returning: self.currentText()) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000) // hard deadline
                guard box.claim() else { return }
                work.cancel()
                if let analyzer { Task.detached { await analyzer.cancelAndFinishNow() } }
                cont.resume(returning: self.currentText())
            }
        }
        lastFinishedSegments = snapshotSegments()
        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancel() {
        let analyzer = claimAnalyzer()
        currentStream()?.finish()
        collector?.cancel()
        reset()
        if let analyzer {
            Task.detached { await analyzer.cancelAndFinishNow() }
        }
    }

    private func reset() {
        collector?.cancel()
        stateLock.lock()
        transcriber = nil
        analyzer = nil
        inputCont = nil
        stateLock.unlock()
        collector = nil
        analyzerFormat = nil
        resetText()
    }

    private func transcribe(fileURL: URL) async throws -> String {
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

    func transcribeSegments(fileURL: URL) async throws -> [TimedTranscriptSegment] {
        _ = try await transcribe(fileURL: fileURL)
        return lastFinishedSegments
    }
}
