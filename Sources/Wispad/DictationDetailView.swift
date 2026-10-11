import SwiftUI
import WispadCore

struct DictationDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: DictationRecord
    @State private var traces: [DictationTrace] = []
    @State private var loadFailed = false
    /// Saisie de ce qui a vraiment été dit, quand on signale une erreur.
    @State private var expected: String?
    @State private var reported: ErrorReport?

    /// `reporting` ouvre directement la saisie de ce qui a été dit (aperçu de développement).
    init(record: DictationRecord, reporting: Bool = false) {
        self.record = record
        _expected = State(initialValue: reporting ? record.finalText : nil)
    }

    private var current: DictationRecord {
        model.history.first { $0.id == record.id } ?? record
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Détails de la dictée").font(.title2.weight(.bold))
                    Text(current.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(appLocale)))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(HoverButtonStyle(treatment: .icon))
                    .help("Fermer les détails").keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !current.finalText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Texte").font(.headline)
                                Spacer()
                                if expected == nil {
                                    Button(reported == nil ? String(localized: "Signaler une erreur") : String(localized: "Erreur signalée"),
                                           systemImage: reported == nil ? "exclamationmark.bubble" : "checkmark.bubble") {
                                        expected = reported?.expected ?? current.finalText
                                    }
                                    .buttonStyle(HoverButtonStyle(treatment: .quiet))
                                    .help("Écrire ce que tu as vraiment dit")
                                }
                                Button("Copier", systemImage: "doc.on.doc") { model.copy(current.finalText) }
                                    .buttonStyle(HoverButtonStyle(treatment: .quiet))
                            }
                            Text(current.finalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if let said = expected {
                                ReportEditor(text: Binding(get: { said }, set: { expected = $0 })) {
                                    expected = nil
                                } save: {
                                    if model.reportError(current, expected: said) {
                                        reported = model.errorReport(for: current)
                                        expected = nil
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Text("\(current.wordCount) mots · \(current.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s d’audio")
                            .foregroundStyle(.secondary)
                        Spacer()
                        let status = HistoryStatus(current.insertionStatus)
                        Text(status.text).foregroundStyle(status.tint)
                    }
                    .font(.callout)
                    if traces.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loadFailed ? String(localized: "Mesures indisponibles") : String(localized: "Pas de mesures pour cette dictée")).font(.headline)
                            Text(loadFailed ? String(localized: "Le détail technique n’a pas pu être lu.") : String(localized: "Le suivi commence avec cette mise à jour. Les anciennes durées ne peuvent pas être reconstituées."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ForEach(traces) { trace in
                            DictationTraceCard(trace: trace)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 480)
        .background(Theme.canvas)
        .onAppear { reported = model.errorReport(for: record) }
        .task(id: model.traceRevision) {
            let store = model.store
            let id = record.id
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try store.traces(dictationID: id) }.value
                guard !Task.isCancelled else { return }
                traces = loaded
                loadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }
}

/// Ce qui a vraiment été dit : le texte collé, corrigé à la main.
private struct ReportEditor: View {
    @Binding var text: String
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ce que tu as vraiment dit").font(.subheadline.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 140)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Ce que tu as vraiment dit")
            Text("Corrige le texte mot pour mot. Le texte, ce que Wispad a entendu et l'audio restent sur ce Mac : ils servent à vérifier qu'un réglage corrige l'erreur sans en créer d'autres.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", action: cancel)
                    .buttonStyle(HoverButtonStyle(treatment: .quiet))
                Button("Enregistrer", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Theme.subtleFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DictationTraceCard: View {
    let trace: DictationTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(trace.origin == .retry ? String(localized: "Retranscription") : trace.origin == .toggle ? String(localized: "Mains libres") : String(localized: "Maintien"))
                    .font(.headline)
                Spacer()
                Text(trace.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(appLocale)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(trace.outcome.displayTitle).font(.callout).foregroundStyle(.secondary)
            if let line = verificationLine {
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                if trace.origin != .retry {
                    timing(String(localized: "Démarrage du micro"), trace.timings.microphoneMs)
                    timing(String(localized: "Premier audio reçu"), trace.timings.firstAudioMs)
                    timing(String(localized: "Flux API prêt"), trace.timings.streamReadyMs)
                }
                timing(trace.origin == .retry ? String(localized: "Transcription") : String(localized: "Transcription après arrêt"), trace.timings.transcriptionMs)
                timing(String(localized: "Correction"), trace.timings.correctionMs)
                if trace.origin != .retry {
                    timing(String(localized: "Insertion"), trace.timings.insertionMs)
                    timing(String(localized: "Fin → résultat"), trace.timings.afterReleaseMs)
                }
            }
            .font(.callout)
            Text(trace.origin == .retry
                 ? String(localized: "L’audio conservé est réutilisé ; le microphone ne s’ouvre pas.")
                 : String(localized: "Démarrage mesuré depuis la demande. La transcription en direct travaille pendant l’écoute ; la ligne ci-dessus mesure ce qui reste après l’arrêt. « — » : étape non mesurée ou non exécutée."))
                .font(.caption).foregroundStyle(.secondary)
            if !trace.calls.isEmpty {
                Divider()
                Text("Appels API").font(.headline)
                ForEach(trace.calls) { call in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: call.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(call.succeeded ? .green : .orange)
                                .accessibilityLabel(call.succeeded ? String(localized: "Réussi") : String(localized: "Échec"))
                            Text(call.api.label).font(.callout.weight(.medium))
                            Spacer(minLength: 8)
                            Text(call.latencyMs > 0 ? Self.duration(call.latencyMs) : "—")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(call.model).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let fallback = call.fallback {
                            let reason = fallback.reason == .servicePaused ? String(localized: "service en pause") : String(localized: "échec de la requête")
                            Text("Relais \(fallback.fromAPI.provider) → \(call.api.provider) · \(reason)")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("La durée d’un flux API correspond à sa finalisation après l’arrêt. « — » : durée non mesurée. Les appels d’apprentissage différés apparaissent ici lorsqu’ils sont terminés.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var verificationLine: String? {
        guard let source = trace.transcriptSource, let reason = trace.transcriptChoice else { return nil }
        let kept = source == .stream ? String(localized: "flux") : String(localized: "enregistrement")
        let because: String
        switch reason {
        case .equivalent: because = String(localized: "même sens que l'enregistrement")
        case .diverged: because = String(localized: "l'enregistrement diffère")
        case .fileTimeout: because = String(localized: "enregistrement trop lent")
        case .fileFailed: because = String(localized: "enregistrement indisponible")
        case .streamEmpty: because = String(localized: "flux vide")
        case .settingOff: because = String(localized: "vérification coupée")
        }
        let delay = trace.fileLatencyMs.map { String(localized: " · fichier \(Self.duration($0))") } ?? ""
        return String(localized: "Texte retenu : \(kept) (\(because))\(delay)")
    }

    private func timing(_ title: String, _ value: Int?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.map(Self.duration) ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private static func duration(_ milliseconds: Int) -> String {
        milliseconds < 1_000 ? "\(milliseconds) ms" : "\((Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(2)))) s"
    }
}

extension DictationOutcome {
    var displayTitle: String {
        switch self {
        case .inserted: return String(localized: "Texte inséré")
        case .pasteSent: return String(localized: "Collage envoyé, confirmation indisponible")
        case .pending: return String(localized: "Texte prêt à copier")
        case .noTarget: return String(localized: "Aucun champ actif")
        case .refusedSecure: return String(localized: "Insertion refusée dans un champ sécurisé")
        case .insertionFailed: return String(localized: "Insertion échouée")
        case .transcriptionFailed: return String(localized: "Transcription échouée")
        case .cancelled: return String(localized: "Opération annulée")
        case .noSpeech: return String(localized: "Aucune parole détectée ou enregistrement trop bref")
        case .microphoneDenied: return String(localized: "Microphone non autorisé")
        case .captureFailed: return String(localized: "Démarrage audio échoué")
        case .keyUnavailable: return String(localized: "Clé API indisponible")
        case .historyFailed: return String(localized: "Enregistrement local échoué")
        case .commandFailed: return String(localized: "Consigne sur la sélection non appliquée")
        }
    }
}
