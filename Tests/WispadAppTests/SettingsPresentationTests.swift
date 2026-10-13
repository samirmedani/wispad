import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Écran Réglages : chaque réglage s'explique en une ligne simple sous son libellé ; fournisseurs, coûts, délais et
/// données envoyées restent exacts, dans les détails de sa rangée (popover « i »).
struct SettingsPresentationTests {
    private let steps = ["DeepSeek deepseek-flash", "OpenAI gpt-5.4-mini"]

    private var rows: [SettingText] {
        [
            SettingsPresentation.dictationShortcut, SettingsPresentation.pasteLast, SettingsPresentation.language,
            SettingsPresentation.verifyWithFile,
            SettingsPresentation.cleanup(enabled: true, structure: true, steps: steps, maxSeconds: 5, hasCleanupKey: true),
            SettingsPresentation.cleanup(enabled: false, structure: false, steps: [], maxSeconds: 0, hasCleanupKey: false),
            SettingsPresentation.structure(smart: true), SettingsPresentation.structure(smart: false),
            SettingsPresentation.selectionCommands, SettingsPresentation.sentData, SettingsPresentation.windowContext,
            SettingsPresentation.retention, SettingsPresentation.learning(hasTypeSafeKey: true),
            SettingsPresentation.learning(hasTypeSafeKey: false), SettingsPresentation.mute,
            SettingsPresentation.muteMode, SettingsPresentation.diagnostics
        ] + formattingRows
    }

    private var formattingRows: [SettingText] {
        [
            SettingsPresentation.dateOrder, SettingsPresentation.dateSeparator, SettingsPresentation.dateYear,
            SettingsPresentation.leadingZero, SettingsPresentation.monthInWords, SettingsPresentation.clock,
            SettingsPresentation.timeStyle, SettingsPresentation.datePreview
        ]
    }

    /// Une ligne en langage simple : ni montant, ni chiffre, ni nom de modèle, ni redite du libellé.
    @Test func everySummaryIsOneShortPlainLine() {
        for row in rows {
            let summary = row.summary ?? ""
            #expect(!summary.isEmpty, "\(row.title)")
            #expect(summary.count <= 90, "\(summary)")
            #expect(!summary.contains("\n"))
            #expect(summary.rangeOfCharacter(from: .decimalDigits) == nil, "\(summary)")
            #expect(!summary.contains("$"))
            for model in ["deepseek", "gpt", "grok", "jev", "typesafe"] {
                #expect(!summary.lowercased().contains(model), "\(summary)")
            }
            #expect(summary != row.title)
            #expect(!row.details.contains(summary), "\(summary)")
        }
        #expect(SettingsPresentation.toneSummary.count <= 90)
        // Aide et retours : une seule ligne d'explication, sous le titre de la section.
        #expect(SettingsPresentation.helpSummary.count <= 90)
        #expect(SettingsPresentation.helpSummary.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(SettingsPresentation.formattingSummary.count <= 90)
    }

    /// Aucune phrase n'est répétée d'un réglage à l'autre.
    @Test func noSentenceIsRepeated() {
        let unique = [
            SettingsPresentation.dictationShortcut, SettingsPresentation.pasteLast, SettingsPresentation.verifyWithFile,
            SettingsPresentation.cleanup(enabled: true, structure: false, steps: steps, maxSeconds: 5, hasCleanupKey: false),
            SettingsPresentation.structure(smart: true), SettingsPresentation.selectionCommands,
            SettingsPresentation.sentData, SettingsPresentation.windowContext, SettingsPresentation.retention,
            SettingsPresentation.learning(hasTypeSafeKey: false), SettingsPresentation.mute,
            SettingsPresentation.muteMode, SettingsPresentation.diagnostics
        ] + formattingRows
        let sentences = unique.flatMap { [$0.summary].compactMap { $0 } + $0.details }
        #expect(Set(sentences).count == sentences.count)
    }

    @Test func fileCheckKeepsItsExactCost() {
        let row = SettingsPresentation.verifyWithFile
        #expect(row.title == "Vérifier chaque dictée sur l'enregistrement complet")
        #expect(row.details.contains("Une transcription de plus par dictée, environ 0,0005 $."))
    }

    /// Services réels dans l'ordre, attente maximale et repli, uniquement dans les détails.
    @Test func correctionDetailsNameTheServicesAndTheDelay() {
        let row = SettingsPresentation.cleanup(enabled: true, structure: false, steps: steps, maxSeconds: 5, hasCleanupKey: true)
        #expect(row.title == "Corriger le texte avant insertion")
        #expect(row.details.first == "La correction passe par DeepSeek deepseek-flash, puis OpenAI gpt-5.4-mini s'il ne répond pas.")
        #expect(row.details.contains("Au-delà d'environ 5 s (un peu plus pour une longue dictée), le texte transcrit est inséré tel quel."))
        #expect(!row.details.contains("Ajoute une clé DeepSeek pour une correction moins chère."))
        #expect(row.details.last == "Seul le texte part chez le service de correction, jamais l'audio.")

        let single = SettingsPresentation.cleanup(enabled: true, structure: true, steps: ["xAI grok-4-fast"], maxSeconds: 4, hasCleanupKey: false)
        #expect(single.details.first == "La correction passe par xAI grok-4-fast.")
        #expect(single.details.contains("Au-delà d'environ 4 s (un peu plus pour une longue dictée), le texte transcrit est utilisé avec les seules commandes explicites de mise en page."))
        #expect(single.details.contains("Ajoute une clé DeepSeek pour une correction moins chère."))
    }

    @Test func correctionOffOrWithoutKeySaysWhatIsInserted() {
        let off = SettingsPresentation.cleanup(enabled: false, structure: false, steps: steps, maxSeconds: 5, hasCleanupKey: true)
        #expect(off.details.first == "Correction désactivée : le texte transcrit est inséré tel quel.")
        let noKey = SettingsPresentation.cleanup(enabled: true, structure: true, steps: [], maxSeconds: 0, hasCleanupKey: false)
        #expect(noKey.details.first == "Aucune clé de correction : le texte transcrit est utilisé avec les seules commandes explicites de mise en page.")
    }

    @Test func structureExplainsLocalCommandsWithoutCorrection() {
        #expect(SettingsPresentation.structure(smart: true).details == ["Tu peux aussi dire « première puce », « deuxième puce » ou « nouveau paragraphe »."])
        #expect(SettingsPresentation.structure(smart: false).details.first?.hasPrefix("Les commandes explicites") == true)
    }

    /// Les informations de confidentialité ne sont pas perdues : elles sont dans la rangée du réglage concerné.
    @Test func privacyInformationStaysWithItsSetting() {
        #expect(SettingsPresentation.sentData.details == [
            "Wispad envoie l'audio et, si disponible, l'application active, la sélection et un court extrait autour du curseur.",
            "L'historique et l'audio restent sur ce Mac."
        ])
        let context = SettingsPresentation.windowContext
        #expect(context.title == "Comprendre le sujet grâce à la fenêtre active")
        #expect(context.details.contains { $0.contains("(2 000 caractères au plus)") })
        #expect(context.details.contains { $0.contains("il n'est ni enregistré ni journalisé, et n'ajoute jamais un mot que tu n'as pas dit") })
        let learning = SettingsPresentation.learning(hasTypeSafeKey: false)
        #expect(learning.title == "Apprendre de mes corrections")
        #expect(learning.details.contains("Seuls l'extrait dicté et le mot corrigé sont envoyés ; le reste du champ n'est ni enregistré ni envoyé."))
        #expect(SettingsPresentation.diagnostics.details.contains("Aucun texte dicté, audio, contexte d'application ni clé. Rien n'est envoyé automatiquement."))
    }

    @Test func learningNamesTheJudgeActuallyUsed() {
        #expect(SettingsPresentation.learning(hasTypeSafeKey: true).details[0].contains("Jev (TypeSafe) le note d'abord"))
        #expect(SettingsPresentation.learning(hasTypeSafeKey: false).details[0].contains("le modèle de correction juge s'il mérite le dictionnaire"))
    }

    @Test func shortcutDetailsKeepEveryRule() {
        let details = SettingsPresentation.dictationShortcut.details
        #expect(details.contains("Appui simple au repos : rien ne se passe, ni micro ni bulle."))
        #expect(details.contains("Échap annule l'écoute en cours sans atteindre l'app."))
        #expect(SettingsPresentation.pasteLast.details.contains("Sans champ où écrire, le texte est copié et la bulle propose Copier."))
    }

    /// Mise en forme : l'aperçu est rendu par le format lui-même, une ligne par langue de dictée (deux en automatique,
    /// seulement si elles diffèrent) ; ce que la correction fait et ne fait pas reste dans les détails.
    @Test func formattingPreviewFollowsTheFormatAndTheLanguage() {
        let format = DictationDateFormat()
        #expect(SettingsPresentation.preview(format, language: .french) == ["24/10/2026 · 03/11 · 14 h 30"])
        #expect(SettingsPresentation.preview(format, language: .english) == ["24/10/2026 · 03/11 · 2:30 PM"])
        #expect(SettingsPresentation.preview(format, language: .auto)
            == ["Français : 24/10/2026 · 03/11 · 14 h 30", "Anglais : 24/10/2026 · 03/11 · 2:30 PM"])
        let iso = DictationDateFormat(order: .iso, clock: .twentyFourHour, timeStyle: .colon)
        #expect(SettingsPresentation.preview(iso, language: .auto) == ["2026-10-24 · 11-03 · 14:30"])
        #expect(SettingsPresentation.preview(DictationDateFormat(monthInWords: true), language: .french)
            == ["24 octobre 2026 · 3 novembre · 14 h 30"])
        #expect(SettingsPresentation.label(DictationDateFormat.Order.dayMonthYear) == "JJ/MM/AAAA")
        #expect(SettingsPresentation.label(DictationDateFormat.Order.iso) == "AAAA-MM-JJ (ISO)")
        #expect(SettingsPresentation.label(DictationDateFormat.Separator.space) == "Espace")
        #expect(SettingsPresentation.label(DictationDateFormat.Separator.dot) == ".")
        #expect(SettingsPresentation.label(DictationDateFormat.Clock.byLanguage) == "Selon la langue")
        #expect(SettingsPresentation.dateOrder.details.contains { $0.contains("« le trois novembre » devient « 03/11 »") })
        #expect(SettingsPresentation.clock.details.contains("Une durée reste une durée : « deux heures de route » devient « 2 heures de route »."))
    }

    /// La nouvelle présentation ne change aucune valeur par défaut.
    @Test func defaultsAreUnchanged() {
        let settings = AppSettings()
        #expect(settings.cleanupEnabled)
        #expect(settings.verifyWithFile)
        #expect(settings.selectionCommands)
        #expect(settings.structureDictation)
        #expect(!settings.useWindowContext)
        #expect(settings.learnCorrections)
        #expect(settings.retention == .temporary)
        #expect(settings.muteWhileDictating)
        #expect(settings.muteMode == .speakersOnly)
        #expect(settings.dateFormat == DictationDateFormat(timeStyle: .compact))
        #expect(settings.dateFormat.order == .dayMonthYear)
        #expect(settings.dateFormat.clock == .byLanguage)
        #expect(settings.dateFormat.timeStyle == .compact)
        #expect(!settings.dateFormat.monthInWords)
    }
}
