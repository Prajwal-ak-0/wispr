import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

// Controller state is main-thread-owned. Background closures only operate the serialized recorder
// and marshal every controller mutation back to the main queue.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let transcriber = LiveTranscriber()
    private let recorder = MicRecorder()
    private let overlay = OverlayController()
    private let hotkeys = HotkeyMonitor()

    private var state: RecordingState = .idle
    private var pushToTalk = false
    private var recorderReady = false
    private var runID = 0
    private var activeBundleID: String?
    private var activeAppName: String?
    private var recordOnlyInTextFields = true
    private static let textGateKey = "recordOnlyInTextFields"

    private var recordingWatchdog: DispatchWorkItem?
    private let audioQueue = DispatchQueue(label: "ai.murmur.audio")

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!
    private var finishMenuItem: NSMenuItem!
    private var cancelMenuItem: NSMenuItem!
    private var meetingCoordinator: MeetingCoordinator!
    private var meetBridge: MeetBridgeServer!
    private var lastMeetHeartbeat: Date?
    private var meetHeartbeatTimer: Timer?
    private var activeMeetURL: String?
    private var pendingMeetStop: DispatchWorkItem?
    private let meetingActivityPanel = MeetingActivityPanel()
    private var pendingMeetOffer: BrowserMeetEvent?
    private var transcriptCommandMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        meetingCoordinator = MeetingCoordinator()
        meetingCoordinator.onActivity = { [weak self] activity in
            self?.meetingActivityPanel.update(activity)
            self?.updateMeetingStatusIcon(activity)
        }
        meetingActivityPanel.onStop = { [weak self] in self?.meetingCoordinator.stop() }
        meetingActivityPanel.onAcceptRecording = { [weak self] in
            guard let self, let event = self.pendingMeetOffer else { return }
            self.pendingMeetOffer = nil
            self.activeMeetURL = event.url
            self.meetingCoordinator.start(title: event.title ?? "Google Meet", source: "google-meet")
        }
        meetingActivityPanel.onDeclineRecording = { [weak self] in self?.pendingMeetOffer = nil }
        if let saved = UserDefaults.standard.object(forKey: Self.textGateKey) as? Bool {
            recordOnlyInTextFields = saved
        }
        buildMenu()
        buildApplicationMenu()
        requestPermissions()

        Task {
            do { try await transcriber.prepareAssets() }
            catch { Log.error("asset preparation failed: \(error.localizedDescription)") }
        }

        wireHotkeys()
        wireOverlay()
        installTranscriptCommands()
        startMeetBridge()
        if hotkeys.start() {
            setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        } else {
            setStatus("⚠︎ Grant Input Monitoring, then relaunch")
        }
        ensureLoginItem()
        Log.info("permissions — inputMonitoring: \(CGPreflightListenEventAccess()), accessibility: \(AXIsProcessTrusted())")
        if CommandLine.arguments.contains("--dashboard") { meetingCoordinator.showDashboard() }
    }

    private func installTranscriptCommands() {
        transcriptCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let transcript = TranscriptTextView.active,
                  transcript.window === NSApp.keyWindow else { return event }
            if key == "c" { transcript.copySelectedText(); return nil }
            if key == "f" { transcript.showFindInterface(); return nil }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { meetingCoordinator.showDashboard() }
        return true
    }

    private func updateMeetingStatusIcon(_ activity: MeetingActivity) {
        switch activity {
        case .recordingOffer: break
        case .starting, .transcribing:
            statusItem?.button?.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Murmur processing meeting")
        case .recording:
            statusItem?.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Murmur recording meeting")
            statusItem?.button?.contentTintColor = .systemRed
        case .ready, .failed, .hidden:
            statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
            statusItem?.button?.contentTintColor = nil
        }
    }

    private func startMeetBridge() {
        let bridge = MeetBridgeServer()
        bridge.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleMeetEvent(event) }
        }
        bridge.start()
        meetBridge = bridge
        meetHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let heartbeat = self.lastMeetHeartbeat,
                      Date().timeIntervalSince(heartbeat) > 30,
                      self.meetingCoordinator.activeMeeting?.source == "google-meet" else { return }
                Log.error("Google Meet heartbeat expired — stopping capture safely")
                self.lastMeetHeartbeat = nil
                self.pendingMeetStop?.cancel()
                self.pendingMeetStop = nil
                self.activeMeetURL = nil
                self.meetingCoordinator.stop()
            }
        }
    }

    private func handleMeetEvent(_ event: BrowserMeetEvent) {
        switch event.kind {
        case "joined":
            lastMeetHeartbeat = Date()
            pendingMeetStop?.cancel()
            pendingMeetStop = nil
            if meetingCoordinator.activeMeeting?.source == "google-meet" {
                activeMeetURL = activeMeetURL ?? event.url
                Log.info("duplicate Meet join ignored for active session: \(event.url ?? "unknown")")
                return
            }
            if pendingMeetOffer?.url == event.url { return }
            pendingMeetOffer = event
            meetingActivityPanel.update(.recordingOffer(event.title ?? "Google Meet"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.pendingMeetOffer = nil }
        case "heartbeat":
            lastMeetHeartbeat = Date()
            pendingMeetStop?.cancel()
            pendingMeetStop = nil
        case "left":
            lastMeetHeartbeat = nil
            pendingMeetOffer = nil
            pendingMeetStop?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.lastMeetHeartbeat == nil,
                      self.meetingCoordinator.activeMeeting?.source == "google-meet" else { return }
                Log.info("sustained Meet leave confirmed — stopping capture")
                self.activeMeetURL = nil
                self.meetingCoordinator.stop()
            }
            pendingMeetStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        default: break
        }
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
            case .paused: self.resumeRecording()
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
        // Esc is a universal escape hatch — returns to idle from recording/processing.
        hotkeys.onCancel = { [weak self] in
            guard let self, self.state != .idle else { return }
            self.reset()
        }
        hotkeys.onPauseResume = { [weak self] in self?.togglePause() }
    }

    private func wireOverlay() {
        overlay.onPauseResume = { [weak self] in self?.togglePause() }
        overlay.onFinish = { [weak self] in self?.stopRecordingAndProcess() }
    }

    // MARK: - Recording pipeline
    //
    // `runID` bumps on every start and every reset. Each async step re-checks it before touching
    // shared state, so a stale task (superseded by Esc, a new recording, or a timeout) can never
    // paste, clobber state, or wedge the UI.

    private func startRecording(pushToTalk: Bool) {
        guard state == .idle else { return }
        if recordOnlyInTextFields, !FocusInspector.isTextInputFocused() {
            Log.info("hotkey ignored — no editable text field focused")
            return
        }
        runID += 1
        let run = runID
        state = .recording
        self.pushToTalk = pushToTalk
        recorderReady = false
        scheduleWatchdog()
        let front = NSWorkspace.shared.frontmostApplication
        activeBundleID = front?.bundleIdentifier
        activeAppName = front?.localizedName
        overlay.show(.listening)
        overlay.setPauseAvailable(!pushToTalk)
        setStatus("Listening…")
        updateRecordingControls()

        Task { @MainActor in
            do {
                let format = try await transcriber.startSession()
                guard runID == run, state == .recording else {
                    transcriber.cancel()   // superseded during setup — never leave a hot mic
                    return
                }
                recorder.onBuffer = { [weak self] buffer in self?.transcriber.feed(buffer) }
                recorder.onLevels = { [weak self] rms, bands in self?.overlay.setLevels(rms: rms, bands: bands) }
                // engine.start() can BLOCK while negotiating a Bluetooth mic — run it off the main
                // thread so the UI, hotkeys, and the menu stay responsive no matter what.
                audioQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.recorder.start(targetFormat: format)
                        DispatchQueue.main.async {
                            guard self.runID == run, self.state == .recording else { return }
                            self.recorderReady = true
                            self.overlay.setPauseAvailable(!self.pushToTalk)
                            self.updateRecordingControls()
                        }
                    } catch {
                        Log.error("failed to start recording: \(error.localizedDescription)")
                        DispatchQueue.main.async { if self.runID == run { self.reset() } }
                    }
                }
            } catch {
                Log.error("failed to start recording: \(error.localizedDescription)")
                if runID == run { reset() }
            }
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording || state == .paused else { return }
        let run = runID
        state = .processing
        overlay.show(.processing)
        setStatus("Transcribing…")
        updateRecordingControls()

        Task { @MainActor in
            // Stop the tap before closing the analyzer input. Otherwise buffers delivered while
            // recorder.stop() is queued arrive after finish() has closed the stream, clipping the
            // last word or two of a recording.
            await withCheckedContinuation { continuation in
                audioQueue.async { [recorder] in
                    recorder.stop()
                    continuation.resume()
                }
            }
            guard runID == run, state == .processing else { return Log.info("stop superseded — dropped") }
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

    private func togglePause() {
        switch state {
        case .recording: pauseRecording()
        case .paused: resumeRecording()
        case .idle, .processing: break
        }
    }

    private func pauseRecording() {
        guard state == .recording, !pushToTalk, recorderReady else { return }
        state = .paused
        cancelWatchdog()
        overlay.show(.paused)
        setStatus("Paused · resume when ready")
        updateRecordingControls()
        audioQueue.async { [recorder] in recorder.pause() }
    }

    private func resumeRecording() {
        guard state == .paused else { return }
        let run = runID
        state = .recording
        scheduleWatchdog()
        overlay.show(.listening)
        overlay.setPauseAvailable(true)
        setStatus("Listening…")
        updateRecordingControls()
        audioQueue.async { [weak self] in
            guard let self else { return }
            do { try self.recorder.resume() }
            catch {
                Log.error("failed to resume recording: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if self.runID == run, self.state == .recording { self.reset() }
                }
            }
        }
    }

    private func finishProcessing(_ text: String?, run: Int) {
        guard runID == run else { return }
        cancelWatchdog()
        overlay.hide()
        state = .idle
        pushToTalk = false
        recorderReady = false
        updateRecordingControls()
        if let text, !text.isEmpty {
            Paster.paste(text)
            audioQueue.async { [recorder] in recorder.discardRecovery() }
            setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        } else if recorder.peakLevel < 0.002 {
            setStatus("No audio captured — mic busy? (music / Bluetooth)")
        } else {
            setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        }
    }

    // Universal reset: stop everything and return to idle, regardless of current state.
    private func reset() {
        runID += 1   // invalidate any in-flight start/processing task
        cancelWatchdog()
        overlay.hide()           // UI first — guaranteed, never blocked by audio teardown
        state = .idle
        pushToTalk = false
        recorderReady = false
        updateRecordingControls()
        setStatus("Ready · ⌘⌘ toggle · hold ⌥")
        Log.info("reset")
        // Tear down audio off the main thread so a blocking engine.stop() can't freeze the UI.
        audioQueue.async { [recorder, transcriber] in
            recorder.stop()
            transcriber.cancel()
        }
    }

    // Emergency backstop: finalize and preserve the transcript instead of cancelling it.
    private func scheduleWatchdog() {
        recordingWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            Log.error("recording reached emergency limit — finalizing safely")
            self.stopRecordingAndProcess()
        }
        recordingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.maxRecordingSeconds, execute: work)
    }

    private func cancelWatchdog() {
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
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
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Record Meeting", action: #selector(startMeetingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Recording & Transcribe", action: #selector(stopMeetingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Up Google Meet in Arc…", action: #selector(setUpArcExtension), keyEquivalent: ""))
        menu.addItem(.separator())

        let toggleHint = NSMenuItem(title: "Double-tap ⌘  →  start / stop", action: nil, keyEquivalent: "")
        toggleHint.isEnabled = false
        menu.addItem(toggleHint)
        let pttHint = NSMenuItem(title: "Hold ⌥  →  push-to-talk", action: nil, keyEquivalent: "")
        pttHint.isEnabled = false
        menu.addItem(pttHint)
        menu.addItem(.separator())

        pauseMenuItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePauseFromMenu), keyEquivalent: "")
        pauseMenuItem.isEnabled = false
        menu.addItem(pauseMenuItem)
        finishMenuItem = NSMenuItem(title: "Finish Recording", action: #selector(finishFromMenu), keyEquivalent: "")
        finishMenuItem.isEnabled = false
        menu.addItem(finishMenuItem)
        cancelMenuItem = NSMenuItem(title: "Cancel Recording", action: #selector(cancelFromMenu), keyEquivalent: "")
        cancelMenuItem.isEnabled = false
        menu.addItem(cancelMenuItem)
        menu.addItem(.separator())

        let textGate = NSMenuItem(title: "Record only in text fields",
                                  action: #selector(toggleTextGate), keyEquivalent: "")
        textGate.state = recordOnlyInTextFields ? .on : .off
        menu.addItem(textGate)
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

    private func buildApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Murmur")
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        let copy = NSMenuItem(title: "Copy", action: #selector(copyFromApplicationMenu), keyEquivalent: "c")
        copy.target = self
        edit.addItem(copy)
        let find = NSMenuItem(title: "Find…", action: #selector(findFromApplicationMenu), keyEquivalent: "f")
        find.target = self
        edit.addItem(find)
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func copyFromApplicationMenu() {
        if let transcript = TranscriptTextView.active,
           transcript.window === NSApp.keyWindow,
           transcript.selectedRange().length > 0 {
            transcript.copySelectedText()
        } else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        }
    }

    @objc private func findFromApplicationMenu() {
        if let transcript = TranscriptTextView.active, transcript.window === NSApp.keyWindow {
            transcript.showFindInterface()
        } else {
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLine?.title = text }
    }

    private func updateRecordingControls() {
        guard pauseMenuItem != nil else { return }
        pauseMenuItem.title = state == .paused ? "Resume Recording" : "Pause Recording"
        pauseMenuItem.isEnabled = state.canPauseOrResume(recorderReady: recorderReady,
                                                         pushToTalk: pushToTalk)
        finishMenuItem.isEnabled = state.canFinish
        cancelMenuItem.isEnabled = state.canCancel
        hotkeys.spacePauseEnabled = state.canPauseOrResume(recorderReady: recorderReady,
                                                           pushToTalk: pushToTalk)
        statusItem.button?.image = NSImage(systemSymbolName: state == .paused ? "pause.circle.fill" :
            state == .recording ? "waveform.circle.fill" : state == .processing ? "ellipsis.circle.fill" : "mic.fill",
            accessibilityDescription: "Murmur")
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

    @objc private func toggleTextGate(_ sender: NSMenuItem) {
        recordOnlyInTextFields.toggle()
        sender.state = recordOnlyInTextFields ? .on : .off
        UserDefaults.standard.set(recordOnlyInTextFields, forKey: Self.textGateKey)
        Log.info("record only in text fields: \(recordOnlyInTextFields)")
    }

    @objc private func cancelFromMenu() {
        reset()
    }

    @objc private func openDashboard() { meetingCoordinator.showDashboard() }

    @objc private func startMeetingFromMenu() {
        meetingCoordinator.start(title: "Audio note", source: "manual")
        meetingCoordinator.showDashboard()
    }

    @objc private func stopMeetingFromMenu() { meetingCoordinator.stop() }

    @objc private func setUpArcExtension() {
        guard let extensionURL = Bundle.main.resourceURL?.appendingPathComponent("ArcExtension") else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extensionURL.path)
        if let url = URL(string: "arc://extensions") { NSWorkspace.shared.open(url) }
    }

    @objc private func togglePauseFromMenu() { togglePause() }

    @objc private func finishFromMenu() { stopRecordingAndProcess() }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.logPath))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
