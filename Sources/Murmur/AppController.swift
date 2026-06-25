import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate {
    private enum RecordState { case idle, recording, processing }

    private let transcriber = LiveTranscriber()
    private let recorder = MicRecorder()
    private let overlay = OverlayController()
    private let hotkeys = HotkeyMonitor()

    private var state: RecordState = .idle
    private var pushToTalk = false
    private var runID = 0
    private var activeBundleID: String?
    private var activeAppName: String?

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        requestPermissions()

        Task {
            do { try await transcriber.prepareAssets() }
            catch { Log.error("asset preparation failed: \(error.localizedDescription)") }
        }

        wireHotkeys()
        if hotkeys.start() {
            setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        } else {
            setStatus("⚠︎ Grant Input Monitoring, then relaunch")
        }
        ensureLoginItem()
        Log.info("permissions — inputMonitoring: \(CGPreflightListenEventAccess()), accessibility: \(AXIsProcessTrusted())")
    }

    // Auto-start at login so the hotkeys are always available — the app is useless when not running.
    private func ensureLoginItem() {
        guard SMAppService.mainApp.status != .enabled else {
            Log.info("login item already enabled")
            return
        }
        do {
            try SMAppService.mainApp.register()
            Log.info("registered as login item")
        } catch {
            Log.error("login item register failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hotkeys

    private func wireHotkeys() {
        hotkeys.onToggle = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .idle: self.startRecording(pushToTalk: false)
            case .recording: self.stopRecordingAndProcess()
            case .processing: break   // finishing (bounded); Esc force-cancels if needed
            }
        }
        hotkeys.onPushToTalkStart = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.startRecording(pushToTalk: true)
        }
        hotkeys.onPushToTalkStop = { [weak self] in
            guard let self, self.state == .recording, self.pushToTalk else { return }
            self.stopRecordingAndProcess()
        }
        hotkeys.onPushToTalkAbort = { [weak self] in
            guard let self, self.state == .recording, self.pushToTalk else { return }
            self.reset()
        }
        // Esc is a universal escape hatch — always returns to idle, from any state.
        hotkeys.onCancel = { [weak self] in self?.reset() }
    }

    // MARK: - Recording pipeline
    //
    // `runID` bumps on every start and every reset. Each async step re-checks it before touching
    // shared state, so a stale task (superseded by Esc, a new recording, or a timeout) can never
    // paste, clobber state, or wedge the UI.

    private func startRecording(pushToTalk: Bool) {
        guard state == .idle else { return }
        runID += 1
        let run = runID
        state = .recording
        self.pushToTalk = pushToTalk
        let front = NSWorkspace.shared.frontmostApplication
        activeBundleID = front?.bundleIdentifier
        activeAppName = front?.localizedName
        overlay.show(.listening)
        setStatus("Listening…")

        Task { @MainActor in
            do {
                let format = try await transcriber.startSession()
                guard runID == run, state == .recording else {
                    transcriber.cancel()   // superseded during setup — never leave a hot mic
                    return
                }
                recorder.onBuffer = { [weak self] buffer in self?.transcriber.feed(buffer) }
                recorder.onLevels = { [weak self] rms, bands in self?.overlay.setLevels(rms: rms, bands: bands) }
                try recorder.start(targetFormat: format)
            } catch {
                Log.error("failed to start recording: \(error.localizedDescription)")
                if runID == run { reset() }
            }
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }
        let run = runID
        state = .processing
        overlay.show(.processing)
        setStatus("Transcribing…")
        recorder.stop()

        Task { @MainActor in
            let raw = await transcriber.finish()   // bounded — never hangs
            guard runID == run, state == .processing else { return Log.info("result superseded — dropped") }
            Log.info("transcribed \(raw.count) chars")
            guard !raw.isEmpty else { return finishProcessing(nil, run: run) }
            let style = Config.style(bundleID: activeBundleID, appName: activeAppName)
            Log.info("formatting with '\(style.name)' style for \(activeAppName ?? "unknown app")")
            let formatted = await TextFormatter.format(raw, style: style)
            guard runID == run, state == .processing else { return Log.info("result superseded — dropped") }
            Log.info("formatted \(formatted.count) chars")
            finishProcessing(formatted, run: run)
        }
    }

    private func finishProcessing(_ text: String?, run: Int) {
        guard runID == run else { return }
        overlay.hide()
        state = .idle
        pushToTalk = false
        setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        if let text, !text.isEmpty { Paster.paste(text) }
    }

    // Universal reset: stop everything and return to idle, regardless of current state.
    private func reset() {
        runID += 1   // invalidate any in-flight start/processing task
        recorder.stop()
        transcriber.cancel()
        overlay.hide()
        state = .idle
        pushToTalk = false
        setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        Log.info("reset")
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info("microphone access granted: \(granted)")
        }
        if !CGRequestListenEventAccess() {
            Log.info("requested Input Monitoring access")
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.info("requested Accessibility access")
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggleHint = NSMenuItem(title: "Double-tap ⌘  →  start / stop", action: nil, keyEquivalent: "")
        toggleHint.isEnabled = false
        menu.addItem(toggleHint)
        let pttHint = NSMenuItem(title: "Hold ⌥  →  push-to-talk", action: nil, keyEquivalent: "")
        pttHint.isEnabled = false
        menu.addItem(pttHint)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Permission Settings…",
                                action: #selector(openPermissions), keyEquivalent: ""))
        let loginItem = NSMenuItem(title: "Start at Login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLine?.title = text }
    }

    @objc private func openPermissions() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        if let first = urls.first, let url = URL(string: first) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            Log.error("login item toggle failed: \(error.localizedDescription)")
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.logPath))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
