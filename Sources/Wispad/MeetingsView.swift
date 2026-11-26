import AppKit
import SwiftUI
import WispadCore

/// Onglet « Réunions » (style Granola, sans bot) intégré dans l'écran Dictées :
/// capture micro + audio système, prise de notes rapides en direct, transcription par les clés existantes,
/// synthèse Markdown IA et synchronisation texte seul chiffrée.
struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var editorTab: EditorTab = .notes
    @State private var recorder = MeetingAudioRecorder()
    @State private var isRecording = false
    @State private var recordingMode: MeetingAudioRecorder.SourceMode = .micOnly
    @State private var includeSystemAudio = true
    @State private var recordingStartedAt: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var isTranscribing = false
    @State private var isEnhancing = false
    @State private var feedbackMessage: String?

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
                .frame(width: 248)
            Rectangle().fill(Theme.cardBorder).frame(width: 1)
            if let meeting = selectedMeeting {
                meetingEditor(meeting)
            } else {
                emptyDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isRecording) {
            guard isRecording else { return }
            while !Task.isCancelled && isRecording {
                if let start = recordingStartedAt {
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
            .padding(12)
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
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.meetings) { meeting in
                            let isSelected = selectedMeeting?.id == meeting.id
                            Button {
                                selectedID = meeting.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(meeting.title.isEmpty ? String(localized: "Réunion sans titre") : meeting.title)
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
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
        let bindingTitle = Binding<String>(
            get: { meeting.title },
            set: { updated in
                var copy = meeting
                copy.title = updated
                copy.updatedAt = Date()
                model.saveMeeting(copy)
            }
        )
        let bindingNotes = Binding<String>(
            get: { meeting.userNotes },
            set: { updated in
                var copy = meeting
                copy.userNotes = updated
                copy.updatedAt = Date()
                model.saveMeeting(copy)
            }
        )
        let bindingEnhanced = Binding<String>(
            get: { meeting.enhancedNotes },
            set: { updated in
                var copy = meeting
                copy.enhancedNotes = updated
                copy.updatedAt = Date()
                model.saveMeeting(copy)
            }
        )
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField(String(localized: "Titre de la réunion"), text: bindingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    recordControls(for: meeting)
                }
                HStack(spacing: 10) {
                    PillPicker(options: EditorTab.allCases, selection: $editorTab, title: \.title)
                    Spacer()
                    if isRecording {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.brand).frame(width: 6, height: 6)
                            Text(formatTimer(elapsedSeconds))
                                .font(.system(size: 11, design: .monospaced))
                            Text(recordingMode == .micAndSystem
                                 ? String(localized: "Micro + Audio système")
                                 : String(localized: "Micro"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else if isTranscribing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Transcription en cours…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if !isRecording {
                        Toggle(String(localized: "Audio système"), isOn: $includeSystemAudio)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let msg = feedbackMessage {
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
                            if meeting.userNotes.isEmpty {
                                Text("Note tes points clés ici pendant la réunion (puces, décisions, noms propres)…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(21)
                                    .allowsHitTesting(false)
                            }
                        }
                case .enhanced:
                    if meeting.enhancedNotes.isEmpty {
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
                    Task { await enhance(meeting) }
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
                .disabled(isEnhancing || (meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                Button {
                    let text = meeting.enhancedNotes.isEmpty ? meeting.userNotes : meeting.enhancedNotes
                    model.copy(text)
                } label: {
                    Label(String(localized: "Copier"), systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(meeting.enhancedNotes.isEmpty && meeting.userNotes.isEmpty)

                Spacer()

                Button(role: .destructive) {
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

    private func recordControls(for meeting: MeetingRecord) -> some View {
        Button {
            if isRecording {
                stopRecording(for: meeting)
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRecording ? Color.white : Theme.brand)
                    .frame(width: 6.5, height: 6.5)
                Text(isRecording ? String(localized: "Arrêter") : String(localized: "Enregistrer"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isRecording ? Color.white : Color.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(isRecording ? Theme.brand : Theme.subtleFill))
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
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

    private func createMeeting() {
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
        editorTab = .notes
        feedbackMessage = nil
    }

    private func startRecording() {
        feedbackMessage = nil
        let dir = model.supportURL.appendingPathComponent("MeetingsAudio", isDirectory: true)
        do {
            let started = try recorder.start(directory: dir, includeSystemAudio: includeSystemAudio)
            recordingMode = started.mode
            recordingStartedAt = Date()
            elapsedSeconds = 0
            isRecording = true
        } catch {
            feedbackMessage = error.localizedDescription
        }
    }

    private func stopRecording(for meeting: MeetingRecord) {
        let result = recorder.stop()
        isRecording = false
        recordingStartedAt = nil
        guard let url = result.url else { return }
        let speech = model.speechRequest(context: nil)
        guard !speech.apiKey.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            feedbackMessage = String(localized: "Ajoute une clé API (xAI ou OpenAI) dans Fournisseurs pour transcrire.")
            return
        }
        isTranscribing = true
        feedbackMessage = nil
        let duration = result.duration
        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: url)
                isTranscribing = false
            }
            do {
                let transcriptText = try await BatchTranscriber.transcribe(fileURL: url, request: speech)
                var updated = model.meetings.first(where: { $0.id == meeting.id }) ?? meeting
                updated.durationSeconds += duration
                let piece = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    updated.rawTranscript = updated.rawTranscript.isEmpty ? piece : (updated.rawTranscript + "\n\n" + piece)
                }
                updated.updatedAt = Date()
                model.saveMeeting(updated)
                feedbackMessage = String(localized: "Transcription terminée (l'audio temporaire a été supprimé).")
            } catch {
                feedbackMessage = String(localized: "Échec de la transcription : vérifie ta clé ou ta connexion.")
            }
        }
    }

    private func enhance(_ meeting: MeetingRecord) async {
        let speech = model.speechRequest(context: nil)
        isEnhancing = true
        feedbackMessage = nil
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
        guard !cleaned.isEmpty else {
            feedbackMessage = String(localized: "Aucune synthèse reçue : vérifie tes clés de correction dans Fournisseurs.")
            return
        }
        var updated = model.meetings.first(where: { $0.id == meeting.id }) ?? meeting
        updated.enhancedNotes = cleaned
        updated.updatedAt = Date()
        model.saveMeeting(updated)
        editorTab = .enhanced
        feedbackMessage = String(localized: "Synthèse IA enregistrée et prête à synchroniser.")
    }

    private func formatTimer(_ total: Int) -> String {
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
