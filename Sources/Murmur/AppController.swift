import AppKit
import AVFoundation
import ServiceManagement

// Meeting capture and UI state are main-thread-owned.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var meetingCoordinator: MeetingCoordinator!
    private var meetBridge: MeetBridgeServer!
    private var lastMeetHeartbeat: Date?
    private var meetHeartbeatTimer: Timer?
    private var activeMeetURL: String?
    private var pendingMeetStop: DispatchWorkItem?
    private let meetingActivityPanel = MeetingActivityPanel()
    private var pendingMeetOffer: BrowserMeetEvent?

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
        buildMenu()
        buildApplicationMenu()
        requestPermissions()
        startMeetBridge()
        setStatus("Ready")
        ensureLoginItem()
        if CommandLine.arguments.contains("--dashboard") { meetingCoordinator.showDashboard() }
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
            let offered = event
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.meetOfferSeconds) { [weak self] in
                // Only expire the offer this timer actually armed — a newer join must not be
                // wiped by an older timer.
                guard let self, self.pendingMeetOffer?.url == offered.url else { return }
                self.pendingMeetOffer = nil
            }
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

    // Auto-start so Google Meet detection is available without manual app setup each time.
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

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info("microphone access granted: \(granted)")
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

        menu.addItem(NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Record Meeting", action: #selector(startMeetingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Recording & Transcribe", action: #selector(stopMeetingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Up Google Meet in Arc…", action: #selector(setUpArcExtension), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Microphone Settings…",
                                action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Screen Recording Settings…",
                                action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
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

    @objc private func openMicrophoneSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSystemSettings(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
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

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.logPath))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
