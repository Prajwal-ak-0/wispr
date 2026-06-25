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

let arguments = CommandLine.arguments
if arguments.contains("--leveltest") {
    runLevelTest(arguments)
} else if arguments.contains("--format") {
    runFormatTest(arguments)
} else if arguments.contains("--selftest") {
    runSelfTest(arguments)
} else {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
