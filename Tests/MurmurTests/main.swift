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

expect(!RecordingState.idle.canPauseOrResume, "idle cannot pause")
expect(Config.maxRecordingSeconds >= 10_800, "long dictation is never cancelled after a few minutes")
expect(!RecordingState.idle.canFinish, "idle cannot finish")
expect(!RecordingState.idle.canCancel, "idle cannot cancel")

expect(RecordingState.recording.canPauseOrResume, "recording can pause")
expect(RecordingState.recording.canFinish, "recording can finish")
expect(RecordingState.recording.canCancel, "recording can cancel")
expect(!RecordingState.recording.canPauseOrResume(recorderReady: false, pushToTalk: false),
       "recording cannot pause before microphone startup completes")
expect(!RecordingState.recording.canPauseOrResume(recorderReady: true, pushToTalk: true),
       "push-to-talk recording cannot be paused")
expect(RecordingState.recording.canPauseOrResume(recorderReady: true, pushToTalk: false),
       "ready hands-free recording can be paused")

expect(RecordingState.paused.canPauseOrResume, "paused recording can resume")
expect(RecordingState.paused.canFinish, "paused recording can finish without losing text")
expect(RecordingState.paused.canCancel, "paused recording can cancel")

expect(!RecordingState.processing.canPauseOrResume, "processing cannot pause")
expect(!RecordingState.processing.canFinish, "processing cannot finish twice")
expect(RecordingState.processing.canCancel, "processing remains cancellable")

for app in ["WhatsApp", "Messages", "Signal"] {
    expect(Config.style(bundleID: nil, appName: app).name == "casual", "\(app) uses casual formatting")
}
for app in ["Slack", "Microsoft Teams", "Discord"] {
    expect(Config.style(bundleID: nil, appName: app).name == "structured", "\(app) uses structured formatting")
}
expect(Config.style(bundleID: "com.apple.TextEdit", appName: "TextEdit").name == "default",
       "unknown apps use balanced formatting")

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

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}
print("\nAll tests passed")
