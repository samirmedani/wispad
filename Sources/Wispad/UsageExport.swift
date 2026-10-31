import Foundation
import WispadCore

/// Consommation › Derniers appels : copier un appel, copier tout le tableau (texte lisible ou CSV), exporter un fichier
/// CSV. N'en sort que ce que porte un appel enregistré : heure, fournisseur, tâche, modèle, statut, cause d'un échec,
/// relais, durée, audio, jetons et coût. Un appel ne contient aucun texte dicté ; le nom du modèle, seul texte venu
/// d'un fournisseur ou d'un serveur local, ne sort que s'il a la forme d'un nom de modèle.
enum UsageExport {
    // MARK: Texte lisible

    /// Un appel sur une ligne : « 31 oct. 2026 à 13:40:01 · OpenAI · Transcription du fichier · gpt-transcribe ·
    /// 12,0 s d'audio · 450 ms · 0,0004 $ · Secours après xAI · échec ou délai dépassé ».
    static func line(_ event: UsageEvent) -> String {
        var parts = [
            event.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second().locale(appLocale)),
            FallbackPresentation.providerName(event.api.provider),
            CallText.task(event.api)
        ]
        if let model = model(event.model) { parts.append(model) }
        parts.append(CallText.quantities(event))
        parts.append(CallText.latency(event.latencyMs))
        parts.append(event.costUSD.map { MoneyFormat.usd($0) } ?? String(localized: "coût inconnu"))
        if let note = CallText.note(event) { parts.append(note.text) }
        if let cause = event.failureCause { parts.append(FailurePresentation.label(cause)) }
        return parts.joined(separator: " · ")
    }

    /// Tout le tableau : une ligne de titre (période, nombre d'appels, total), puis un appel par ligne, du plus récent au
    /// plus ancien. `incomplete` : des coûts sont inconnus ou la consommation n'a pas pu être relue (total minimum).
    static func text(_ events: [UsageEvent], period: StatsPeriod, incomplete: Bool) -> String {
        let total = events.reduce(0) { $0 + ($1.costUSD ?? 0) }
        let amount = UsagePresentation.amount(total, incomplete: incomplete || events.contains { $0.costUSD == nil })
        let title = String(localized: "Appels de Wispad, \(UsagePresentation.periodPhrase(period)) : \(UsagePresentation.calls(events.count)), \(amount)")
        return ([title, ""] + events.map(line)).joined(separator: "\n") + "\n"
    }

    // MARK: CSV

    /// Colonnes du CSV, dans l'ordre de `csvFields`.
    static var csvHeader: [String] {
        [
            String(localized: "Date"), String(localized: "Fournisseur"), String(localized: "Tâche"),
            String(localized: "Modèle"), String(localized: "Statut"), String(localized: "Cause de l'échec"),
            String(localized: "Relais après"), String(localized: "Raison du relais"), String(localized: "Durée (ms)"),
            String(localized: "Audio (s)"), String(localized: "Jetons en entrée"), String(localized: "Jetons en cache"),
            String(localized: "Jetons en sortie"), String(localized: "Coût (USD)")
        ]
    }

    /// CSV au format RFC 4180 : virgules, lignes terminées par CRLF, une ligne d'en-tête. Nombres avec un point
    /// décimal, dates « 2026-10-31 13:40:01 » à l'heure de ce Mac : un tableur les lit comme des nombres et des dates.
    static func csv(_ events: [UsageEvent], timeZone: TimeZone = .current) -> String {
        ([csvHeader] + events.map { csvFields($0, timeZone: timeZone) })
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    /// Une ligne du CSV. Un compteur inconnu reste vide, jamais un zéro certain : coût inconnu, jetons d'un appel
    /// sans compteurs.
    static func csvFields(_ event: UsageEvent, timeZone: TimeZone = .current) -> [String] {
        let audio = event.api.isAudio
        let counters = !audio && !(event.costUSD == nil && event.tokens == TokenUsage())
        return [
            timestamp(event.createdAt, timeZone: timeZone),
            FallbackPresentation.providerName(event.api.provider),
            CallText.task(event.api),
            model(event.model) ?? "",
            event.succeeded ? String(localized: "réussi") : String(localized: "échec"),
            event.failureCause.map(FailurePresentation.label) ?? "",
            event.fallback.map { FallbackPresentation.providerName($0.fromAPI.provider) } ?? "",
            event.fallback.map { FallbackPresentation.reason($0.reason) } ?? "",
            String(event.latencyMs),
            audio ? decimal(event.audioSeconds, digits: 1) : "",
            counters ? String(event.tokens.input) : "",
            counters ? String(event.tokens.cachedInput) : "",
            counters ? String(event.tokens.output) : "",
            event.costUSD.map { decimal($0, digits: 8) } ?? ""
        ]
    }

    /// Guillemets autour d'un champ qui contient une virgule, un guillemet ou un retour à la ligne ; ses guillemets
    /// sont doublés.
    static func csvField(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// « 2026-10-31 13:40:01 », à l'heure de ce Mac, calendrier grégorien quel que soit celui du système.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Point décimal, sans séparateur de milliers ni zéros inutiles : « 0.00041667 », « 12.5 ». Vide si la valeur
    /// n'est pas un nombre fini.
    static func decimal(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    /// Nom de modèle tel que les fournisseurs et les serveurs locaux l'écrivent (« gpt-5.4-mini », « qwen2.5:7b »,
    /// « org/modèle@q4 ») : lettres et chiffres ASCII et « . - _ : / @ + », 80 caractères au plus, en commençant par
    /// une lettre ou un chiffre (un tableur n'y voit jamais une formule). Autre chose (texte inattendu d'une réponse,
    /// base abîmée) ne sort pas : nil.
    static func model(_ value: String) -> String? {
        let scalars = value.unicodeScalars
        guard let first = scalars.first, scalars.count <= 80, isASCIIAlphanumeric(first),
              scalars.allSatisfy({ isASCIIAlphanumeric($0) || ".-_:/@+".unicodeScalars.contains($0) }) else { return nil }
        return value
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    // MARK: Fichier

    /// « Wispad-appels-7-jours-2026-10-31.csv » : période choisie et jour de l'export.
    static func fileName(period: StatsPeriod, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = String(timestamp(now, timeZone: timeZone).prefix(10))
        return String(localized: "Wispad-appels") + "-" + periodSlug(period) + "-" + day + ".csv"
    }

    private static func periodSlug(_ period: StatsPeriod) -> String {
        switch period {
        case .today: return String(localized: "aujourdhui")
        case .days7: return String(localized: "7-jours")
        case .days30: return String(localized: "30-jours")
        case .all: return String(localized: "tout")
        }
    }

    /// Écriture du fichier hors du fil principal.
    static let writes = BlockingQueue(label: "wispad.usage-export", qos: .utility)
}
