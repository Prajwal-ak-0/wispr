import Foundation

enum MeetingStatus: String, Codable {
    case recording, transcribing, ready, failed
}

enum MeetingTimeline {
    static func chunkOffsets(durations: [TimeInterval]) -> [TimeInterval] {
        var elapsed: TimeInterval = 0
        return durations.map { duration in defer { elapsed += max(0, duration) }; return elapsed }
    }
}

enum MeetingSummaryProvider: String, Codable, CaseIterable, Identifiable {
    case codex = "ChatGPT (Codex)"
    case claude = "Claude"
    case gemini = "Gemini"

    var id: String { rawValue }

    var shortName: String {
        switch self { case .codex: return "ChatGPT"; case .claude: return "Claude"; case .gemini: return "Gemini" }
    }

    var defaultModel: String {
        switch self { case .codex: return "gpt-5.6-luna"; case .claude: return "claude-sonnet-5"; case .gemini: return "gemini-3.1-pro-preview" }
    }

    var modelOptions: [(label: String, id: String)] {
        switch self {
        case .codex: return [("GPT-5.6 Luna", "gpt-5.6-luna"), ("GPT-5.6 Terra", "gpt-5.6-terra"), ("GPT-5.6 Sol", "gpt-5.6-sol")]
        case .claude: return [("Claude Sonnet 5", "claude-sonnet-5"), ("Claude Opus 4.8", "claude-opus-4-8"), ("Claude Haiku 4.5", "claude-haiku-4-5")]
        case .gemini: return [("Gemini 3.1 Pro", "gemini-3.1-pro-preview"), ("Gemini 3.1 Flash Lite", "gemini-3.1-flash-lite"), ("Gemini 2.5 Pro", "gemini-2.5-pro"), ("Gemini 2.5 Flash", "gemini-2.5-flash")]
        }
    }

    var modelDefaultsKey: String { "meetingModel.\(id)" }
}

// Which engine produces meeting transcripts. Cloud transcription is diarized and names speakers;
// the on-device engine is the privacy-preserving fallback and always works offline.
enum MeetingTranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case gemini = "Gemini (cloud)"
    case local = "On-device"

    var id: String { rawValue }
    var shortName: String { self == .gemini ? "Gemini" : "On-device" }
    var detail: String {
        switch self {
        case .gemini: return "Uploads meeting audio to Vertex AI. Names speakers and separates every voice."
        case .local: return "Never leaves this Mac. Splits your voice from everyone else's, without names."
        }
    }
    static let defaultsKey = "meetingTranscriptionEngine"
    static var current: MeetingTranscriptionEngine {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let engine = MeetingTranscriptionEngine(rawValue: raw) else { return .gemini }
        return engine
    }
}

struct MeetingSpeaker: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var isPrimaryUser: Bool
    var evidence: String?

    // Stable per-speaker tint so the same voice keeps its colour down the whole transcript.
    var colorIndex: Int { abs(id.hashValue) % 6 }
}

struct MeetingUtterance: Codable, Equatable, Identifiable {
    var start: TimeInterval
    var end: TimeInterval
    var speakerId: String
    var text: String

    // Identity for list rendering: two turns can share a start second, so the span and length
    // participate too.
    var id: String { "\(start)-\(end)-\(speakerId)-\(text.count)-\(text.prefix(24))" }
    var timestamp: String { MeetingStructuredTranscript.timestamp(start) }
}

struct MeetingStructuredTranscript: Codable, Equatable {
    var speakers: [MeetingSpeaker]
    var utterances: [MeetingUtterance]
    var engine: String
    var model: String?
    var generatedAt: Date
    // Set when part of the meeting could not be transcribed, so the gap is stated rather than
    // silently absent.
    var note: String?

    func speaker(_ id: String) -> MeetingSpeaker? { speakers.first { $0.id == id } }

    func name(for id: String) -> String {
        guard let speaker = speaker(id) else { return "Unknown" }
        return speaker.isPrimaryUser && speaker.displayName.caseInsensitiveCompare("You") != .orderedSame
            ? "\(speaker.displayName) (you)" : speaker.displayName
    }

    // The flat rendering every existing feature already understands: search, briefs, and Q&A all
    // read MeetingRecord.transcript, so structured output stays additive rather than a migration.
    var plainText: String {
        utterances.map { "[\($0.timestamp)] \(name(for: $0.speakerId)): \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var source: String
    var systemAudioPaths: [String]
    var microphoneAudioPaths: [String]
    var transcript: String
    var summary: String
    var summaryProvider: MeetingSummaryProvider?
    var error: String?
    var isPinned: Bool
    // Added after v1: absent in older meeting.json files, which still decode cleanly.
    var structured: MeetingStructuredTranscript?
    var transcriptEngine: String?
    var audioPath: String?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

final class MeetingStore: @unchecked Sendable {
    static let shared = MeetingStore()
    private let lock = NSLock()
    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func meetingDirectory(id: UUID) throws -> URL {
        let url = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func save(_ meeting: MeetingRecord) throws {
        let directory = try meetingDirectory(id: meeting.id)
        let data = try JSONEncoder.murmur.encode(meeting)
        let target = directory.appendingPathComponent("meeting.json")
        let temporary = directory.appendingPathComponent("meeting.json.tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    func loadAll() -> [MeetingRecord] {
        lock.withLock {
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return directories.compactMap { url in
                let file = url.appendingPathComponent("meeting.json")
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder.murmur.decode(MeetingRecord.self, from: data)
            }.sorted { $0.startedAt > $1.startedAt }
        }
    }

    func delete(_ meeting: MeetingRecord) throws {
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(meeting.id.uuidString))
    }

    func cleanup(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        for meeting in loadAll() where !meeting.isPinned && meeting.startedAt < cutoff {
            do { try delete(meeting); Log.info("deleted expired meeting \(meeting.id)") }
            catch { Log.error("meeting cleanup failed: \(error.localizedDescription)") }
        }
    }
}

private extension JSONEncoder {
    static var murmur: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var murmur: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
