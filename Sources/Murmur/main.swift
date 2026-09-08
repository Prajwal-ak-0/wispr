import AppKit

func runMeetingProviderTest(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--meeting-provider-test"), index + 1 < arguments.count else {
        print("usage: Murmur --meeting-provider-test codex|claude|gemini")
        exit(2)
    }
    let provider: MeetingSummaryProvider
    switch arguments[index + 1].lowercased() {
    case "codex": provider = .codex
    case "claude": provider = .claude
    case "gemini": provider = .gemini
    default: print("unknown provider"); exit(2)
    }
    Task {
        do {
            let result = try await MeetingLLMService().summarize(
                transcript: "[00:00:01] You: The synthetic test decision is to ship Friday.",
                provider: provider)
            print(result)
            exit(0)
        } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
}

// Re-runs the full post-recording pipeline (mix to mp3 -> chosen engine -> structured transcript)
// against a meeting that is already on disk, so the whole path can be exercised without sitting
// through a live call.
func runMeetingTranscribe(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--transcribe-meeting"), index + 1 < arguments.count,
          let id = UUID(uuidString: arguments[index + 1]),
          var meeting = MeetingStore.shared.loadAll().first(where: { $0.id == id }) else {
        print("usage: Murmur --transcribe-meeting <meeting-uuid> [--engine gemini|local] [--dry-run]")
        exit(2)
    }
    var engine = MeetingTranscriptionEngine.current
    if let e = arguments.firstIndex(of: "--engine"), e + 1 < arguments.count {
        engine = arguments[e + 1].lowercased() == "local" ? .local : .gemini
    }
    let dryRun = arguments.contains("--dry-run")
    Task {
        do {
            let directory = try MeetingStore.shared.meetingDirectory(id: meeting.id)
            let started = Date()
            let outcome = try await MeetingTranscriptionPipeline().run(
                system: meeting.systemAudioPaths.map { URL(fileURLWithPath: $0) },
                microphone: meeting.microphoneAudioPaths.map { URL(fileURLWithPath: $0) },
                directory: directory, engine: engine)
            print("engine:   \(outcome.engine)")
            print("audio:    \(outcome.audioPath ?? "—")")
            print("elapsed:  \(Int(Date().timeIntervalSince(started)))s")
            if let warning = outcome.warning, !warning.isEmpty { print("warning:  \(warning)") }
            if let structured = outcome.structured {
                print("speakers: " + structured.speakers
                    .map { "\($0.displayName)\($0.isPrimaryUser ? " (you)" : "")" }.joined(separator: ", "))
                print("turns:    \(structured.utterances.count)")
                print("covers:   \(MeetingStructuredTranscript.timestamp(structured.utterances.last?.end ?? 0))")
            }
            print("---")
            print(outcome.text.prefix(1200))
            if !dryRun {
                meeting.transcript = outcome.text
                meeting.structured = outcome.structured
                meeting.transcriptEngine = outcome.engine
                meeting.audioPath = outcome.audioPath
                meeting.status = .ready
                meeting.error = outcome.text.isEmpty ? "No speech was detected" : outcome.warning
                try MeetingStore.shared.save(meeting)
                print("--- saved to \(directory.path)/meeting.json")
            }
            exit(0)
        } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
}

func runMeetingRepair(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--repair-meeting"), index + 1 < arguments.count,
          let id = UUID(uuidString: arguments[index + 1]),
          var meeting = MeetingStore.shared.loadAll().first(where: { $0.id == id }) else {
        print("usage: Murmur --repair-meeting <meeting-uuid>")
        exit(2)
    }
    Task {
        do {
            meeting.transcript = try await MeetingTranscriptionService().transcribe(
                system: meeting.systemAudioPaths.map { URL(fileURLWithPath: $0) },
                microphone: meeting.microphoneAudioPaths.map { URL(fileURLWithPath: $0) })
            if let provider = meeting.summaryProvider {
                meeting.summary = try await MeetingLLMService().summarize(transcript: meeting.transcript, provider: provider)
            }
            meeting.error = nil
            try MeetingStore.shared.save(meeting)
            print("Repaired \(meeting.title): \(meeting.transcript.count) transcript characters")
            exit(0)
        } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
}

let arguments = CommandLine.arguments
if arguments.contains("--meeting-provider-test") {
    runMeetingProviderTest(arguments)
} else if arguments.contains("--transcribe-meeting") {
    runMeetingTranscribe(arguments)
} else if arguments.contains("--repair-meeting") {
    runMeetingRepair(arguments)
} else {
    let app = NSApplication.shared
    let controller = MainActor.assumeIsolated { AppController() }
    app.delegate = controller
    // A regular activation policy keeps the meeting dashboard visible in Cmd-Tab and the Dock.
    app.setActivationPolicy(.regular)
    app.run()
}
