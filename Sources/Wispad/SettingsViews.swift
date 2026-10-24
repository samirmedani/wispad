import SwiftUI
import AppKit
import WispadCore
import UniformTypeIdentifiers

/// Écran réglages : en-tête fixe (et, au besoin, une barre sous le titre), formulaire groupé natif dessous.
struct FormScreen<Accessory: View, Content: View>: View {
    var title: String
    var subtitle: String
    /// Change : le formulaire repart d'en haut (onglet de Réglages).
    var resetID: AnyHashable?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            accessory
                .padding(.horizontal, 32)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .id(resetID)
        }
    }
}

extension FormScreen where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, resetID: nil, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Réglages

extension AppModel {
    /// Réglages, sur l'onglet voulu (un micro refusé ouvre Autorisations).
    func openSettings(_ tab: SettingsTab) {
        setDisplayChoice(\.settingsTab, tab)
        open(.settings)
    }
}

/// Réglages en onglets : un thème par page, l'onglet choisi est retrouvé au lancement suivant.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = model.settings.settingsTab
        FormScreen(title: String(localized: "Réglages"), subtitle: String(localized: "Raccourci, correction, audio et autorisations."),
                   resetID: tab) {
            SettingsTabBar()
                .padding(.top, 12)
        } content: {
            switch tab {
            case .general: general
            case .dictation: dictation
            case .formatting:
                FormattingSection()
                ToneSection()
            case .bubble: OverlayPlacementSection()
            case .privacy: privacy
            case .permissions: permissions
            case .help:
                UpdatesSection()
                DiagnosticsSection()
                HelpSection()
            }
        }
        // Autorisations relues hors du fil principal, qui anime l'écran qui s'ouvre ; un clic sur une rangée les relit,
        // lui, sur place.
        .onAppear { model.refreshPermissionsInBackground() }
    }

    @ViewBuilder private var general: some View {
        Section("Raccourci") {
            DictationShortcutRow()
            PasteShortcutRow()
        }
        Section("Général") {
            Toggle("Sons de début et de fin", isOn: Binding(
                get: { model.settings.soundsEnabled },
                set: { model.settings.soundsEnabled = $0; model.saveSettings() }
            ))
            if model.settings.soundsEnabled {
                SoundVolumeRow(text: SettingsPresentation.soundsVolume, value: \.soundsVolume, preview: .start)
                SoundVolumeRow(text: SettingsPresentation.startSoundVolume, value: \.startSoundVolume, preview: .start)
                SoundVolumeRow(text: SettingsPresentation.endSoundVolume, value: \.endSoundVolume, preview: .stop)
            }
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
            LabeledContent("Configuration guidée") {
                Button("Revoir la configuration") { model.replayOnboarding() }
                    .hoverFeedback()
            }
        }
        Section {
            AppearancePicker()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } header: {
            SectionTitle(title: SettingsPresentation.appearanceTitle, summary: SettingsPresentation.appearanceSummary)
        }
    }

    @ViewBuilder private var dictation: some View {
        Section("Audio") {
            MicrophonePicker()
            SettingToggle(text: SettingsPresentation.voiceIsolation(refused: voiceIsolationRefused,
                                                                    otherMicrophone: voiceIsolationOtherMicrophone), isOn: Binding(
                get: { model.settings.voiceIsolation },
                set: { model.settings.voiceIsolation = $0; model.saveSettings(); model.prepareVoiceIsolation() }
            ))
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
        Section("Apprentissage") {
            SettingToggle(text: learningText, isOn: Binding(
                get: { model.settings.learnCorrections },
                set: { model.settings.learnCorrections = $0; model.saveSettings() }
            ))
        }
    }

    private var privacy: some View {
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
    }

    private var permissions: some View {
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
        SettingsPresentation.learning(hasTypeSafeKey: model.hasKey(account: APIKeys.typesafe))
    }

    /// Le traitement de la voix demandé n'a pas démarré avec ce micro (lu à l'affichage des Réglages).
    private var voiceIsolationRefused: Bool {
        model.settings.voiceIsolation && model.dependencies.makeCapture().voiceIsolationRefused
    }

    /// Le traitement est demandé mais un autre micro que celui du système est choisi et branché : micro standard.
    private var voiceIsolationOtherMicrophone: Bool {
        let saved = model.settings.microphoneUID
        guard model.settings.voiceIsolation, !saved.isEmpty,
              let chosen = InputDeviceChoice.effectiveUID(saved: saved, available: AudioInputDevices.all().map(\.uid)) else { return false }
        return chosen != AudioInputDevices.systemDefault()?.uid
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

/// Onglets de Réglages : icône et nom, l'onglet ouvert surligné ; point orange sur Autorisations s'il en manque une.
/// Fenêtre étroite : les icônes seules, leur nom en bulle d'aide.
struct SettingsTabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(labeled: true)
            tabs(labeled: false)
        }
    }

    private func tabs(labeled: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, selected: tab == model.settings.settingsTab, labeled: labeled,
                                  alert: tab == .permissions && model.missingPermissions, namespace: highlight) {
                    withAnimation(reduceMotion ? nil : Theme.spring) { model.setDisplayChoice(\.settingsTab, tab) }
                }
            }
        }
        .fixedSize()
    }
}

private struct SettingsTabButton: View {
    var tab: SettingsTab
    var selected: Bool
    var labeled: Bool
    var alert: Bool
    var namespace: Namespace.ID
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                    .frame(height: 19)
                    .overlay(alignment: .topTrailing) {
                        if alert {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                                .offset(x: 6, y: -2)
                                .help("Une autorisation manque")
                        }
                    }
                if labeled {
                    Text(tab.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, labeled ? 10 : 9)
            .frame(minWidth: labeled ? 64 : 38)
            .frame(height: labeled ? 48 : 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.brand.opacity(0.13))
                        .matchedGeometryEffect(id: "tab", in: namespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle())
        .help(labeled ? "" : tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// Format des dates et des heures écrites par la correction. L'aperçu suit chaque choix ; les rangées sans effet pour le
/// format choisi (séparateur en ISO ou en toutes lettres, écriture sur 24 h en AM/PM) se cachent.
struct FormattingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let format = model.settings.dateFormat
        Section {
            orderRow
            if format.order != .iso, !format.monthInWords {
                separatorRow
                yearRow
                SettingToggle(text: SettingsPresentation.leadingZero, isOn: binding(\.leadingZero))
            }
            SettingToggle(text: SettingsPresentation.monthInWords, isOn: binding(\.monthInWords))
            clockRow
            if format.clock != .twelveHour {
                timeStyleRow
            }
            previewRow
            numberStyleRow
            amountsRow
            thousandsRow
            numberPreviewRow
        } header: {
            SectionTitle(title: SettingsPresentation.formattingTitle, summary: SettingsPresentation.formattingSummary)
        }
        .disabled(!model.settings.cleanupEnabled)
    }

    private var orderRow: some View {
        SettingRow(text: SettingsPresentation.dateOrder) {
            Picker(SettingsPresentation.dateOrder.title, selection: binding(\.order)) {
                ForEach(DictationDateFormat.Order.allCases, id: \.self) { order in
                    Text(SettingsPresentation.label(order)).tag(order)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var separatorRow: some View {
        SettingRow(text: SettingsPresentation.dateSeparator) {
            Picker(SettingsPresentation.dateSeparator.title, selection: binding(\.separator)) {
                ForEach(DictationDateFormat.Separator.allCases, id: \.self) { separator in
                    Text(SettingsPresentation.label(separator)).tag(separator)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var yearRow: some View {
        SettingRow(text: SettingsPresentation.dateYear) {
            Picker(SettingsPresentation.dateYear.title, selection: binding(\.fourDigitYear)) {
                Text("4 chiffres").tag(true)
                Text("2 chiffres").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var clockRow: some View {
        SettingRow(text: SettingsPresentation.clock) {
            Picker(SettingsPresentation.clock.title, selection: binding(\.clock)) {
                ForEach(DictationDateFormat.Clock.allCases, id: \.self) { clock in
                    Text(SettingsPresentation.label(clock)).tag(clock)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Chaque écriture est montrée telle qu'elle sortira : « 14 h 30 », « 14h30 », « 14:30 ».
    private var timeStyleRow: some View {
        SettingRow(text: SettingsPresentation.timeStyle) {
            Picker(SettingsPresentation.timeStyle.title, selection: binding(\.timeStyle)) {
                ForEach(DictationDateFormat.TimeStyle.allCases, id: \.self) { style in
                    Text(verbatim: DictationDateFormat(clock: .twentyFourHour, timeStyle: style).time(hour: 14, minute: 30, english: false))
                        .tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var previewRow: some View {
        SettingRow(text: SettingsPresentation.datePreview) {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(SettingsPresentation.preview(model.settings.dateFormat, language: model.settings.language), id: \.self) { line in
                    Text(verbatim: line)
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DictationDateFormat, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.dateFormat[keyPath: keyPath] },
            set: { model.settings.dateFormat[keyPath: keyPath] = $0; model.saveSettings() }
        )
    }

    private var numberStyleRow: some View {
        SettingRow(text: SettingsPresentation.numberStyle) {
            Picker(SettingsPresentation.numberStyle.title, selection: numberBinding(\.smallNumbersInWords)) {
                Text("Selon le contexte").tag(true)
                Text("En chiffres").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var amountsRow: some View {
        SettingRow(text: SettingsPresentation.amounts) {
            Picker(SettingsPresentation.amounts.title, selection: numberBinding(\.symbols)) {
                Text("Symboles").tag(true)
                Text("En lettres").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var thousandsRow: some View {
        SettingRow(text: SettingsPresentation.thousands) {
            Picker(SettingsPresentation.thousands.title, selection: numberBinding(\.thousands)) {
                ForEach(DictationNumberFormat.Thousands.allCases, id: \.self) { thousands in
                    Text(SettingsPresentation.label(thousands)).tag(thousands)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var numberPreviewRow: some View {
        SettingRow(text: SettingsPresentation.numberPreview) {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(SettingsPresentation.preview(model.settings.numberFormat, language: model.settings.language), id: \.self) { line in
                    Text(verbatim: line)
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func numberBinding<Value>(_ keyPath: WritableKeyPath<DictationNumberFormat, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.numberFormat[keyPath: keyPath] },
            set: { model.settings.numberFormat[keyPath: keyPath] = $0; model.saveSettings() }
        )
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

/// Réglages › Aide › Mises à jour : la version installée, son état, et la recherche à la main (même pause que la
/// flèche de la barre latérale). Une version plus récente se propose ici aussi.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var model
    var status = BuildStatus.shared
    @State private var loadingNotes = false

    var body: some View {
        Section("Mises à jour") {
            SettingRow(text: SettingText(title: status.versionLine, summary: summary)) {
                if case .available(let release) = status.display {
                    Button("Mettre à jour") { model.showUpdate(release) }
                        .buttonStyle(.borderedProminent)
                        .hoverFeedback()
                } else {
                    Button(status.manualPhase == .checking ? "Recherche…" : "Rechercher une mise à jour") {
                        model.checkForUpdates()
                    }
                    .disabled(status.manualPhase == .checking || status.coolingDown)
                    .hoverFeedback()
                }
            }
            if let version = status.version {
                SettingRow(text: SettingText(title: String(localized: "Nouveautés de cette version"),
                                             summary: String(localized: "Ce qui a changé dans la \(version), en rubriques claires."))) {
                    Button(loadingNotes ? String(localized: "Chargement…") : String(localized: "Voir les nouveautés")) {
                        loadingNotes = true
                        Task {
                            await model.showWhatsNew()
                            loadingNotes = false
                        }
                    }
                    .disabled(loadingNotes)
                    .hoverFeedback()
                }
            }
        }
    }

    /// Le résultat d'une recherche à la main, sinon l'état connu et le rythme de la vérification automatique.
    private var summary: String {
        if case .finished(let outcome) = status.manualPhase { return outcome.message }
        switch status.display {
        case .available(let release): return DictationCoordinator.updateMessage(release.version)
        case .upToDate: return String(localized: "À jour. Wispad vérifie aussi seul au lancement, puis toutes les 6 heures.")
        case .development(let freshness):
            return freshness.label ?? String(localized: "Wispad vérifie seul au lancement, puis toutes les 6 heures.")
        case .unknown: return String(localized: "Wispad vérifie seul au lancement, puis toutes les 6 heures.")
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
