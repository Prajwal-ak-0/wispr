import AppKit
import AVFoundation

func runLevelTest(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--leveltest"), index + 1 < arguments.count else {
        print("usage: Murmur --leveltest <audiofile>")
        exit(2)
    }
    guard let analyzer = SpectrumAnalyzer(size: 1024) else { print("analyzer init failed"); exit(1) }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1]))
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              file.length > 0 else { print("empty file"); exit(1) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { print("no float channel data"); exit(1) }

        let total = Int(buffer.frameLength)
        let window = 1024
        let frames = 12
        let step = max(window, (total - window) / (frames - 1))
        for i in 0..<frames {
            let t = i * step
            if t + window > total { break }
            let bands = analyzer.analyze(channel[0].advanced(by: t), count: window, bandCount: Config.barCount)
            print(String(format: "frame %2d:", i) + " " + bands.map { String(format: "%.4f", $0) }.joined(separator: " "))
        }
    } catch {
        print("ERROR: \(error)")
    }
    exit(0)
}

func runSelfTest(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count else {
        print("usage: Murmur --selftest <audiofile>")
        exit(2)
    }
    let path = arguments[index + 1]
    let transcriber = LiveTranscriber()
    Task {
        do {
            let raw = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: path))
            print("RAW:\n\(raw)\n")
            let formatted = await TextFormatter.format(raw, style: Config.defaultStyle)
            print("FORMATTED:\n\(formatted)")
        } catch {
            print("ERROR: \(error)")
        }
        DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
    }
    CFRunLoopRun()
}

func runFormatTest(_ arguments: [String]) {
    guard let index = arguments.firstIndex(of: "--format"), index + 1 < arguments.count else {
        print("usage: Murmur --format \"<text>\" [--app <name>]")
        exit(2)
    }
    let text = arguments[index + 1]
    var appName: String?
    if let a = arguments.firstIndex(of: "--app"), a + 1 < arguments.count { appName = arguments[a + 1] }
    let style = Config.style(bundleID: nil, appName: appName)
    Task {
        let out = await TextFormatter.format(text, style: style)
        print("[style: \(style.name), app: \(appName ?? "—")]")
        print(out)
        DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
    }
    CFRunLoopRun()
}

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
if arguments.contains("--leveltest") {
    runLevelTest(arguments)
} else if arguments.contains("--format") {
    runFormatTest(arguments)
} else if arguments.contains("--selftest") {
    runSelfTest(arguments)
} else if arguments.contains("--meeting-provider-test") {
    runMeetingProviderTest(arguments)
} else if arguments.contains("--repair-meeting") {
    runMeetingRepair(arguments)
} else {
    let app = NSApplication.shared
    let controller = MainActor.assumeIsolated { AppController() }
    app.delegate = controller
    // V2 has a real dashboard. A regular activation policy keeps it visible in Cmd-Tab and the
    // Dock while preserving the menu-bar controls used by dictation.
    app.setActivationPolicy(.regular)
    app.run()
}
