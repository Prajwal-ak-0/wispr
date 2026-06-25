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
    private var cancelRequested = false
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
            case .processing: break
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
            self.abortRecording()
        }
        hotkeys.onCancel = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .recording: self.abortRecording()
            case .processing: self.cancelRequested = true
            case .idle: break
            }
        }
    }

    // MARK: - Recording pipeline

    private func startRecording(pushToTalk: Bool) {
        guard state == .idle else { return }
        state = .recording
        self.pushToTalk = pushToTalk
        cancelRequested = false
        let front = NSWorkspace.shared.frontmostApplication
        activeBundleID = front?.bundleIdentifier
        activeAppName = front?.localizedName
        overlay.show(.listening)
        setStatus("Listening…")

        Task { @MainActor in
            do {
                let format = try await transcriber.startSession()
                recorder.onBuffer = { [weak self] buffer in self?.transcriber.feed(buffer) }
                recorder.onLevels = { [weak self] rms, bands in self?.overlay.setLevels(rms: rms, bands: bands) }
                try recorder.start(targetFormat: format)
            } catch {
                Log.error("failed to start recording: \(error.localizedDescription)")
                self.abortRecording()
            }
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }
        state = .processing
        overlay.show(.processing)
        setStatus("Transcribing…")
        recorder.stop()

        Task { @MainActor in
            do {
                let raw = try await transcriber.finish()
                Log.info("transcribed \(raw.count) chars")
                guard !raw.isEmpty else { return finishProcessing(nil) }
                let style = Config.style(bundleID: activeBundleID, appName: activeAppName)
                Log.info("formatting with '\(style.name)' style for \(activeAppName ?? "unknown app")")
                let formatted = await TextFormatter.format(raw, style: style)
                Log.info("formatted \(formatted.count) chars")
                finishProcessing(formatted)
            } catch {
                Log.error("transcription failed: \(error.localizedDescription)")
                finishProcessing(nil)
            }
        }
    }

    private func finishProcessing(_ text: String?) {
        overlay.hide()
        state = .idle
        pushToTalk = false
        setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        let cancelled = cancelRequested
        cancelRequested = false
        if !cancelled, let text, !text.isEmpty { Paster.paste(text) }
    }

    private func abortRecording() {
        recorder.stop()
        overlay.hide()
        state = .idle
        pushToTalk = false
        cancelRequested = false
        setStatus("Ready · ⌘⌘ toggle · hold ⌥")
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
