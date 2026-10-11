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
            Section {
                LabeledContent("Raccourci de dictée") {
                    HStack(spacing: 10) {
                        KeyCap(label: KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags))
                        Button(model.isRecordingShortcut ? String(localized: "Appuie sur le raccourci…") : String(localized: "Modifier")) {
                            model.stopRecordingPasteShortcut()
                            model.isRecordingShortcut = true
                        }
                        .hoverFeedback()
                    }
                }
                PasteShortcutRow()
            } header: {
                Text("Raccourci")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maintien : dictée. Double appui rapide : mains libres, un appui l'arrête. Appui simple au repos : rien. Échap annule l'écoute en cours sans atteindre l'app. Une nouvelle dictée peut commencer pendant que la précédente se termine.")
                    Text("Coller la dernière dictée : remet au curseur la dernière dictée qui n'a pas pu être écrite (sinon la dernière dictée). Sans champ où écrire, le texte est copié et la bulle propose Copier.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section {
                Picker("Langue", selection: Binding(
                    get: { model.settings.language },
                    set: { model.settings.language = $0; model.saveSettings() }
                )) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                Toggle("Vérifier chaque dictée sur l'enregistrement complet", isOn: Binding(
                    get: { model.settings.verifyWithFile },
                    set: { model.settings.verifyWithFile = $0; model.saveSettings() }
                ))
                Toggle("Corriger le texte avant insertion", isOn: Binding(
                    get: { model.settings.cleanupEnabled },
                    set: { model.settings.cleanupEnabled = $0; model.saveSettings() }
                ))
                Toggle("Structurer les listes et paragraphes", isOn: Binding(
                    get: { model.settings.structureDictation },
                    set: { model.settings.structureDictation = $0; model.saveSettings() }
                ))
                Toggle("Comprendre le sujet grâce à la fenêtre active", isOn: Binding(
                    get: { model.settings.useWindowContext },
                    set: { model.settings.useWindowContext = $0; model.saveSettings() }
                ))
                .disabled(!model.settings.cleanupEnabled)
                Toggle("Apprendre de mes corrections", isOn: Binding(
                    get: { model.settings.learnCorrections },
                    set: { model.settings.learnCorrections = $0; model.saveSettings() }
                ))
            } header: {
                Text("Dictée")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plus fiable sur la fin de phrase et les mots techniques. Une transcription de plus par dictée, environ 0,0005 $.")
                    Text(cleanupDescription)
                    if model.settings.structureDictation {
                        Text(structureDescription)
                    }
                    if model.settings.cleanupEnabled, model.settings.useWindowContext {
                        Text(windowContextDescription)
                    }
                    Text(learningDescription)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ToneSection()
            Section("Audio local") {
                Picker("Conservation de l'audio", selection: Binding(
                    get: { model.settings.retention },
                    set: { model.settings.retention = $0; model.saveSettings(); model.purgeAudio() }
                )) {
                    ForEach(RetentionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
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
            Section("Général") {
                Toggle("Sons de début et de fin", isOn: Binding(
                    get: { model.settings.soundsEnabled },
                    set: { model.settings.soundsEnabled = $0; model.saveSettings() }
                ))
                Toggle("Couper le son du Mac pendant la dictée", isOn: Binding(
                    get: { model.settings.muteWhileDictating },
                    set: { model.settings.muteWhileDictating = $0; model.saveSettings() }
                ))
                if model.settings.muteWhileDictating {
                    Picker("Quand couper", selection: Binding(
                        get: { model.settings.muteMode },
                        set: { model.settings.muteMode = $0; model.saveSettings() }
                    )) {
                        ForEach(OutputMuteMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Le son revient dès que tu arrêtes de parler. « Haut-parleurs seulement » : rien n'est coupé si le son sort par un casque ou des AirPods.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            Section {
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
            } header: {
                Text("Autorisations")
            } footer: {
                Text("Wispad envoie l'audio et, si disponible, l'application active, la sélection et un court extrait autour du curseur. L'historique et l'audio restent sur ce Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DiagnosticsSection()
        }
        .onAppear { model.refreshPermissions() }
    }

    /// Correction réellement faite, d'après les clés du coffre : services dans l'ordre et attente maximale.
    private var cleanupDescription: String {
        _ = model.keysLoadedAt
        let fallback = model.settings.structureDictation
            ? String(localized: "le texte transcrit est utilisé avec les seules commandes explicites de mise en page")
            : String(localized: "le texte transcrit est inséré tel quel")
        guard model.settings.cleanupEnabled else { return String(localized: "Correction désactivée : \(fallback).") }
        let plan = TextCleaner.plan(model.speechRequest(context: nil))
        guard !plan.steps.isEmpty else { return String(localized: "Aucune clé de correction : \(fallback).") }
        let seconds = plan.maxSeconds.formatted(.number.precision(.fractionLength(0...1)).locale(appLocale))
        let order = plan.steps.count == 1 ? String(localized: "La correction passe par \(plan.steps[0])") : String(localized: "La correction passe par \(plan.steps[0]), puis \(plan.steps[1]) s'il ne répond pas")
        let hint = model.hasCleanupKey() ? "" : String(localized: " Ajoute une clé DeepSeek pour une correction moins chère.")
        return String(localized: "\(order). Au-delà d'environ \(seconds) s (un peu plus pour une longue dictée), \(fallback).\(hint)")
    }

    private var structureDescription: String {
        _ = model.keysLoadedAt
        if model.settings.cleanupEnabled, !TextCleaner.plan(model.speechRequest(context: nil)).steps.isEmpty {
            return String(localized: "Les énumérations et les changements d'idée sont mis en forme automatiquement. Tu peux aussi dire « première puce », « deuxième puce » ou « nouveau paragraphe ».")
        }
        return String(localized: "Les commandes explicites « première puce », « deuxième puce » et « nouveau paragraphe » fonctionnent localement. Pour structurer une dictée naturelle, active la correction avec un fournisseur configuré.")
    }

    private var windowContextDescription: String {
        String(localized: "La correction lit aussi la fin de la conversation visible dans la fenêtre où tu dictes (2 000 caractères au plus) et tes dernières dictées dans cette app, pour comprendre le sujet, les noms et les nombres. Ce texte part avec la dictée chez le fournisseur de correction ; il n'est ni enregistré ni journalisé, et n'ajoute jamais un mot que tu n'as pas dit.")
    }

    private var learningDescription: String {
        let judge = model.dependencies.loadKey("typesafe").map { !$0.isEmpty } == true
            ? String(localized: "Jev (TypeSafe) le note d'abord ; en cas de doute, le modèle de correction tranche")
            : String(localized: "le modèle de correction juge s'il mérite le dictionnaire")
        return String(localized: "Pendant 30 s après une dictée, si tu corriges un mot mal entendu (« Sidance » → « Seedance »), \(judge) : marques, noms et jargon oui, mots courants et fautes de frappe non. Le mot est ajouté, puis la bulle te demande si tu le gardes. Seuls l'extrait dicté et le mot corrigé sont envoyés ; le reste du champ n'est ni enregistré ni envoyé.")
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

/// Ton par catégorie d'apps et consignes sur la sélection.
struct ToneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Réécrire la sélection sur consigne", isOn: Binding(
                get: { model.settings.selectionCommands },
                set: { model.settings.selectionCommands = $0; model.saveSettings() }
            ))
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
            Text("Ton et consignes")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Le ton ne change que le registre (tournures familières, ponctuation), jamais les mots ni le sens.")
                Text("Avec du texte sélectionné, commence la dictée par une consigne : « reformule plus poliment », « traduis en anglais », « rends-le plus court ». La sélection est réécrite ; si le service ne répond pas, elle reste intacte.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
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
        Section {
            LabeledContent("État de la dictée", value: AppDiagnostics.phase(model.coordinator.phase).title)
            Button(exporting ? "Export en cours…" : "Exporter le diagnostic…", systemImage: "square.and.arrow.up") {
                chooseDestination()
            }
            .hoverFeedback()
            .disabled(exporting)
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostic")
        } footer: {
            Text("Rapport JSON local : autorisations, état du raccourci et de la bulle, durées, API utilisées et résultats des 50 dernières tentatives. Aucun texte dicté, audio, contexte d'application ni clé. Rien n'est envoyé automatiquement.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
