import Foundation

/// Synthèse de notes de réunion (style Granola) : fusionne les puces tapées par l'utilisateur avec la transcription
/// complète pour produire un compte-rendu clair, fidèle et structuré, en utilisant le fournisseur LLM BYOK choisi.
public enum MeetingPrompt {
    public static func system(english: Bool) -> String {
        if english {
            return """
            You enhance meeting notes. Combine the user's rough bullet points with the meeting transcript into clear, structured Markdown notes.
            Rules:
            - Prioritize what the user wrote in their notes; use the transcript to fill in exact details, decisions, numbers, names, and action items.
            - Never invent facts, owners, deadlines, or quotes not present in the notes or transcript.
            - Structure with short sections: Summary, Key Decisions, Action Items (with owners if mentioned), and Details.
            - Keep the language concise, direct, and in the same language as the notes/transcript. Reply with the enhanced Markdown only.
            """
        }
        return """
        Tu enrichis des notes de réunion. Fusionne les puces rapides prises par l'utilisateur avec la transcription complète pour produire un compte-rendu clair et structuré en Markdown.
        Règles :
        - Donne la priorité aux points notés par l'utilisateur ; appuie-toi sur la transcription pour compléter les détails exacts, chiffres, noms, décisions et actions.
        - N'invente jamais de fait, de responsable, de date limite ni de citation absents des notes ou de la transcription.
        - Organise en sections courtes : Résumé, Décisions clés, Actions à suivre (avec responsable s'il est cité) et Points détaillés.
        - Style concis et direct, dans la langue des notes et de la transcription. Réponds uniquement avec le Markdown final, sans préambule.
        """
    }

    public static func userText(title: String, userNotes: String, transcript: String, english: Bool) -> String {
        var blocks: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            blocks.append((english ? "Title" : "Titre") + ": \(trimmedTitle)")
        }
        let trimmedNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            blocks.append((english ? "User notes" : "Notes prises pendant la réunion") + ":\n\(trimmedNotes)")
        }
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            blocks.append((english ? "Transcript" : "Transcription") + ":\n\(trimmedTranscript)")
        }
        return blocks.joined(separator: "\n\n")
    }
}

public extension TextCleaner {
    /// Enrichit une note de réunion via les routes LLM BYOK (DeepSeek, OpenAI, xAI ou modèle local Ollama/LM Studio).
    static func enhanceMeeting(
        title: String,
        userNotes: String,
        transcript: String,
        language: DictationLanguage,
        speech: SpeechRequest
    ) async -> CleanupOutcome {
        await enhanceMeeting(title: title, userNotes: userNotes, transcript: transcript, language: language,
                             speech: speech, transport: httpTransport)
    }
}

extension TextCleaner {
    static func enhanceMeeting(
        title: String,
        userNotes: String,
        transcript: String,
        language: DictationLanguage,
        speech: SpeechRequest,
        transport: @escaping HTTPTransport
    ) async -> CleanupOutcome {
        let english = (language == .auto ? TranscriptLanguage.guess(userNotes + " " + transcript) : language) == .english
        let combined = userNotes.trimmingCharacters(in: .whitespacesAndNewlines) + transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return CleanupOutcome(text: userNotes) }
        let routes = Array(routes(speech).prefix(2))
        guard !routes.isEmpty else { return CleanupOutcome(text: userNotes) }
        let requests = RequestLog()
        let systemPrompt = MeetingPrompt.system(english: english)
        let userPrompt = MeetingPrompt.userText(title: title, userNotes: userNotes, transcript: transcript, english: english)
        let maxTokens = min(4_096, max(800, combined.count / 2))
        let timeout: TimeInterval = 45
        for (index, route) in routes.enumerated() {
            guard !Task.isCancelled else { break }
            let transition = fallback(for: index, routes: routes, speech: speech, stage: .correction)
            do {
                let reply = try await withTimeout(seconds: timeout) {
                    try await send(
                        system: systemPrompt,
                        user: userPrompt,
                        route: route,
                        maxTokens: maxTokens,
                        includeReasoning: false,
                        allowTruncated: true,
                        transport: transport,
                        requests: requests,
                        fallback: transition,
                        requestTimeout: timeout
                    )
                }
                let text = CorrectionPrompt.cleanModelOutput(reply.content, fallback: userNotes)
                var failed = requests.events
                let usage = failed.popLast()
                return CleanupOutcome(
                    text: text,
                    usage: usage,
                    failedUsages: failed,
                    fallback: index > 0 || route.isFallback ? route.provider : nil
                )
            } catch {
                if isCancellation(error) { break }
                if APIFailureCause.classify(error) == .timeout { requests.markTimedOut(api: route.api) }
            }
        }
        var failed = requests.events
        let last = failed.popLast()
        return CleanupOutcome(text: userNotes, usage: last, failedUsages: failed)
    }
}
