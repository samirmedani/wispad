import SwiftUI
import AppKit
import WispadCore
import UniformTypeIdentifiers

/// Écran réglages : en-tête fixe, formulaire groupé natif dessous.
struct FormScreen<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormScreen(title: String(localized: "Réglages"), subtitle: String(localized: "Raccourci, correction, audio et autorisations.")) {
            Section("Raccourci") {
                DictationShortcutRow()
                PasteShortcutRow()
            }
            Section("Transcription") {
                SettingRow(text: SettingsPresentation.language) {
                    Picker(SettingsPresentation.language.title, selection: Binding(
                        get: { model.settings.language },
                        set: { model.settings.language = $0; model.saveSettings() }
                    )) {
                        ForEach(DictationLanguage.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingToggle(text: SettingsPresentation.verifyWithFile, isOn: Binding(
                    get: { model.settings.verifyWithFile },
                    set: { model.settings.verifyWithFile = $0; model.saveSettings() }
                ))
            }
            Section("Correction") {
                SettingToggle(text: cleanupText, isOn: Binding(
                    get: { model.settings.cleanupEnabled },
                    set: { model.settings.cleanupEnabled = $0; model.saveSettings() }
                ))
                SettingToggle(text: structureText, isOn: Binding(
                    get: { model.settings.structureDictation },
                    set: { model.settings.structureDictation = $0; model.saveSettings() }
                ))
                SettingToggle(text: SettingsPresentation.selectionCommands, isOn: Binding(
                    get: { model.settings.selectionCommands },
                    set: { model.settings.selectionCommands = $0; model.saveSettings() }
                ), enabled: model.settings.cleanupEnabled)
            }
            ToneSection()
            Section("Confidentialité") {
                SettingRow(text: SettingsPresentation.sentData)
                SettingToggle(text: SettingsPresentation.windowContext, isOn: Binding(
                    get: { model.settings.useWindowContext },
                    set: { model.settings.useWindowContext = $0; model.saveSettings() }
                ), enabled: model.settings.cleanupEnabled)
                SettingRow(text: SettingsPresentation.retention) {
                    Picker(SettingsPresentation.retention.title, selection: Binding(
                        get: { model.settings.retention },
                        set: { model.settings.retention = $0; model.saveSettings(); model.purgeAudio() }
                    )) {
                        ForEach(RetentionMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Stepper("Durée : \(model.settings.temporaryHours) h", value: Binding(
                    get: { model.settings.temporaryHours },
                    set: { model.settings.temporaryHours = $0; model.saveSettings() }
                ), in: AppSettings.temporaryHoursRange)
                Stepper("Plafond audio : \(model.settings.maxStorageMB) Mo", value: Binding(
                    get: { model.settings.maxStorageMB },
                    set: { model.settings.maxStorageMB = $0; model.saveSettings(); model.purgeAudio() }
                ), in: AppSettings.maxStorageMBRange, step: 10)
            }
            Section("Apprentissage") {
                SettingToggle(text: learningText, isOn: Binding(
                    get: { model.settings.learnCorrections },
                    set: { model.settings.learnCorrections = $0; model.saveSettings() }
                ))
            }
            Section("Général") {
                Toggle("Sons de début et de fin", isOn: Binding(
                    get: { model.settings.soundsEnabled },
                    set: { model.settings.soundsEnabled = $0; model.saveSettings() }
                ))
                SettingToggle(text: SettingsPresentation.mute, isOn: Binding(
                    get: { model.settings.muteWhileDictating },
                    set: { model.settings.muteWhileDictating = $0; model.saveSettings() }
                ))
                if model.settings.muteWhileDictating {
                    SettingRow(text: SettingsPresentation.muteMode) {
                        Picker(SettingsPresentation.muteMode.title, selection: Binding(
                            get: { model.settings.muteMode },
                            set: { model.settings.muteMode = $0; model.saveSettings() }
                        )) {
                            ForEach(OutputMuteMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Toggle("Ouvrir à la connexion", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                MicrophonePicker()
                LabeledContent("Configuration guidée") {
                    Button("Revoir la configuration") { model.replayOnboarding() }
                        .hoverFeedback()
                }
            }
            Section("Autorisations") {
                PermissionRow(symbol: "mic.fill", title: String(localized: "Microphone"), detail: microphoneLabel,
                              granted: model.microphoneStatus == .authorized) {
                    Task {
                        _ = await PermissionCenter.requestMicrophone()
                        model.refreshPermissions()
                    }
                }
                PermissionRow(symbol: "accessibility", title: String(localized: "Accessibilité"),
                              detail: model.accessibilityTrusted ? String(localized: "Autorisée") : String(localized: "Requise pour insérer le texte"),
                              granted: model.accessibilityTrusted) {
                    _ = PermissionCenter.accessibilityTrusted(prompt: true)
                    model.refreshPermissions()
                }
                PermissionRow(symbol: "keyboard", title: String(localized: "Surveillance des entrées"),
                              detail: model.inputMonitoringTrusted ? String(localized: "Autorisée") : String(localized: "Requise pour le raccourci"),
                              granted: model.inputMonitoringTrusted) {
                    PermissionCenter.requestInputMonitoring()
                    model.hotkeys?.installTap()
                    model.refreshPermissions()
                }
            }
            DiagnosticsSection()
            HelpSection()
        }
        .onAppear { model.refreshPermissions() }
    }

    /// Correction réellement faite, d'après les clés du coffre.
    private var cleanupText: SettingText {
        _ = model.keysLoadedAt
        let plan = TextCleaner.plan(model.speechRequest(context: nil))
        return SettingsPresentation.cleanup(enabled: model.settings.cleanupEnabled, structure: model.settings.structureDictation,
                                            steps: plan.steps, maxSeconds: plan.maxSeconds, hasCleanupKey: model.hasCleanupKey())
    }

    private var structureText: SettingText {
        _ = model.keysLoadedAt
        return SettingsPresentation.structure(smart: model.settings.cleanupEnabled && !TextCleaner.plan(model.speechRequest(context: nil)).steps.isEmpty)
    }

    private var learningText: SettingText {
        SettingsPresentation.learning(hasTypeSafeKey: model.dependencies.loadKey("typesafe").map { !$0.isEmpty } == true)
    }

    private var microphoneLabel: String {
        switch model.microphoneStatus {
        case .authorized: return String(localized: "Autorisé")
        case .denied: return String(localized: "Refusé")
        case .restricted: return String(localized: "Restreint")
        case .notDetermined: return String(localized: "Pas encore demandé")
        @unknown default: return String(localized: "Inconnu")
        }
    }
}

/// Réglages › Raccourci : raccourci de dictée, même rangée que « Coller la dernière dictée ». Modifier, puis la
/// touche ou la combinaison voulue ; Annuler arrête l'enregistrement sans rien changer.
struct DictationShortcutRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keyCode = model.settings.keyCode
        let modifiers = model.settings.modifierFlags
        let recording = model.isRecordingShortcut
        let keys = ShortcutKeys.dictation(keyCode: keyCode, modifiers: modifiers)
        let prompt: String? = recording ? String(localized: "Appuie sur le raccourci…") : nil
        let keysHelp: String = KeyLabels.describe(keyCode: keyCode, modifiers: modifiers)
        ShortcutRow(text: SettingsPresentation.dictationShortcut, keys: keys, prompt: prompt,
                    keysHelp: keysHelp) { compact in
            ShortcutEditButton(recording: recording, compact: compact) { toggleRecording(recording) }
        }
    }

    private func toggleRecording(_ recording: Bool) {
        if recording {
            model.isRecordingShortcut = false
        } else {
            model.stopRecordingPasteShortcut()
            model.isRecordingShortcut = true
        }
    }
}

/// Ton par catégorie d'apps.
struct ToneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(Self.kinds, id: \.self) { kind in
                Picker(Self.label(kind), selection: Binding(
                    get: { model.settings.tones[kind.rawValue] ?? .natural },
                    set: { tone in
                        model.settings.tones[kind.rawValue] = tone == .natural ? nil : tone
                        model.saveSettings()
                    }
                )) {
                    ForEach(DictationTone.allCases, id: \.self) { tone in
                        Text(Self.label(tone)).tag(tone)
                    }
                }
            }
        } header: {
            SectionTitle(title: SettingsPresentation.toneTitle, summary: SettingsPresentation.toneSummary)
        }
        .disabled(!model.settings.cleanupEnabled)
    }

    static let kinds: [UsageKind] = [.email, .messaging, .writing, .notes, .development, .browser, .other]

    static func label(_ kind: UsageKind) -> String {
        switch kind {
        case .email: return String(localized: "E-mails")
        case .messaging: return String(localized: "Messageries")
        case .writing: return String(localized: "Documents")
        case .notes: return String(localized: "Notes")
        case .development: return String(localized: "Code et terminal")
        case .browser: return String(localized: "Navigateur")
        case .other: return String(localized: "Autres apps")
        }
    }

    static func label(_ tone: DictationTone) -> String {
        switch tone {
        case .natural: return String(localized: "Comme dicté")
        case .polished: return String(localized: "Soigné")
        case .casual: return String(localized: "Détendu")
        }
    }
}

struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var result: String?

    var body: some View {
        Section("Diagnostic") {
            LabeledContent("État de la dictée", value: AppDiagnostics.phase(model.coordinator.phase).title)
            SettingRow(text: SettingsPresentation.diagnostics) {
                Button(exporting ? "Export en cours…" : "Exporter le diagnostic…", systemImage: "square.and.arrow.up") {
                    chooseDestination()
                }
                .hoverFeedback()
                .disabled(exporting)
            }
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func chooseDestination() {
        result = nil
        exporting = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "wispad-diagnostic.json"
        panel.title = String(localized: "Exporter le diagnostic")
        panel.message = String(localized: "Enregistrer les informations techniques sur ce Mac.")
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else {
                    exporting = false
                    return
                }
                model.refreshPermissions()
                let snapshot = AppDiagnostics.snapshot(model: model)
                do {
                    try await AppDiagnostics.export(snapshot: snapshot, store: model.store, to: url)
                    result = String(localized: "Diagnostic exporté.")
                } catch {
                    // Une erreur brute peut contenir le chemin choisi ; elle ne va ni à l'écran ni au rapport.
                    result = String(localized: "Export impossible. Choisis un dossier accessible puis réessaie.")
                }
                exporting = false
            }
        }
    }
}

/// Aide et retours : trois liens vers GitHub, ouverts dans le navigateur, sous une seule ligne d'explication.
struct HelpSection: View {
    var body: some View {
        Section {
            ForEach(HelpPage.allCases, id: \.self) { page in
                Button {
                    page.open()
                } label: {
                    Label(page.title, systemImage: page.symbol)
                }
                .buttonStyle(.link)
                .hoverFeedback()
            }
        } header: {
            SectionTitle(title: SettingsPresentation.helpTitle, summary: SettingsPresentation.helpSummary)
        }
    }
}

/// Micro des dictées : celui du système, ou un micro choisi tant qu'il est branché.
struct MicrophonePicker: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []
    @State private var systemName: String?

    var body: some View {
        Picker("Micro", selection: Binding(
            get: {
                let saved = model.settings.microphoneUID
                return InputDeviceChoice.effectiveUID(saved: saved.isEmpty ? nil : saved, available: devices.map(\.uid)) ?? ""
            },
            set: { model.settings.microphoneUID = $0; model.saveSettings() }
        )) {
            Text(systemName.map { String(localized: "Micro du système (\($0))") } ?? String(localized: "Micro du système")).tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .onAppear {
            devices = AudioInputDevices.all()
            systemName = AudioInputDevices.systemDefault()?.name
        }
    }
}

struct PermissionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var granted: Bool
    var request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: granted ? .green : .orange, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            } else {
                Button("Autoriser", action: request)
                    .hoverFeedback()
            }
        }
    }
}
