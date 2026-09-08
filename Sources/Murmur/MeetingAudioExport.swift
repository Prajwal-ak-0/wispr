@preconcurrency import AVFoundation
import Foundation

// Turns a meeting's recorded chunks into one shareable audio file, and slices that file into
// upload-sized pieces for cloud transcription.
//
// The preferred output is .mp3 (small, universally playable) which needs ffmpeg. macOS has no
// built-in MP3 encoder, so when ffmpeg is absent we still produce a mixed .m4a — every consumer
// here (Gemini, QuickLook, the dashboard) accepts both.
enum MeetingAudioExportError: LocalizedError {
    case noAudio
    case mixFailed(String)
    case sliceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return "This meeting has no recorded audio to export"
        case .mixFailed(let detail): return "Could not build the meeting audio file: \(detail)"
        case .sliceFailed(let detail): return "Could not split the meeting audio: \(detail)"
        }
    }
}

struct MeetingAudioSlice {
    let url: URL
    let offset: TimeInterval
    let duration: TimeInterval
}

struct MeetingAudioExporter: Sendable {
    static let fileName = "meeting"

    // Speech only needs a narrow mono band; 16 kHz @ 32 kbps keeps a 30-minute meeting near 7 MB so
    // a whole chunk fits comfortably inside one inline upload.
    private let sampleRate = 16_000
    private let bitrate = "32k"

    static func ffmpegPath() -> String? {
        let configured = UserDefaults.standard.string(forKey: "ffmpegPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var candidates: [String] = []
        if !configured.isEmpty { candidates.append((configured as NSString).expandingTildeInPath) }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ffmpeg").path,
            "/opt/local/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Mixes the microphone and system chunk lists into a single file inside `directory`.
    func export(system: [URL], microphone: [URL], into directory: URL) async throws -> URL {
        let existing = [system, microphone].flatMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw MeetingAudioExportError.noAudio }

        if let ffmpeg = Self.ffmpegPath() {
            do { return try await exportWithFFmpeg(ffmpeg, system: system, microphone: microphone, into: directory) }
            catch {
                Log.error("ffmpeg mp3 export failed, falling back to m4a: \(error.localizedDescription)")
            }
        }
        return try await exportWithAVFoundation(system: system, microphone: microphone, into: directory)
    }

    // Splits an exported file into pieces no longer than `chunkSeconds`, each tagged with its offset
    // in the meeting so timestamps can be stitched back together.
    func slice(_ url: URL, chunkSeconds: TimeInterval, into directory: URL) async throws -> [MeetingAudioSlice] {
        let total = await Self.duration(of: url)
        guard total > chunkSeconds else {
            return [MeetingAudioSlice(url: url, offset: 0, duration: total)]
        }
        var slices: [MeetingAudioSlice] = []
        var offset: TimeInterval = 0
        var index = 0
        while offset < total - 1 {
            let span = min(chunkSeconds, total - offset)
            let piece = try await extract(from: url, start: offset, duration: span,
                                          into: directory, name: "slice-\(String(format: "%03d", index))")
            slices.append(MeetingAudioSlice(url: piece, offset: offset, duration: span))
            offset += span
            index += 1
        }
        return slices
    }

    // Cuts one time range out of an exported file. Used both to slice a meeting for upload and to
    // re-request a range the model skipped.
    func extract(from url: URL, start: TimeInterval, duration: TimeInterval,
                 into directory: URL, name: String) async throws -> URL {
        let piece = directory.appendingPathComponent("\(name).\(url.pathExtension)")
        try? FileManager.default.removeItem(at: piece)
        if let ffmpeg = Self.ffmpegPath() {
            try await Self.run(ffmpeg, ["-v", "error", "-ss", "\(start)", "-t", "\(duration)",
                                        "-i", url.path, "-c", "copy", piece.path, "-y"])
        } else {
            try await exportSegment(from: url, start: start, duration: duration, to: piece)
        }
        guard FileManager.default.fileExists(atPath: piece.path) else {
            throw MeetingAudioExportError.sliceFailed("no output produced for \(name)")
        }
        return piece
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        default: return "audio/mpeg"
        }
    }

    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - ffmpeg path

    private func exportWithFFmpeg(_ ffmpeg: String, system: [URL], microphone: [URL],
                                  into directory: URL) async throws -> URL {
        let output = directory.appendingPathComponent("\(Self.fileName).mp3")
        try? FileManager.default.removeItem(at: output)

        let micList = try concatList(microphone, named: "mic", in: directory)
        let systemList = try concatList(system, named: "system", in: directory)
        defer { for list in [micList, systemList].compactMap({ $0 }) { try? FileManager.default.removeItem(at: list) } }

        var arguments = ["-v", "error"]
        var filters: [String] = []
        var inputs = 0
        for list in [micList, systemList].compactMap({ $0 }) {
            arguments += ["-f", "concat", "-safe", "0", "-i", list.path]
            filters.append("[\(inputs):a]aresample=\(sampleRate)[a\(inputs)]")
            inputs += 1
        }
        guard inputs > 0 else { throw MeetingAudioExportError.noAudio }

        let labels = (0..<inputs).map { "[a\($0)]" }.joined()
        let mix = inputs > 1
            ? "\(labels)amix=inputs=\(inputs):duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[out]"
            : "[a0]alimiter=limit=0.95[out]"
        arguments += ["-filter_complex", (filters + [mix]).joined(separator: ";"),
                      "-map", "[out]", "-ac", "1", "-ar", "\(sampleRate)", "-b:a", bitrate,
                      "-c:a", "libmp3lame", output.path, "-y"]

        try await Self.run(ffmpeg, arguments)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MeetingAudioExportError.mixFailed("ffmpeg produced no output file")
        }
        return output
    }

    private func concatList(_ urls: [URL], named: String, in directory: URL) throws -> URL? {
        let usable = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !usable.isEmpty else { return nil }
        let list = directory.appendingPathComponent("\(named)-concat.txt")
        // ffmpeg's concat demuxer treats a single quote as a delimiter; escape it the documented way.
        let body = usable.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try Data(body.utf8).write(to: list, options: .atomic)
        return list
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            process.terminationHandler = { process in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 { continuation.resume() }
                else {
                    continuation.resume(throwing: MeetingAudioExportError.mixFailed(
                        message.isEmpty ? "exit status \(process.terminationStatus)" : message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - AVFoundation fallback (no ffmpeg installed)

    private func exportWithAVFoundation(system: [URL], microphone: [URL],
                                        into directory: URL) async throws -> URL {
        let composition = AVMutableComposition()
        for group in [microphone, system] where !group.isEmpty {
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = CMTime.zero
            for url in group where FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
            }
        }
        guard composition.tracks.contains(where: { $0.mediaType == .audio }) else {
            throw MeetingAudioExportError.noAudio
        }
        let output = directory.appendingPathComponent("\(Self.fileName).m4a")
        try? FileManager.default.removeItem(at: output)
        try await export(composition, to: output, timeRange: nil)
        return output
    }

    private func exportSegment(from url: URL, start: TimeInterval,
                               duration: TimeInterval, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: duration, preferredTimescale: 600))
        try await export(asset, to: output, timeRange: range)
    }

    private func export(_ asset: AVAsset, to output: URL, timeRange: CMTimeRange?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingAudioExportError.mixFailed("no usable audio export preset")
        }
        session.outputURL = output
        session.outputFileType = .m4a
        if let timeRange { session.timeRange = timeRange }
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            throw MeetingAudioExportError.mixFailed(error.localizedDescription)
        }
    }
}

// Where the device owner actually speaks, measured from the microphone track rather than inferred.
//
// This exists because asking the model to pick the owner's voice out of the mix fails badly when
// the owner is quiet: on a meeting where the microphone was near-silent for the first fourteen
// minutes, it confidently attributed the host's lines to "you". Measured silence is the honest
// answer, and it is cheap to compute.
struct MeetingVoiceActivity {
    let intervals: [ClosedRange<TimeInterval>]
    let activeRatio: Double

    var isUsable: Bool { activeRatio >= 0.02 && !intervals.isEmpty }

    // A compact "12–19s, 44–51s" rendering, capped so a chatty track cannot flood the prompt.
    func summary(limit: Int = 40) -> String {
        intervals.prefix(limit)
            .map { "\(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded()))s" }
            .joined(separator: ", ")
    }

    static func measure(_ url: URL, thresholdDB: Double = -42, window: TimeInterval = 0.5) -> MeetingVoiceActivity {
        guard let file = try? AVAudioFile(forReading: url) else {
            return MeetingVoiceActivity(intervals: [], activeRatio: 0)
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return MeetingVoiceActivity(intervals: [], activeRatio: 0) }

        let frames = AVAudioFrameCount(max(1, window * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return MeetingVoiceActivity(intervals: [], activeRatio: 0)
        }
        let floor = pow(10, thresholdDB / 20)
        var loud: [Int] = []
        var index = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: frames)) != nil, buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            var sum: Float = 0
            let count = Int(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<count { sum += samples[frame] * samples[frame] }
            }
            let rms = sqrt(sum / Float(count * Int(format.channelCount)))
            if Double(rms) > floor { loud.append(index) }
            index += 1
        }
        guard index > 0 else { return MeetingVoiceActivity(intervals: [], activeRatio: 0) }

        // Merge adjacent loud windows, tolerating a single quiet one so a breath does not split a
        // sentence into two intervals.
        var intervals: [ClosedRange<TimeInterval>] = []
        var start: Int?
        var previous: Int?
        for windowIndex in loud {
            if start == nil { start = windowIndex }
            else if let last = previous, windowIndex - last > 2 {
                intervals.append(Double(start!) * window...Double(last + 1) * window)
                start = windowIndex
            }
            previous = windowIndex
        }
        if let start, let previous {
            intervals.append(Double(start) * window...Double(previous + 1) * window)
        }
        return MeetingVoiceActivity(intervals: intervals,
                                    activeRatio: Double(loud.count) / Double(index))
    }
}
