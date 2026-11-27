import AppKit
import SwiftUI
import WispadCore

/// Onglet « Réunions » (style Granola, sans bot) intégré dans l'écran Dictées :
/// capture micro + audio système (gérée par `AppModel` pour survivre au changement d'onglet),
/// prise de notes rapides en direct (sauvegarde groupée), transcription par morceaux,
/// synthèse Markdown IA et synchronisation texte seul chiffrée.
struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var editorTab: EditorTab = .notes
    @State private var includeSystemAudio = true
    @State private var elapsedSeconds: Int = 0
    @State private var isEnhancing = false

    // Tampons locaux d'édition : évite d'écrire SQLite et de relancer la synchro à chaque touche.
    @State private var loadedMeetingID: String?
    @State private var draftTitle = ""
    @State private var draftNotes = ""
    @State private var draftEnhanced = ""
    @State private var draftDirty = false
    @State private var saveTask: Task<Void, Never>?

    enum EditorTab: String, CaseIterable, Identifiable {
        case notes
        case enhanced
        case transcript

        var id: String { rawValue }
        var title: String {
            switch self {
            case .notes: return String(localized: "Notes rapides")
            case .enhanced: return String(localized: "Synthèse IA")
            case .transcript: return String(localized: "Transcription")
            }
        }
    }

    private var selectedMeeting: MeetingRecord? {
        if let id = selectedID, let found = model.meetings.first(where: { $0.id == id }) {
            return found
        }
        return model.meetings.first
    }

    var body: some View {
        HStack(spacing: 0) {
            meetingList
                .frame(width: 210)
            Rectangle().fill(Theme.cardBorder).frame(width: 1)
            if let meeting = selectedMeeting {
                meetingEditor(meeting)
            } else {
                emptyDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let m = selectedMeeting { loadDraft(from: m) }
        }
        .onChange(of: selectedMeeting?.id) { _, newID in
            flushDraft()
            if let id = newID, let m = model.meetings.first(where: { $0.id == id }) {
                loadDraft(from: m)
            } else {
                loadedMeetingID = nil
            }
        }
        .onChange(of: selectedMeeting?.updatedAt) { _, _ in
            if !draftDirty, let m = selectedMeeting, m.id == loadedMeetingID {
                draftTitle = m.title
                draftNotes = m.userNotes
                draftEnhanced = m.enhancedNotes
            }
        }
        .onDisappear {
            flushDraft()
        }
        .task(id: model.isRecordingMeeting) {
            guard model.isRecordingMeeting else { elapsedSeconds = 0; return }
            while !Task.isCancelled && model.isRecordingMeeting {
                if let start = model.recordingMeetingStartedAt {
                    elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    createMeeting()
                } label: {
                    Label(String(localized: "Nouvelle réunion"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            Rectangle().fill(Theme.cardBorder).frame(height: 1)
            if model.meetings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Aucune réunion")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Prends des notes rapides et laisse l'IA les enrichir avec la transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.meetings) { meeting in
                            let isSelected = selectedMeeting?.id == meeting.id
                            let isRecordingThis = model.recordingMeetingID == meeting.id
                            Button {
                                flushDraft()
                                selectedID = meeting.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        if isRecordingThis {
                                            Circle().fill(Theme.brand).frame(width: 6, height: 6)
                                        }
                                        Text(meeting.title.isEmpty ? String(localized: "Réunion sans titre") : meeting.title)
                                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 5) {
                                        Text(meeting.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale)))
                                        if let origin = meeting.sourceDeviceName,
                                           meeting.sourceDeviceID != nil,
                                           meeting.sourceDeviceID != model.sync.config.deviceId {
                                            Text("·")
                                            Text(origin)
                                        }
                                    }
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isSelected ? Theme.subtleFill : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func meetingEditor(_ meeting: MeetingRecord) -> some View {
        let isRecordingThis = model.recordingMeetingID == meeting.id
        let isRecordingOther = model.isRecordingMeeting && !isRecordingThis
        let isTranscribingThis = model.transcribingMeetingID == meeting.id
        let hasRetryAudio = model.pendingRetryMeetingAudio[meeting.id] != nil

        let bindingTitle = Binding<String>(
            get: { loadedMeetingID == meeting.id ? draftTitle : meeting.title },
            set: { updated in
                if loadedMeetingID != meeting.id { loadDraft(from: meeting) }
                draftTitle = updated
                scheduleDraftSave()
            }
        )
        let bindingNotes = Binding<String>(
            get: { loadedMeetingID == meeting.id ? draftNotes : meeting.userNotes },
            set: { updated in
                if loadedMeetingID != meeting.id { loadDraft(from: meeting) }
                draftNotes = updated
                scheduleDraftSave()
            }
        )
        let bindingEnhanced = Binding<String>(
            get: { loadedMeetingID == meeting.id ? draftEnhanced : meeting.enhancedNotes },
            set: { updated in
                if loadedMeetingID != meeting.id { loadDraft(from: meeting) }
                draftEnhanced = updated
                scheduleDraftSave()
            }
        )
        let effectiveNotes = loadedMeetingID == meeting.id ? draftNotes : meeting.userNotes
        let effectiveEnhanced = loadedMeetingID == meeting.id ? draftEnhanced : meeting.enhancedNotes
        let copyText: String = {
            switch editorTab {
            case .transcript:
                return meeting.rawTranscript
            case .enhanced:
                return effectiveEnhanced.isEmpty ? effectiveNotes : effectiveEnhanced
            case .notes:
                return effectiveNotes.isEmpty ? effectiveEnhanced : effectiveNotes
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField(String(localized: "Titre de la réunion"), text: bindingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    recordControls(for: meeting, isRecordingThis: isRecordingThis, isRecordingOther: isRecordingOther, isTranscribingThis: isTranscribingThis)
                }
                HStack(spacing: 10) {
                    PillPicker(options: EditorTab.allCases, selection: $editorTab, title: \.title)
                    Spacer()
                    if isRecordingThis {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.brand).frame(width: 6, height: 6)
                            Text(formatTimer(elapsedSeconds))
                                .font(.system(size: 11, design: .monospaced))
                            Text(model.recordingMeetingMode == .micAndSystem
                                 ? String(localized: "Micro + Audio système")
                                 : String(localized: "Micro"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else if isTranscribingThis {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(model.meetingTranscribeProgress ?? String(localized: "Transcription en cours…"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if !model.isRecordingMeeting {
                        Toggle(String(localized: "Audio système"), isOn: $includeSystemAudio)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if hasRetryAudio, !isTranscribingThis {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("L'audio de cette réunion a été conservé après l'échec de transcription.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Réessayer la transcription")) {
                            Task { await model.retryMeetingTranscription(for: meeting.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                }
                if let msg = model.meetingFeedback {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(Theme.cardBorder).frame(height: 1)

            Group {
                switch editorTab {
                case .notes:
                    TextEditor(text: bindingNotes)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .overlay(alignment: .topLeading) {
                            if effectiveNotes.isEmpty {
                                Text("Note tes points clés ici pendant la réunion (puces, décisions, noms propres)…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(21)
                                    .allowsHitTesting(false)
                            }
                        }
                case .enhanced:
                    if effectiveEnhanced.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("Aucune synthèse IA pour le moment")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Enregistre la réunion ou ajoute quelques puces, puis clique sur « Enrichir avec l'IA ».")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 340)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TextEditor(text: bindingEnhanced)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(16)
                    }
                case .transcript:
                    ScrollView {
                        Text(meeting.rawTranscript.isEmpty
                             ? String(localized: "La transcription apparaîtra ici après l'enregistrement.")
                             : meeting.rawTranscript)
                            .font(.system(size: 12.5))
                            .foregroundStyle(meeting.rawTranscript.isEmpty ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }

            Rectangle().fill(Theme.cardBorder).frame(height: 1)

            HStack(spacing: 10) {
                Button {
                    flushDraft()
                    if let fresh = model.meetings.first(where: { $0.id == meeting.id }) {
                        Task { await enhance(fresh) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isEnhancing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Enrichir avec l'IA")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnhancing || (effectiveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                Button {
                    model.copy(copyText)
                } label: {
                    Label(String(localized: "Copier"), systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button(role: .destructive) {
                    saveTask?.cancel()
                    draftDirty = false
                    model.deleteMeeting(meeting)
                    if selectedID == meeting.id { selectedID = model.meetings.first?.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Supprimer cette réunion"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func recordControls(for meeting: MeetingRecord, isRecordingThis: Bool, isRecordingOther: Bool, isTranscribingThis: Bool) -> some View {
        Button {
            flushDraft()
            if isRecordingThis {
                Task { await model.stopMeetingRecording() }
            } else {
                Task { await model.startMeetingRecording(for: meeting.id, includeSystemAudio: includeSystemAudio) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRecordingThis ? Color.white : Theme.brand)
                    .frame(width: 6.5, height: 6.5)
                Text(isRecordingThis ? String(localized: "Arrêter") : String(localized: "Enregistrer"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isRecordingThis ? Color.white : Color.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(isRecordingThis ? Theme.brand : Theme.subtleFill))
        }
        .buttonStyle(.plain)
        .disabled(isTranscribingThis || isRecordingOther || model.transcribingMeetingID != nil)
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Notes de réunion sans bot")
                .font(.system(size: 15, weight: .semibold))
            Text("Capture ta voix et l'audio de l'appel directement sur ton Mac, sans inviter de bot dans Zoom, Meet ou Teams.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(String(localized: "Nouvelle réunion")) {
                createMeeting()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadDraft(from meeting: MeetingRecord) {
        saveTask?.cancel()
        loadedMeetingID = meeting.id
        draftTitle = meeting.title
        draftNotes = meeting.userNotes
        draftEnhanced = meeting.enhancedNotes
        draftDirty = false
    }

    private func scheduleDraftSave() {
        draftDirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushDraft()
        }
    }

    private func flushDraft() {
        saveTask?.cancel()
        saveTask = nil
        guard draftDirty, let id = loadedMeetingID,
              var current = model.meetings.first(where: { $0.id == id }) else {
            draftDirty = false
            return
        }
        draftDirty = false
        guard current.title != draftTitle || current.userNotes != draftNotes || current.enhancedNotes != draftEnhanced else {
            return
        }
        current.title = draftTitle
        current.userNotes = draftNotes
        current.enhancedNotes = draftEnhanced
        current.updatedAt = Date()
        model.saveMeeting(current)
    }

    private func createMeeting() {
        flushDraft()
        let identity = model.sync.deviceIdentity
        let formatted = Date().formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale))
        let meeting = MeetingRecord(
            title: String(localized: "Réunion du \(formatted)"),
            sourceDeviceID: identity.deviceId,
            sourceDeviceName: identity.deviceName,
            sourceDevicePlatform: identity.platform.rawValue
        )
        model.saveMeeting(meeting)
        selectedID = meeting.id
        loadDraft(from: meeting)
        editorTab = .notes
        model.meetingFeedback = nil
    }

    private func enhance(_ meeting: MeetingRecord) async {
        let speech = model.speechRequest(context: nil)
        isEnhancing = true
        model.meetingFeedback = nil
        defer { isEnhancing = false }
        let result = await TextCleaner.enhanceMeeting(
            title: meeting.title,
            userNotes: meeting.userNotes,
            transcript: meeting.rawTranscript,
            language: model.settings.language,
            speech: speech
        )
        if let usage = result.usage { model.recordUsage(usage) }
        for failed in result.failedUsages { model.recordUsage(failed) }
        let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.usage?.succeeded == true, !cleaned.isEmpty else {
            model.meetingFeedback = String(localized: "Aucune synthèse reçue : vérifie tes clés de correction dans Fournisseurs.")
            return
        }
        guard var updated = model.meetings.first(where: { $0.id == meeting.id }) else { return }
        updated.enhancedNotes = cleaned
        updated.updatedAt = Date()
        model.saveMeeting(updated)
        if loadedMeetingID == updated.id {
            draftEnhanced = cleaned
            draftDirty = false
        }
        editorTab = .enhanced
        model.meetingFeedback = String(localized: "Synthèse IA enregistrée et prête à synchroniser.")
    }

    private func formatTimer(_ total: Int) -> String {
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
