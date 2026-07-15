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
