import Foundation
import Testing
@testable import WispadCore

/// Contrats de WispadCore encore sans test : conservation des audios, santé des services, événements des flux,
/// historique local et nombres dits. Sans réseau ni micro.
struct RetentionContractTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func deleteOnSuccessExpiresOnlyAfterADeliveredDictation() {
        #expect(RetentionPolicy.expiry(mode: .deleteOnSuccess, temporaryHours: 24, now: now, insertionSucceeded: true) == now)
        // Un collage raté garde l'audio pour Retranscrire.
        #expect(RetentionPolicy.expiry(mode: .deleteOnSuccess, temporaryHours: 24, now: now, insertionSucceeded: false) == nil)
        #expect(!RetentionPolicy.shouldDeleteImmediately(mode: .temporary, insertionSucceeded: true))
        #expect(!RetentionPolicy.shouldDeleteImmediately(mode: .keepWithHistory, insertionSucceeded: true))
    }

    @Test func temporaryKeepsTheAudioForTheChosenHoursWhateverTheOutcome() {
        let day = now.addingTimeInterval(24 * 3_600)
        #expect(RetentionPolicy.expiry(mode: .temporary, temporaryHours: 24, now: now, insertionSucceeded: true) == day)
        #expect(RetentionPolicy.expiry(mode: .temporary, temporaryHours: 24, now: now, insertionSucceeded: false) == day)
        // Un réglage nul ou négatif ne supprime pas l'audio sur-le-champ : une heure au moins.
        #expect(RetentionPolicy.expiry(mode: .temporary, temporaryHours: 0, now: now, insertionSucceeded: true) == now.addingTimeInterval(3_600))
        #expect(RetentionPolicy.expiry(mode: .temporary, temporaryHours: -5, now: now, insertionSucceeded: true) == now.addingTimeInterval(3_600))
    }

    @Test func keepWithHistoryNeverExpires() {
        #expect(RetentionPolicy.expiry(mode: .keepWithHistory, temporaryHours: 24, now: now, insertionSucceeded: true) == nil)
        #expect(RetentionPolicy.expiry(mode: .keepWithHistory, temporaryHours: 24, now: now, insertionSucceeded: false) == nil)
    }

    @Test func purgeRemovesExpiredFilesEvenUnderTheBudget() {
        let files = [
            StoredAudio(id: "a-expirer", path: "a", bytes: 10, createdAt: now.addingTimeInterval(-60), expiresAt: now),
            StoredAudio(id: "futur", path: "b", bytes: 10, createdAt: now.addingTimeInterval(-120), expiresAt: now.addingTimeInterval(60)),
            StoredAudio(id: "sans-date", path: "c", bytes: 10, createdAt: now.addingTimeInterval(-180), expiresAt: nil),
        ]
        #expect(RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 1_000_000) == ["a-expirer"])
    }

    @Test func purgeDropsTheOldestFirstWhateverTheInputOrder() {
        let files = [
            StoredAudio(id: "recent", path: "a", bytes: 400, createdAt: now.addingTimeInterval(-10), expiresAt: nil),
            StoredAudio(id: "ancien", path: "b", bytes: 400, createdAt: now.addingTimeInterval(-1_000), expiresAt: nil),
            StoredAudio(id: "moyen", path: "c", bytes: 400, createdAt: now.addingTimeInterval(-500), expiresAt: nil),
        ]
        #expect(RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 800) == ["ancien"])
        #expect(RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 400) == ["ancien", "moyen"])
        #expect(RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 0) == ["ancien", "moyen", "recent"])
        #expect(RetentionPolicy.idsToDelete(files: [], now: now, maxBytes: 0).isEmpty)
    }

    /// Plafond abaissé sous des milliers d'audios : le choix des audios à supprimer reste linéaire (il est fait sur le
    /// fil principal, chaque minute et après chaque dictée). Avant, chaque audio retiré décalait toute la liste.
    @Test func purgeOfThousandsOfFilesStaysLinear() {
        let files = (0..<20_000).map { index in
            StoredAudio(id: "audio-\(index)", path: "\(index)", bytes: 320_000,
                        createdAt: now.addingTimeInterval(Double(-index)), expiresAt: nil)
        }
        let all = RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 0)
        #expect(all.count == files.count)
        #expect(all.first == "audio-19999")
        #expect(all.last == "audio-0")
        let kept = Timing.fastest(of: 3) { _ = RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: .max) }
        let purged = Timing.fastest(of: 3) { _ = RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 0) }
        #expect(purged < kept * 4)
    }

    /// La taille lue pour la purge est celle que donnait `attributesOfItem(atPath:)` : fichier, fichier vide, dossier,
    /// lien (le lien lui-même), fichier absent, nom accentué écrit en forme décomposée.
    @Test func storedAudioSizeIsTheOneFileManagerReports() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("wispad-taille-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictée.wav")
        try Data(count: 3_210).write(to: file)
        let empty = folder.appendingPathComponent("vide.wav")
        try Data().write(to: empty)
        let link = folder.appendingPathComponent("lien.wav")
        try manager.createSymbolicLink(at: link, withDestinationURL: file)
        let paths = [
            file.path, empty.path, folder.path, link.path, folder.appendingPathComponent("absent.wav").path,
            (file.path as NSString).decomposedStringWithCanonicalMapping,
        ]
        for path in paths {
            let expected = (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            #expect(StoredAudio.bytes(atPath: path) == expected)
        }
        #expect(StoredAudio.bytes(atPath: file.path) == 3_210)
        #expect(StoredAudio.bytes(atPath: "") == 0)
    }

    @Test func unreadableSizesDoNotTriggerAPurge() {
        let files = [
            StoredAudio(id: "illisible", path: "a", bytes: -1, createdAt: now.addingTimeInterval(-100), expiresAt: nil),
            StoredAudio(id: "normal", path: "b", bytes: 100, createdAt: now.addingTimeInterval(-50), expiresAt: nil),
        ]
        #expect(RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 100).isEmpty)
    }
}

struct ServiceHealthContractTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyConsecutiveFailuresPauseAService() {
        var health = ServiceHealth()
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start)
        health.record(ServiceHealth.deepSeek, succeeded: true, at: start)
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start)
        #expect(!health.isDown(ServiceHealth.deepSeek, now: start))
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start)
        #expect(health.isDown(ServiceHealth.deepSeek, now: start))
    }

    @Test func pauseLastsAtMostThirtyMinutesAfterTheLastFailure() {
        var health = ServiceHealth()
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start)
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start.addingTimeInterval(600))
        // Compté depuis le dernier échec, pas le premier.
        #expect(health.isDown(ServiceHealth.deepSeek, now: start.addingTimeInterval(600 + 29 * 60)))
        #expect(!health.isDown(ServiceHealth.deepSeek, now: start.addingTimeInterval(600 + 31 * 60)))
    }

    @Test func servicesArePausedIndependently() {
        var health = ServiceHealth()
        let xai = ServiceHealth.voice(.xai)
        health.record(xai, succeeded: false, at: start)
        health.record(xai, succeeded: false, at: start)
        health.record(ServiceHealth.deepSeek, succeeded: false, at: start)
        #expect(health.isDown(xai, now: start))
        #expect(!health.isDown(ServiceHealth.deepSeek, now: start))
        #expect(!health.isDown(ServiceHealth.voice(.openAI), now: start))
        #expect(health.downServices(now: start) == [xai])
        #expect(ServiceHealth.voice(.xai) != ServiceHealth.voice(.openAI))
    }
}

struct TranscriptEventParserContractTests {
    @Test func xaiPartialCarriesItsFlagsAndSegmentEnd() {
        let event = TranscriptEventParser.parseXAI([
            "type": "transcript.partial", "text": "Bonjour", "is_final": true, "speech_final": false,
            "start": 1, "duration": 0.5,
        ])
        #expect(event == .partial(text: "Bonjour", isFinal: true, speechFinal: false, endSeconds: 1.5))
    }

    @Test func xaiPartialReadFromJSONKeepsItsSegmentEnd() throws {
        let data = Data(#"{"type":"transcript.partial","text":"Salut","is_final":false,"speech_final":true,"start":0.25,"duration":1}"#.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(TranscriptEventParser.parseXAI(object) == .partial(text: "Salut", isFinal: false, speechFinal: true, endSeconds: 1.25))
    }

    @Test func xaiPartialWithoutTimingHasNoSegmentEnd() {
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.partial", "text": "a"])
            == .partial(text: "a", isFinal: false, speechFinal: false, endSeconds: nil))
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.partial", "text": "a", "start": 1])
            == .partial(text: "a", isFinal: false, speechFinal: false, endSeconds: nil))
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.partial", "text": "a", "start": Double.nan, "duration": 1.0])
            == .partial(text: "a", isFinal: false, speechFinal: false, endSeconds: nil))
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.partial", "text": "a", "start": "1", "duration": "2"])
            == .partial(text: "a", isFinal: false, speechFinal: false, endSeconds: nil))
    }

    @Test func xaiOtherEvents() {
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.created"]) == .created)
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.done", "text": "Fin."]) == .done(text: "Fin."))
        #expect(TranscriptEventParser.parseXAI(["type": "transcript.done"]) == .done(text: ""))
        #expect(TranscriptEventParser.parseXAI(["type": "error", "message": "quota"]) == .error("quota"))
        #expect(TranscriptEventParser.parseXAI(["type": "error"]) == .error("Erreur de transcription"))
        #expect(TranscriptEventParser.parseXAI(["type": "inconnu"]) == .other)
        #expect(TranscriptEventParser.parseXAI([:]) == .other)
    }

    @Test func openAIEvents() {
        #expect(TranscriptEventParser.parseOpenAI(["type": "conversation.item.input_audio_transcription.delta", "delta": "On "]) == .delta("On "))
        #expect(TranscriptEventParser.parseOpenAI(["type": "conversation.item.input_audio_transcription.completed", "transcript": "On part."]) == .completed("On part."))
        #expect(TranscriptEventParser.parseOpenAI(["type": "error", "error": ["message": "clé invalide"]]) == .error("clé invalide"))
        #expect(TranscriptEventParser.parseOpenAI(["type": "error", "message": "quota"]) == .error("quota"))
        #expect(TranscriptEventParser.parseOpenAI(["type": "error"]) == .error("Erreur de transcription"))
        #expect(TranscriptEventParser.parseOpenAI(["type": "session.created"]) == .other)
    }

    @Test func emptyOpenAICompletionKeepsTheDeltas() {
        var assembler = TranscriptAssembler()
        assembler.apply(TranscriptEventParser.parseOpenAI(["type": "conversation.item.input_audio_transcription.delta", "delta": "Réunion mardi"]))
        assembler.apply(TranscriptEventParser.parseOpenAI(["type": "conversation.item.input_audio_transcription.completed", "transcript": "  "]))
        #expect(assembler.bestText == "Réunion mardi")
    }
}

struct HistoryStoreContractTests {
    private func makeStore() throws -> (HistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path), directory)
    }

    private func record(_ text: String, at seconds: TimeInterval, status: InsertionStatus = .inserted) -> DictationRecord {
        DictationRecord(
            createdAt: Date(timeIntervalSince1970: seconds), finalText: text, rawText: text.lowercased(),
            durationSeconds: 2, wordCount: WordCount.count(text), provider: "xai", model: "fixture",
            targetApp: "Notes", targetBundle: "com.apple.Notes", insertionStatus: status.rawValue,
            audioPath: "audio.wav", audioExpiresAt: Date(timeIntervalSince1970: seconds + 3_600)
        )
    }

    @Test func dictationsComeNewestFirst() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.insert(record("Première.", at: 1_000))
        try store.insert(record("Troisième.", at: 3_000))
        try store.insert(record("Deuxième.", at: 2_000))
        #expect(try store.dictations().map(\.finalText) == ["Troisième.", "Deuxième.", "Première."])
    }

    @Test func retranscriptionReplacesOnlyTheTexts() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = record("", at: 1_000, status: .transcriptionFailed)
        try store.insert(original)
        try store.updateTranscript(id: original.id, finalText: "Texte retrouvé.", rawText: "texte retrouvé", wordCount: 2)
        let loaded = try #require(try store.dictations().first)
        #expect(loaded.finalText == "Texte retrouvé.")
        #expect(loaded.rawText == "texte retrouvé")
        #expect(loaded.wordCount == 2)
        // L'audio, l'app et le statut restent ceux de la dictée d'origine.
        #expect(loaded.audioPath == original.audioPath)
        #expect(loaded.audioExpiresAt == original.audioExpiresAt)
        #expect(loaded.targetBundle == original.targetBundle)
        #expect(loaded.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
        #expect(loaded.createdAt == original.createdAt)
    }

    @Test func updatesTouchOnlyTheTargetedDictation() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = record("Gardée.", at: 1_000)
        let changed = record("Changée.", at: 2_000)
        try store.insert(kept)
        try store.insert(changed)
        try store.updateAudio(id: changed.id, path: nil, expiresAt: nil)
        try store.updateStatus(id: changed.id, status: InsertionStatus.cancelled.rawValue)
        try store.updateTranscript(id: changed.id, finalText: "Nouvelle.", rawText: "nouvelle", wordCount: 1)
        let byID = Dictionary(uniqueKeysWithValues: try store.dictations().map { ($0.id, $0) })
        #expect(byID[kept.id] == kept)
        #expect(byID[changed.id]?.audioPath == nil)
        #expect(byID[changed.id]?.audioExpiresAt == nil)
        #expect(byID[changed.id]?.insertionStatus == InsertionStatus.cancelled.rawValue)
        #expect(byID[changed.id]?.finalText == "Nouvelle.")
    }

    @Test func deleteAllEmptiesTheHistory() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.insert(record("Une.", at: 1_000))
        try store.insert(record("Deux.", at: 2_000))
        try store.deleteAllDictations()
        #expect(try store.dictations().isEmpty)
    }

    @Test func dictionaryIgnoresCaseDuplicatesAndBlankTerms() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addTerm("  Seedance  ")
        try store.addTerm("seedance")
        try store.addTerm("SEEDANCE")
        try store.addTerm("   ")
        try store.addTerm("")
        #expect(try store.dictionary().map(\.term) == ["Seedance"])
    }

    @Test func dictionaryIsSortedWithoutRegardToCase() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for term in ["zsh", "Vercel", "bun", "Anthropic"] { try store.addTerm(term) }
        #expect(try store.dictionary().map(\.term) == ["Anthropic", "bun", "Vercel", "zsh"])
    }

    @Test func deletingATermRemovesOnlyThatTermAndAllowsAddingItBack() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addTerm("Seedance")
        try store.addTerm("Vercel")
        let seedance = try #require(try store.dictionary().first(where: { $0.term == "Seedance" }))
        try store.deleteTerm(id: seedance.id)
        #expect(try store.dictionary().map(\.term) == ["Vercel"])
        try store.addTerm("Seedance")
        #expect(try store.dictionary().map(\.term) == ["Seedance", "Vercel"])
    }
}

struct SpokenNumbersContractTests {
    @Test(arguments: [
        ("soixante dix sept", 77),
        ("quatre vingt dix neuf", 99),
        ("dix huit", 18),
        ("deux cents", 200),
        ("mille", 1_000),
        ("trois cent mille", 300_000),
        ("mille neuf cent quatre vingt quatre", 1_984),
        ("vingt et un", 21),
        ("one thousand and one", 1_001),
    ])
    func frenchAndEnglishNumbersAreReadWhole(words: String, value: Int) {
        let tokens = words.split(separator: " ").map(String.init)
        let parsed = SpokenNumbers.parse(tokens, from: 0)
        #expect(parsed?.value == value)
        #expect(parsed?.next == tokens.count)
    }

    @Test func wordsAroundANumberAreKept() {
        #expect(SpokenNumbers.spell(["il", "faut", "trente", "deux", "serveurs"]) == ["il", "faut", "32", "serveurs"])
        #expect(SpokenNumbers.spell(["et", "voilà"]) == ["et", "voilà"])
        #expect(SpokenNumbers.parse(["serveurs"], from: 0) == nil)
    }

    @Test func numbersWrittenInLettersOrDigitsAreTheSameTranscript() {
        #expect(TranscriptEquivalence.equivalent("Il faut soixante-dix-sept serveurs.", "il faut 77 serveurs"))
        #expect(TranscriptEquivalence.equivalent("En mille neuf cent quatre-vingt-quatre", "en 1984"))
        #expect(!TranscriptEquivalence.equivalent("trente serveurs", "13 serveurs"))
    }
}
