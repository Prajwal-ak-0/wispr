import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct MeetingChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var activeMeeting: MeetingRecord?
    @Published var lastError: String?
    @Published var chatMessages: [MeetingChatMessage] = []
    @Published var isAnswering = false
    @Published private(set) var providerConnections: [MeetingSummaryProvider: Bool] = [:]
    @Published private(set) var isCheckingProviders = false
    var onActivity: ((MeetingActivity) -> Void)?

    private let store = MeetingStore.shared
    private let recorder = MeetingAudioRecorder()
    private let transcription = MeetingTranscriptionService()
    private let llm = MeetingLLMService()
    private var dashboard: MeetingDashboardController?
    private var stopTask: Task<Void, Never>?
    private var isStartingCapture = false
    private var cleanupTimer: Timer?

    var provider: MeetingSummaryProvider {
        get { MeetingSummaryProvider(rawValue: UserDefaults.standard.string(forKey: "meetingSummaryProvider") ?? "") ?? .codex }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetingSummaryProvider"); objectWillChange.send() }
    }
    var retentionDays: Int {
        get { max(1, UserDefaults.standard.object(forKey: "meetingRetentionDays") as? Int ?? 30) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "meetingRetentionDays"); objectWillChange.send() }
    }
    var automaticallyGenerateSummary: Bool {
        get { UserDefaults.standard.object(forKey: "automaticallyGenerateMeetingSummary") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticallyGenerateMeetingSummary"); objectWillChange.send() }
    }
    func model(for provider: MeetingSummaryProvider) -> String {
        UserDefaults.standard.string(forKey: provider.modelDefaultsKey).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
    }
    func setModel(_ model: String, for provider: MeetingSummaryProvider) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.modelDefaultsKey)
        objectWillChange.send()
    }
    func isProviderConnected(_ provider: MeetingSummaryProvider) -> Bool { providerConnections[provider] == true }

    init() {
        store.cleanup(retentionDays: retentionDays)
        reload()
        recoverInterruptedMeetings()
        Task { await refreshProviderConnections() }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCleanup() }
        }
    }

    func showDashboard() {
        if dashboard == nil { dashboard = MeetingDashboardController(coordinator: self) }
        dashboard?.show()
    }

    func reload() { meetings = store.loadAll() }

    func start(title: String = "Audio note", source: String = "manual") {
        guard activeMeeting == nil, stopTask == nil, !isStartingCapture else {
            Log.info("meeting start ignored while another meeting lifecycle is active")
            return
        }
        isStartingCapture = true
        Task { await startCapture(title: title, source: source) }
    }

    private func startCapture(title: String, source: String) async {
        defer { isStartingCapture = false }
        onActivity?(.starting(title))
        var meeting = MeetingRecord(id: UUID(), title: title, startedAt: Date(), endedAt: nil,
                                    status: .recording, source: source, systemAudioPaths: [],
                                    microphoneAudioPaths: [], transcript: "", summary: "",
                                    summaryProvider: nil, error: nil, isPinned: false)
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw NSError(domain: "Murmur.MeetingPermission", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Allow Murmur under Privacy & Security → Screen & System Audio Recording, then relaunch Murmur."])
            }
            let directory = try store.meetingDirectory(id: meeting.id)
            try store.save(meeting)
            activeMeeting = meeting
            reload()
            try await recorder.start(directory: directory)
            onActivity?(.recording(title))
            Log.info("meeting started: \(meeting.id) from \(source)")
        } catch {
            meeting.status = .failed
            meeting.error = error.localizedDescription
            try? store.save(meeting)
            activeMeeting = nil
            lastError = error.localizedDescription
            onActivity?(.failed(error.localizedDescription))
            reload()
            Log.error("meeting start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard stopTask == nil, activeMeeting != nil else { return }
        stopTask = Task { [weak self] in
            await self?.finishCapture()
            self?.stopTask = nil
        }
    }

    private func finishCapture() async {
        guard var meeting = activeMeeting else { return }
        activeMeeting = nil
        let artifacts = await recorder.stop()
        meeting.endedAt = Date()
        meeting.systemAudioPaths = artifacts.system.map(\.path)
        meeting.microphoneAudioPaths = artifacts.microphone.map(\.path)
        meeting.status = .transcribing
        onActivity?(.transcribing(meeting.title))
        try? store.save(meeting)
        reload()

        do {
            meeting.transcript = try await transcription.transcribe(
                system: artifacts.system, microphone: artifacts.microphone)
            meeting.status = .ready
            if meeting.transcript.isEmpty { meeting.error = "No speech was detected" }
            try store.save(meeting)
            onActivity?(.ready(meeting.title))
            Log.info("meeting transcription ready: \(meeting.id)")
            if automaticallyGenerateSummary, !meeting.transcript.isEmpty, await llm.isConfigured(provider) {
                do {
                    meeting.summary = try await llm.summarize(transcript: meeting.transcript, provider: provider)
                    meeting.summaryProvider = provider
                    meeting.error = nil
                    try store.save(meeting)
                    Log.info("meeting brief generated automatically: \(meeting.id)")
                } catch {
                    Log.error("automatic meeting brief failed without affecting transcript: \(error.localizedDescription)")
                }
            }
        } catch {
            meeting.status = .failed
            meeting.error = error.localizedDescription
            onActivity?(.failed(error.localizedDescription))
            try? store.save(meeting)
            Log.error("meeting transcription failed: \(error.localizedDescription)")
        }
        reload()
    }

    func summarize(_ meeting: MeetingRecord) {
        guard !meeting.transcript.isEmpty else { return }
        Task {
            do {
                guard await llm.isConfigured(provider) else {
                    lastError = "Connect \(provider.shortName) in AI Providers before creating a brief."
                    return
                }
                var updated = meeting
                updated.summary = try await llm.summarize(transcript: meeting.transcript, provider: provider)
                updated.summaryProvider = provider
                updated.error = nil
                try store.save(updated)
                reload()
            } catch {
                lastError = error.localizedDescription
                Log.error("meeting summary failed: \(error.localizedDescription)")
            }
        }
    }

    func ask(_ question: String, about meeting: MeetingRecord) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !meeting.transcript.isEmpty, !isAnswering else { return }
        isAnswering = true
        chatMessages.append(MeetingChatMessage(role: .user, text: question))
        Task {
            defer { isAnswering = false }
            do {
                guard await llm.isConfigured(provider) else {
                    lastError = "Connect \(provider.shortName) in AI Providers before asking Murmur."
                    return
                }
                let answer = try await llm.answer(question: question, transcript: meeting.transcript, provider: provider)
                chatMessages.append(MeetingChatMessage(role: .assistant, text: answer))
            }
            catch { lastError = error.localizedDescription }
        }
    }

    func clearChat() { chatMessages = [] }

    func delete(_ meeting: MeetingRecord) {
        do { try store.delete(meeting); reload() }
        catch { lastError = error.localizedDescription }
    }

    func delete(ids: Set<UUID>) {
        for meeting in meetings where ids.contains(meeting.id) {
            do { try store.delete(meeting) }
            catch { lastError = error.localizedDescription }
        }
        reload()
    }

    func setPinned(_ pinned: Bool, meeting: MeetingRecord) {
        var updated = meeting
        updated.isPinned = pinned
        try? store.save(updated)
        reload()
    }

    func runCleanup() { store.cleanup(retentionDays: retentionDays); reload() }

    func refreshProviderConnections() async {
        isCheckingProviders = true
        for item in MeetingSummaryProvider.allCases { providerConnections[item] = await llm.isConfigured(item) }
        isCheckingProviders = false
    }

    var hasSystemAudioPermission: Bool { CGPreflightScreenCaptureAccess() }

    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func recoverInterruptedMeetings() {
        for var meeting in meetings where meeting.status == .recording {
            meeting.status = .failed
            meeting.endedAt = meeting.endedAt ?? Date()
            meeting.error = "Murmur stopped before this recording was finalized. Audio chunks were preserved."
            let directory = store.rootURL.appendingPathComponent(meeting.id.uuidString)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []
            meeting.systemAudioPaths = files.filter { $0.lastPathComponent.hasPrefix("system-") }.map(\.path).sorted()
            meeting.microphoneAudioPaths = files.filter { $0.lastPathComponent.hasPrefix("microphone-") }.map(\.path).sorted()
            try? store.save(meeting)
        }
        reload()
    }
}

private final class MeetingDashboardController {
    private let window: NSWindow

    @MainActor init(coordinator: MeetingCoordinator) {
        let root = MeetingDashboardView(coordinator: coordinator)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Murmur"
        window.minSize = NSSize(width: 940, height: 620)
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
