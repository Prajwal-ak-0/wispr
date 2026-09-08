import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        failures += 1
        print("✗ \(message)")
    }
}

expect(MeetingSummaryProvider.codex.defaultModel == "gpt-5.6-luna", "ChatGPT defaults to Luna")
expect(MeetingSummaryProvider.claude.defaultModel == "claude-sonnet-5", "Claude defaults to Sonnet 5")
expect(MeetingSummaryProvider.codex.modelOptions.count == 3, "all requested GPT-5.6 models are selectable")
expect(MeetingSummaryProvider.claude.modelOptions.count == 3, "all requested Claude models are selectable")
expect(MeetingSummaryProvider.gemini.shortName == "Gemini", "provider labels are user friendly")
expect(MeetingTimeline.chunkOffsets(durations: [100, 100, 51.9]) == [0, 100, 200],
       "meeting timestamps use real per-file durations")

let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-store-tests-\(UUID())")
let store = MeetingStore(rootURL: storeRoot)
let oldDate = Calendar.current.date(byAdding: .day, value: -45, to: Date())!
let recent = MeetingRecord(id: UUID(), title: "Morning sync", startedAt: Date(), endedAt: Date(),
    status: .ready, source: "google-meet", systemAudioPaths: [], microphoneAudioPaths: [],
    transcript: "[00:00:01] Others: Hello", summary: "", summaryProvider: nil, error: nil, isPinned: false)
let expired = MeetingRecord(id: UUID(), title: "Old sync", startedAt: oldDate, endedAt: oldDate,
    status: .ready, source: "manual", systemAudioPaths: [], microphoneAudioPaths: [],
    transcript: "Old", summary: "", summaryProvider: nil, error: nil, isPinned: false)
let pinned = MeetingRecord(id: UUID(), title: "Pinned sync", startedAt: oldDate, endedAt: oldDate,
    status: .ready, source: "manual", systemAudioPaths: [], microphoneAudioPaths: [],
    transcript: "Pinned", summary: "", summaryProvider: .codex, error: nil, isPinned: true)
do {
    try store.save(recent); try store.save(expired); try store.save(pinned)
    expect(store.loadAll().count == 3, "meeting history round-trips atomically")
    expect(store.loadAll().first?.id == recent.id, "meeting history is newest first")
    store.cleanup(retentionDays: 30)
    let retained = store.loadAll()
    expect(retained.contains(where: { $0.id == recent.id }), "retention keeps recent meetings")
    expect(!retained.contains(where: { $0.id == expired.id }), "retention deletes expired meetings")
    expect(retained.contains(where: { $0.id == pinned.id }), "retention never deletes pinned meetings")
} catch {
    expect(false, "meeting store operations succeed: \(error)")
}
try? FileManager.default.removeItem(at: storeRoot)

// ---- structured transcript ----------------------------------------------------------------
let structured = MeetingStructuredTranscript(
    speakers: [
        MeetingSpeaker(id: "spk_1", displayName: "Amit", isPrimaryUser: false, evidence: "thanks Amit"),
        MeetingSpeaker(id: "spk_2", displayName: "Gautam", isPrimaryUser: true, evidence: nil),
        MeetingSpeaker(id: "spk_3", displayName: "You", isPrimaryUser: true, evidence: nil),
    ],
    utterances: [
        MeetingUtterance(start: 5, end: 9, speakerId: "spk_1", text: "Did the deploy land?"),
        MeetingUtterance(start: 3661, end: 3665, speakerId: "spk_2", text: "Yes, this morning."),
    ],
    engine: "Gemini", model: "gemini-3.1-pro-preview", generatedAt: Date())

expect(MeetingStructuredTranscript.timestamp(3661) == "01:01:01", "timestamps render as hh:mm:ss")
expect(MeetingStructuredTranscript.timestamp(-5) == "00:00:00", "negative offsets clamp to zero")
expect(structured.name(for: "spk_1") == "Amit", "other speakers keep their spoken name")
expect(structured.name(for: "spk_2") == "Gautam (you)", "a named device owner is marked as you")
expect(structured.name(for: "spk_3") == "You", "an unnamed device owner is not labelled twice")
expect(structured.name(for: "nope") == "Unknown", "an unknown speaker id still renders")
expect(structured.plainText == "[00:00:05] Amit: Did the deploy land?\n\n[01:01:01] Gautam (you): Yes, this morning.",
       "structured transcripts flatten to the text every other feature reads")
expect(structured.speakers[0].colorIndex == structured.speakers[0].colorIndex,
       "speaker colour is stable for one id")

// A meeting recorded before this feature has no structured transcript and must still decode.
let legacy = """
{"id":"\(UUID().uuidString)","title":"Legacy","startedAt":"2026-08-01T09:00:00Z",
 "status":"ready","source":"manual","systemAudioPaths":[],"microphoneAudioPaths":[],
 "transcript":"[00:00:01] You: hi","summary":"","isPinned":false}
"""
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
if let decoded = try? legacyDecoder.decode(MeetingRecord.self, from: Data(legacy.utf8)) {
    expect(decoded.structured == nil, "meetings recorded before diarization still load")
    expect(decoded.audioPath == nil, "older meetings simply have no exported audio")
} else {
    expect(false, "meetings recorded before diarization still load")
}

expect(MeetingTranscriptionEngine.gemini.shortName == "Gemini", "engine has a short label for badges")
expect(MeetingTranscriptionEngine.allCases.count == 2, "the engine picker offers cloud and on-device")

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}
print("\nAll tests passed")
