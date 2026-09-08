import AppKit
import SwiftUI

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case transcript = "Transcript"
    case ask = "Ask Murmur"
    var id: String { rawValue }
}

struct MeetingDashboardView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var showingSettings = false
    @State private var question = ""
    @State private var detailTab: MeetingDetailTab = .overview
    @State private var showRawTranscript = false
    @State private var geminiKey = MeetingCredentials.geminiAPIKey
    @State private var vertexCredentials = UserDefaults.standard.string(forKey: "vertexCredentialsPath") ?? ""
    @State private var vertexProject = UserDefaults.standard.string(forKey: "vertexProject") ?? ""
    @State private var vertexLocation = UserDefaults.standard.string(forKey: "vertexLocation") ?? "global"
    @State private var settingsSection = 0
    @State private var copiedItem: String?
    @State private var hoveredMeetingID: UUID?
    @State private var clock = Date()
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var filtered: [MeetingRecord] {
        guard !search.isEmpty else { return coordinator.meetings }
        return coordinator.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.transcript.localizedCaseInsensitiveContains(search)
        }
    }
    private var selected: MeetingRecord? {
        let id = selection.count == 1 ? selection.first : nil
        return coordinator.meetings.first { $0.id == id } ?? coordinator.meetings.first
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                header
                List(filtered, selection: $selection) { meeting in
                    meetingRow(meeting).tag(meeting.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 292, max: 340)
        } detail: {
            if selection.count > 1 { bulkSelection }
            else if let meeting = selected { detail(meeting) }
            else { emptyState }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .tint(Color(red: 0.20, green: 0.72, blue: 0.42))
        .sheet(isPresented: $showingSettings) { settings }
        .alert("Murmur", isPresented: Binding(get: { coordinator.lastError != nil },
            set: { if !$0 { coordinator.lastError = nil } })) {
            Button("OK") { coordinator.lastError = nil }
        } message: { Text(coordinator.lastError ?? "") }
        .onAppear { if selection.isEmpty, let id = coordinator.meetings.first?.id { selection = [id] } }
        .onChange(of: coordinator.activeMeeting?.id) { _, activeID in
            if let activeID { selection = [activeID] }
        }
        .onChange(of: selection) { _, _ in
            detailTab = .overview
            question = ""
            coordinator.clearChat()
        }
        .onReceive(clockTimer) { clock = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(.green)
                        Text("Murmur").font(.system(size: 20, weight: .semibold, design: .rounded))
                    }
                    Text("Private meeting memory").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Meeting settings")
            }
            TextField("Search meetings", text: $search)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("MEETINGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(coordinator.meetings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if selection.count > 1 {
                HStack {
                    Text("\(selection.count) selected").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { coordinator.delete(ids: selection); selection.removeAll() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(.borderless)
                }.padding(.horizontal, 2)
            } else if coordinator.activeMeeting != nil {
                Button { coordinator.stop() } label: {
                    Label("Stop recording and transcribe", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button { coordinator.start() } label: {
                    Label("Record audio now", systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).help("Record your Mac audio and microphone until you press Stop")
            }
        }.padding(16)
    }

    private func meetingRow(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                HStack(spacing: 8) {
                    Button { coordinator.setPinned(!meeting.isPinned, meeting: meeting) } label: { Image(systemName: meeting.isPinned ? "pin.fill" : "pin").font(.caption2) }.buttonStyle(.borderless).help(meeting.isPinned ? "Unpin" : "Pin")
                    Button(role: .destructive) { coordinator.delete(meeting) } label: { Image(systemName: "trash").font(.caption2) }.buttonStyle(.borderless).help("Delete")
                }.opacity(hoveredMeetingID == meeting.id || selection.contains(meeting.id) || meeting.isPinned ? 1 : 0)
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor(meeting.status)).frame(width: 6, height: 6)
                Text(meeting.startedAt, style: .date)
                Text("·")
                Text(duration(liveDuration(meeting)))
                if let endedAt = meeting.endedAt { Text("· Ended \(endedAt.formatted(date: .omitted, time: .shortened))") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5).contentShape(Rectangle()).onHover { hoveredMeetingID = $0 ? meeting.id : nil }
    }

    private func detail(_ meeting: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            detailHeader(meeting)
            Divider()
            switch detailTab {
            case .overview: overview(meeting)
            case .transcript: transcript(meeting)
            case .ask: askMurmur(meeting)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func detailHeader(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor(meeting.status)).frame(width: 7, height: 7)
                        Text(meeting.status.rawValue.capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(meeting.title).font(.system(size: 30, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text("Started \(meeting.startedAt.formatted(date: .long, time: .shortened))   ·   Ended \(meeting.endedAt?.formatted(date: .omitted, time: .shortened) ?? "—")   ·   \(duration(liveDuration(meeting)))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { coordinator.setPinned(!meeting.isPinned, meeting: meeting) } label: {
                    Image(systemName: meeting.isPinned ? "pin.fill" : "pin")
                }.buttonStyle(.borderless).help(meeting.isPinned ? "Unpin" : "Keep beyond retention period")
                Button(role: .destructive) { coordinator.delete(meeting) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete meeting and audio")
            }
            Picker("Meeting section", selection: $detailTab) {
                ForEach(MeetingDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 430)
        }.padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 24)
    }

    private func overview(_ meeting: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if meeting.status == .recording || meeting.status == .transcribing { processing(meeting) }
                HStack(spacing: 0) {
                    metric("Duration", duration(liveDuration(meeting)))
                    Divider().frame(height: 38).padding(.horizontal, 28)
                    metric("Words", "\(meeting.transcript.split(whereSeparator: \.isWhitespace).count)")
                    Divider().frame(height: 38).padding(.horizontal, 28)
                    metric("Source", meeting.source == "google-meet" ? "Google Meet" : "Manual")
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Meeting brief", systemImage: "sparkles").font(.title3.weight(.semibold))
                        Spacer()
                        if !meeting.summary.isEmpty {
                            Text(meeting.summaryProvider?.rawValue ?? "AI").font(.caption).foregroundStyle(.secondary)
                            copyButton(meeting.summary, label: "summary")
                        }
                    }
                    if !meeting.summary.isEmpty {
                        MeetingBriefView(markdown: meeting.summary)
                    } else if meeting.status == .ready && !meeting.transcript.isEmpty {
                        if coordinator.isProviderConnected(coordinator.provider) {
                            Text("Turn the transcript into decisions, action items, and open questions.").foregroundStyle(.secondary)
                            Button { coordinator.summarize(meeting) } label: {
                                Label("Create brief with \(coordinator.provider.shortName)", systemImage: "sparkles")
                            }.buttonStyle(.borderedProminent).tint(.green)
                        } else {
                            Label("Connect an AI provider to create a meeting brief", systemImage: "link.badge.plus")
                                .foregroundStyle(.secondary)
                            Button("Open AI Providers") { settingsSection = 1; showingSettings = true }.buttonStyle(.bordered)
                        }
                    } else {
                        Text(meeting.error ?? "The meeting brief will appear after transcription.").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 44).padding(.vertical, 30).frame(maxWidth: 940, alignment: .leading)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 15, weight: .medium))
        }
    }

    private func transcript(_ meeting: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Full transcript").font(.headline)
                if let engine = meeting.transcriptEngine {
                    Text(engine).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule()).foregroundStyle(.secondary)
                }
                Spacer()
                if let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: { Label("Audio", systemImage: "waveform") }
                        .buttonStyle(.borderless)
                        .help("Reveal \(URL(fileURLWithPath: path).lastPathComponent) in Finder")
                }
                if meeting.structured?.utterances.isEmpty == false {
                    Picker("View", selection: $showRawTranscript) {
                        Text("Speakers").tag(false); Text("Raw").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                copyButton(meeting.transcript, label: "transcript")
            }.padding(.horizontal, 44).frame(height: 52)
            Divider()
            // A finished meeting can still carry a note — most often "Gemini was unreachable, this
            // was transcribed on-device" — which would otherwise be invisible once status is ready.
            if meeting.status == .ready, let note = meeting.error, !note.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 44).padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
                Divider()
            }
            if let structured = meeting.structured, !structured.utterances.isEmpty, !showRawTranscript {
                StructuredTranscriptView(transcript: structured)
            } else {
                SelectableTranscriptView(text: meeting.transcript.isEmpty ? (meeting.error ?? "No transcript yet") : meeting.transcript,
                                         isPlaceholder: meeting.transcript.isEmpty)
            }
        }
    }

    private func askMurmur(_ meeting: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if coordinator.chatMessages.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 34, weight: .light)).foregroundStyle(.green)
                                Text("Ask anything from this meeting").font(.title3.weight(.semibold))
                                Text("Answers use only the transcript and cite timestamps.").foregroundStyle(.secondary)
                                HStack {
                                    suggestion("What decisions were made?", meeting)
                                    suggestion("List the action items", meeting)
                                }
                            }.padding(.top, 72)
                        }
                        ForEach(coordinator.chatMessages) { message in chatBubble(message).id(message.id) }
                        if coordinator.isAnswering { HStack { ProgressView(); Text("Reading the transcript…").foregroundStyle(.secondary); Spacer() } }
                    }.padding(30).frame(maxWidth: 820)
                }.onChange(of: coordinator.chatMessages.count) { _, _ in
                    if let last = coordinator.chatMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Ask about decisions, owners, or context…", text: $question)
                    .textFieldStyle(.plain).font(.system(size: 14)).onSubmit { submitQuestion(meeting) }
                Button { submitQuestion(meeting) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isAnswering)
            }.padding(.horizontal, 18).frame(height: 54).background(.regularMaterial)
        }
    }

    private func suggestion(_ text: String, _ meeting: MeetingRecord) -> some View {
        Button(text) { question = text; submitQuestion(meeting) }.buttonStyle(.bordered)
    }

    private func submitQuestion(_ meeting: MeetingRecord) {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        coordinator.ask(value, about: meeting); question = ""
    }

    private func chatBubble(_ message: MeetingChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 90) }
            VStack(alignment: .trailing, spacing: 5) {
                Text(.init(message.text)).textSelection(.enabled).padding(.horizontal, 15).padding(.vertical, 11)
                    .background(message.role == .user ? Color.green.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 14))
                if message.role == .assistant { copyButton(message.text, label: "answer") }
            }
            if message.role == .assistant { Spacer(minLength: 90) }
        }
    }

    private func processing(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading) {
                Text(meeting.status == .recording ? "Recording locally" : "Transcribing on this Mac")
                    .font(.headline)
                Text(meeting.status == .recording ? "System audio and your microphone are stored separately." : "Audio never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.green.opacity(0.10)).frame(width: 112, height: 112)
                Image(systemName: "waveform.and.mic").font(.system(size: 42, weight: .light)).foregroundStyle(.green)
            }
            VStack(spacing: 7) {
                Text("Your meetings, remembered privately").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Join Google Meet in Arc or start a recording here.\nAudio and transcription stay on this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
            }
            Button { coordinator.start() } label: { Label("Start recording", systemImage: "record.circle") }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var bulkSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
            Text("\(selection.count) meetings selected").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Use Command-click in the sidebar to add or remove meetings from this selection.").foregroundStyle(.secondary)
            Button(role: .destructive) { coordinator.delete(ids: selection); selection.removeAll() } label: { Label("Delete selected meetings", systemImage: "trash") }.buttonStyle(.borderedProminent)
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.title2.weight(.semibold)); Spacer(); Button("Done") { saveSettings() }.keyboardShortcut(.defaultAction) }
                .padding(24)
            Picker("Settings section", selection: $settingsSection) {
                Text("General").tag(0); Text("AI Providers").tag(1)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                if settingsSection == 0 { generalSettings } else { providerSettings }
            }
        }.frame(width: 620, height: 650)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsCard("Automation", icon: "bolt.fill") {
                Label("Google Meet always asks before recording", systemImage: "hand.raised.fill").foregroundStyle(.green)
                Text("A \(Int(Config.meetOfferSeconds))-second prompt appears when you join. Choose Record to start; dismiss it or let it time out to skip recording.").font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically create an AI brief after transcription", isOn: Binding(get: { coordinator.automaticallyGenerateSummary }, set: { coordinator.automaticallyGenerateSummary = $0 }))
            }
            settingsCard("Audio & speakers", icon: "waveform") {
                Label(coordinator.hasSystemAudioPermission ? "System audio access granted" : "System audio access needed", systemImage: coordinator.hasSystemAudioPermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(coordinator.hasSystemAudioPermission ? .green : .orange)
                Text(MeetingAudioExporter.ffmpegPath() == nil
                     ? "Every meeting is mixed into one audio file (.m4a — install ffmpeg for .mp3)."
                     : "Every meeting is mixed into one .mp3 you can play or share.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsCard("Transcription", icon: "text.bubble") {
                Picker("Engine", selection: Binding(get: { coordinator.transcriptionEngine },
                                                    set: { coordinator.transcriptionEngine = $0 })) {
                    ForEach(MeetingTranscriptionEngine.allCases) { engine in Text(engine.rawValue).tag(engine) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(coordinator.transcriptionEngine.detail).font(.caption).foregroundStyle(.secondary)
                if coordinator.transcriptionEngine == .gemini {
                    HStack {
                        Text("Model").foregroundStyle(.secondary)
                        Picker("Transcription model", selection: Binding(get: { coordinator.transcriptionModel },
                                                                        set: { coordinator.transcriptionModel = $0 })) {
                            ForEach(MeetingSummaryProvider.gemini.modelOptions, id: \.id) { option in
                                Text(option.label).tag(option.id)
                            }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Label(coordinator.isGeminiTranscriptionReady ? "Vertex service account found" : "Vertex service-account JSON not found — meetings fall back to on-device",
                          systemImage: coordinator.isGeminiTranscriptionReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(coordinator.isGeminiTranscriptionReady ? .green : .orange)
                    Text("Set the credentials path under AI Providers → Gemini. On-device transcription is always the fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingsCard("Storage", icon: "internaldrive") {
                Stepper("Delete unpinned meetings after \(coordinator.retentionDays) days", value: Binding(get: { coordinator.retentionDays }, set: { coordinator.retentionDays = $0 }), in: 1...365)
            }
        }.padding(24)
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading) { Text("Choose your meeting intelligence").font(.title3.weight(.semibold)); Text("Your transcript is sent only when you request AI features.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { Task { await coordinator.refreshProviderConnections() } } label: { Image(systemName: "arrow.clockwise") }.disabled(coordinator.isCheckingProviders) }
            ForEach(MeetingSummaryProvider.allCases) { item in providerCard(item) }
        }.padding(24)
    }

    private func providerCard(_ item: MeetingSummaryProvider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: item == .codex ? "sparkles" : item == .claude ? "brain.head.profile" : "diamond.fill").frame(width: 24).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) { Text(item.shortName).font(.headline); Label(coordinator.isProviderConnected(item) ? "Connected" : "Not connected", systemImage: coordinator.isProviderConnected(item) ? "checkmark.circle.fill" : "circle.dashed").font(.caption).foregroundStyle(coordinator.isProviderConnected(item) ? .green : .secondary) }
                Spacer()
                Button(coordinator.provider == item ? "Selected" : "Use provider") { coordinator.provider = item }.buttonStyle(.borderedProminent).tint(coordinator.provider == item ? .green : .gray)
            }
            HStack {
                Text("Model").foregroundStyle(.secondary)
                Picker("Model", selection: Binding(get: { coordinator.model(for: item) }, set: { coordinator.setModel($0, for: item) })) {
                    ForEach(item.modelOptions, id: \.id) { option in Text(option.label).tag(option.id) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                Text("Medium effort").font(.caption).foregroundStyle(.secondary)
            }
            if item == .codex { Text("Uses your Codex ChatGPT login · medium reasoning").font(.caption).foregroundStyle(.secondary) }
            if item == .claude { Text("Uses your Claude CLI login. Run `claude login` once if disconnected.").font(.caption).foregroundStyle(.secondary) }
            if item == .gemini {
                SecureField("Gemini API key", text: $geminiKey).textFieldStyle(.roundedBorder)
                TextField("Vertex service-account JSON path", text: $vertexCredentials).textFieldStyle(.roundedBorder)
                HStack { TextField("Vertex project", text: $vertexProject); TextField("Location", text: $vertexLocation) }.textFieldStyle(.roundedBorder)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(coordinator.provider == item ? Color.green.opacity(0.55) : Color.primary.opacity(0.08)))
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: icon).font(.headline); content() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func saveSettings() {
        MeetingCredentials.geminiAPIKey = geminiKey
        UserDefaults.standard.set(vertexCredentials, forKey: "vertexCredentialsPath")
        UserDefaults.standard.set(vertexProject, forKey: "vertexProject")
        UserDefaults.standard.set(vertexLocation, forKey: "vertexLocation")
        coordinator.runCleanup(); Task { await coordinator.refreshProviderConnections() }; showingSettings = false
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            copiedItem = label
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if copiedItem == label { copiedItem = nil } }
        } label: { Label(copiedItem == label ? "Copied" : "Copy", systemImage: copiedItem == label ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).foregroundStyle(copiedItem == label ? .green : .secondary).disabled(text.isEmpty)
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status { case .recording: return .red; case .transcribing: return .orange; case .ready: return .green; case .failed: return .gray }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    private func liveDuration(_ meeting: MeetingRecord) -> TimeInterval {
        (meeting.endedAt ?? clock).timeIntervalSince(meeting.startedAt)
    }
}

// Speaker-attributed transcript: one block per utterance, tinted and named per voice, so a reader
// can follow who said what instead of a wall of "You / Others".
private struct StructuredTranscriptView: View {
    let transcript: MeetingStructuredTranscript

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]
    private func color(_ speakerId: String) -> Color {
        guard let speaker = transcript.speaker(speakerId) else { return .gray }
        return Self.palette[speaker.colorIndex % Self.palette.count]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                speakerLegend
                ForEach(transcript.utterances) { utterance in
                    HStack(alignment: .top, spacing: 14) {
                        Text(utterance.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary).frame(width: 62, alignment: .leading).padding(.top, 3)
                        RoundedRectangle(cornerRadius: 2).fill(color(utterance.speakerId).opacity(0.6)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transcript.name(for: utterance.speakerId))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color(utterance.speakerId))
                            Text(utterance.text).font(.system(size: 13.5)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }.padding(.horizontal, 44).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speakerLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(transcript.speakers.count) speakers · \(transcript.utterances.count) turns")
                .font(.caption).foregroundStyle(.secondary)
            FlowRow {
                ForEach(transcript.speakers) { speaker in
                    HStack(spacing: 6) {
                        Circle().fill(Self.palette[speaker.colorIndex % Self.palette.count]).frame(width: 8, height: 8)
                        Text(transcript.name(for: speaker.id)).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    // Names are inferred from what was said aloud, so the evidence stays inspectable.
                    .help(speaker.evidence.map { "Named from: \u{201C}\($0)\u{201D}" } ?? "Name not spoken in the meeting")
                }
            }
        }.padding(.bottom, 4)
    }
}

// Wraps speaker chips onto as many lines as they need.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximum = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximum { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maximum == .infinity ? x : maximum, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct SelectableTranscriptView: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = TranscriptTextView()
        view.isEditable = false
        view.isSelectable = true
        view.allowsUndo = false
        view.drawsBackground = false
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 42, height: 28)
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TranscriptTextView, view.string != text else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style
        ]))
        DispatchQueue.main.async {
            TranscriptTextView.active = view
            view.window?.makeFirstResponder(view)
        }
    }
}

final class TranscriptTextView: NSTextView {
    static weak var active: TranscriptTextView?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        Self.active = self
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRange().length > 0 }
        if item.action == #selector(performFindPanelAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c":
            copySelectedText()
            return true
        case "f":
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(sender)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func copy(_ sender: Any?) { copySelectedText() }

    func copySelectedText() {
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0,
              let swiftRange = Range(range, in: string) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(string[swiftRange]), forType: .string)
    }

    func showFindInterface() {
        let sender = NSMenuItem()
        sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(sender)
    }
}

private struct MeetingBriefView: View {
    let markdown: String
    private var lines: [String] { markdown.components(separatedBy: .newlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(.system(size: 16, weight: .semibold)).padding(.top, 10)
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(.secondary).frame(width: 4, height: 4)
                        Text(.init(String(line.dropFirst(2)))).textSelection(.enabled)
                    }
                } else if line.isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    Text(.init(line)).textSelection(.enabled).lineSpacing(3)
                }
            }
        }
    }
}
