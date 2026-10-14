import AVFoundation
import CryptoKit
import Foundation
import os
import Testing
@testable import WispadApp
@testable import WispadCore

// Aucun appel qui attend (question à macOS ou à une autre app, base, fichier, processus) ne s'exécute sur un fil de
// Swift concurrency : ces fils, autant que de cœurs (3 sur la machine de vérification), servent toute l'app, minuteries
// de la dictée comprises, et macOS n'en ajoute pas quand l'un d'eux attend (constat du 14 octobre, voir
// `PermissionReadsTests`). Preuve déterministe, comme `PermissionReadsTests` : l'appel s'exécute sur sa file GCD, dont
// l'étiquette est lue pendant l'appel, ou ne peut finir avant que sa file partagée, tenue par le test, soit rendue.
// Avec l'ancienne façon de faire (`Task.detached`, ou une fonction `async` non isolée qui attend elle-même), chacun de
// ces tests échoue.

/// Deux fois plus d'appels que de fils de Swift concurrency.
private let callCount = ProcessInfo.processInfo.activeProcessorCount * 2

/// Étiquette de la file GCD de l'appel en cours ; sur un fil de Swift concurrency, celle de sa file « .cooperative ».
private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Appels simultanés : chacun note la file où il s'exécute, puis attend que tous soient là, 10 s au plus. Sur une file
/// neuve par appel, ils s'y retrouvent aussitôt, aucun n'en attend un autre. Sur les fils de Swift concurrency (autant
/// que de cœurs) ou sur une file partagée, ils s'attendent les uns les autres et le délai passe.
private final class Rendezvous: @unchecked Sendable {
    private struct State {
        var labels: [String] = []
        var met: [Bool] = []
    }

    let expected = callCount
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// L'appel qui attend : sa file notée, puis tous les autres attendus.
    func meet() {
        let label = currentQueueLabel()
        state.withLock { $0.labels.append(label) }
        let deadline = Date().addingTimeInterval(10)
        while state.withLock({ $0.labels.count }) < expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let arrived = state.withLock { $0.labels.count }
        state.withLock { $0.met.append(arrived >= expected) }
    }

    /// Une fois tous les appels passés : les files où ils se sont exécutés, et s'ils se sont tous retrouvés.
    func outcome() async throws -> (labels: [String], allMet: Bool) {
        let deadline = Date().addingTimeInterval(30)
        while state.withLock({ $0.met.count }) < expected, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return state.withLock { ($0.labels, $0.met.count == expected && !$0.met.contains(false)) }
    }
}

/// File partagée tenue par le test pendant 300 ms : un appel qui s'y exécute ne peut pas se terminer avant qu'elle soit
/// rendue. Rend vrai si l'appel attendait encore la file, puis sa valeur une fois la file rendue.
private func waitsForHeldQueue<Value: Sendable>(_ queue: BlockingQueue,
                                                _ call: @escaping @Sendable () async -> Value) async -> (waited: Bool, value: Value) {
    let holding = OSAllocatedUnfairLock(initialState: false)
    let release = DispatchSemaphore(value: 0)
    let hold = Task.detached {
        await queue.run {
            holding.withLock { $0 = true }
            release.wait()
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while !holding.withLock({ $0 }), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    let finished = OSAllocatedUnfairLock(initialState: false)
    let pending = Task.detached {
        let value = await call()
        finished.withLock { $0 = true }
        return value
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let waited = !finished.withLock { $0 }
    release.signal()
    let value = await pending.value
    await hold.value
    return (waited, value)
}

@Suite(.serialized)
struct BlockingWorkTests {
    // MARK: - Files

    /// File partagée : ses appels passent l'un après l'autre, sur elle, jamais sur un fil de Swift concurrency.
    @Test func aSharedQueueRunsItsCallsOneAtATimeOnItself() async throws {
        let queue = BlockingQueue(label: "wispad.tests.file-partagee")
        let active = OSAllocatedUnfairLock(initialState: [0, 0])
        let calls = (0..<callCount).map { _ in
            Task.detached {
                await queue.run { () -> String in
                    active.withLock { $0[0] += 1; $0[1] = max($0[1], $0[0]) }
                    Thread.sleep(forTimeInterval: 0.005)
                    active.withLock { $0[0] -= 1 }
                    return currentQueueLabel()
                }
            }
        }
        for call in calls { #expect(await call.value == "wispad.tests.file-partagee") }
        // Jamais deux appels à la fois.
        #expect(active.withLock { $0[1] } == 1)
        #expect(await queue.run { 42 } == 42)
        await #expect(throws: CocoaError.self) {
            try await queue.run { () throws -> Int in throw CocoaError(.fileReadUnknown) }
        }
    }

    /// File neuve par appel : aucun appel n'en attend un autre, comme sur des fils à eux.
    @Test func aQueuePerCallLetsEveryCallRunAtOnce() async throws {
        let calls = Rendezvous()
        let pending = (0..<calls.expected).map { _ in
            Task.detached { await BlockingQueue.run(label: "wispad.tests.file-par-appel") { calls.meet() } }
        }
        for task in pending { await task.value }
        let outcome = try await calls.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.tests.file-par-appel", count: calls.expected))
        #expect(outcome.allMet)
    }

    // MARK: - Accessibilité : une app lente ou figée fait attendre chaque question 0,5 s

    /// Champ actif lu au début de chaque dictée (`ContextProbe.begin`) : celui d'une app figée ne retarde pas la dictée
    /// suivante.
    @MainActor
    @Test func fieldReadsAtTheStartOfADictationRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let fields = (0..<reads.expected).map { _ in
            ContextProbe.begin(read: { _ in
                reads.meet()
                return nil
            }).1
        }
        for field in fields { #expect(await field.value == nil) }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.champ-actif", count: reads.expected))
        #expect(outcome.allMet)
    }

    /// Conversation visible, lue pendant la dictée (`AppDependencies.readWindow`).
    @Test func windowReadsDuringADictationRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let pending = (0..<reads.expected).map { _ in
            Task.detached(priority: .userInitiated) {
                await WindowTextProbe.context(pid: 4242, reader: { _ in
                    reads.meet()
                    return .empty
                })
            }
        }
        for read in pending { #expect(await read.value == nil) }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.fenetre", count: reads.expected))
        #expect(outcome.allMet)
    }

    /// Champ relu avant et après ⌘V (`InsertionSystem.read`), 0,3 s au plus chaque fois.
    @MainActor
    @Test func fieldReadsAroundAPasteRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let limit = TextInserter.fieldReadLimit
        let pending = (0..<reads.expected).map { _ in
            Task.detached(priority: .userInitiated) {
                await InsertionField.read(pid: 4242, within: limit, reader: { _ in
                    reads.meet()
                    return InsertionField()
                }).element == nil
            }
        }
        for read in pending { #expect(await read.value) }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.insertion", count: reads.expected))
        #expect(outcome.allMet)
    }

    /// Zone de saisie lue après l'envoi du texte (`InsertionSystem.locate`), 0,3 s au plus.
    @MainActor
    @Test func inputZoneReadsAfterAPasteRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let limit = TextInserter.fieldReadLimit
        let pending = (0..<reads.expected).map { _ in
            Task.detached(priority: .utility) {
                await ContextProbe.inputZone(pid: 4242, within: limit, reader: { _ in
                    reads.meet()
                    return ContextProbe.InputLocation()
                }) == nil
            }
        }
        for read in pending { #expect(await read.value) }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.zone-de-saisie", count: reads.expected))
        #expect(outcome.allMet)
    }

    /// Champ relu toutes les 250 ms pendant 30 s après un collage, pour apprendre les mots corrigés (`CorrectionWatcher`) :
    /// chaque surveillance a sa file.
    @MainActor
    @Test func correctionWatchReadsRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        // App quittée à la première lecture : chaque surveillance s'arrête là.
        let watchers = (0..<reads.expected).map { _ in
            CorrectionWatcher(reader: { _, _ in
                reads.meet()
                return CorrectionWatcher.Read(
                    element: nil,
                    sample: CorrectionWatch.FocusSample(sameApplication: false, sameElement: false, value: nil)
                )
            })
        }
        for watcher in watchers {
            watcher.watch(inserted: "Phrase de test.", pid: 4242, known: [], corrected: { _ in })
        }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.apprentissage", count: reads.expected))
        #expect(outcome.allMet)
    }

    // MARK: - Autorisations

    /// Accès au micro, relu au début de chaque dictée avant d'ouvrir le micro (`PermissionCenter.requestMicrophone`) :
    /// une question au démon des autorisations de macOS, qui n'attend aucune autre lecture d'autorisation.
    @Test func microphoneAccessReadsAtTheStartOfADictationRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let pending = (0..<reads.expected).map { _ in
            Task.detached(priority: .userInitiated) {
                await PermissionCenter.requestMicrophone(status: {
                    reads.meet()
                    return .authorized
                })
            }
        }
        for request in pending { #expect(await request.value) }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.autorisations.micro", count: reads.expected))
        #expect(outcome.allMet)
    }

    // MARK: - Fichiers et base

    /// Audio d'une dictée lu avant d'être envoyé au fournisseur (`BatchTranscriber`), une file par envoi. Aucun réseau.
    @Test func audioReadsBeforeTheUploadRunOnQueuesOfTheirOwn() async throws {
        let reads = Rendezvous()
        let speech = SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-voice-key",
                                   language: .french, keyterms: [], prompt: "")
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-envoi.wav")
        let pending = (0..<reads.expected).map { _ in
            Task.detached(priority: .userInitiated) {
                try? await BatchTranscriber.transcribe(fileURL: audio, request: speech, transport: { request in
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"text":"Phrase du fichier."}"#.utf8), response)
                }, readFile: { _ in
                    reads.meet()
                    return Data()
                })
            }
        }
        for upload in pending { #expect(await upload.value == "Phrase du fichier.") }
        let outcome = try await reads.outcome()
        #expect(outcome.labels == Array(repeating: "wispad.audio-envoi", count: reads.expected))
        #expect(outcome.allMet)
    }

    /// Fichier des clés lu, enregistré et modifié sur sa file (`APIKeys.LocalFile`), l'un après l'autre.
    @Test func keyFileAccessRunsOnTheKeyQueue() async throws {
        let directory = try temporaryDirectory("wispad-cles")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api-keys.json")
        let account = ProviderID.xai.rawValue
        let saved = await waitsForHeldQueue(APIKeys.LocalFile.queue) {
            await APIKeys.LocalFile.write(account, "valeur-de-test-xai", url: url)
        }
        #expect(saved.waited)
        #expect(saved.value)
        let read = await waitsForHeldQueue(APIKeys.LocalFile.queue) {
            await APIKeys.LocalFile.readAll([account], url: url).map(\.1)
        }
        #expect(read.waited)
        #expect(read.value == ["valeur-de-test-xai"])
        let deleted = await waitsForHeldQueue(APIKeys.LocalFile.queue) {
            await APIKeys.LocalFile.delete(account, url: url)
        }
        #expect(deleted.waited)
        #expect(deleted.value)
    }

    /// Détail d'une dictée lu dans la base sur sa file (`DictationDetailView`) : la base peut attendre jusqu'à 2 s qu'un
    /// autre programme la rende.
    @Test func traceReadsOfTheDetailRunOnTheirQueue() async throws {
        let directory = try temporaryDirectory("wispad-detail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        let record = DictationRecord(finalText: "Phrase de test.", rawText: "phrase de test", durationSeconds: 2, wordCount: 3,
                                     provider: "xai", model: "fixture", insertionStatus: InsertionStatus.inserted.rawValue)
        try store.insert(record)
        try store.saveTrace(DictationTrace(id: "trace", dictationID: record.id, origin: .hold))
        let loaded = await waitsForHeldQueue(DictationDetailView.traceReads) {
            (try? await DictationDetailView.traces(in: store, dictationID: record.id))?.map(\.id)
        }
        #expect(loaded.waited)
        #expect(loaded.value == ["trace"])
    }

    /// Diagnostic exporté sur sa file (`AppDiagnostics.export`) : lecture de la base, puis écriture du rapport.
    @MainActor
    @Test func diagnosticExportsRunOnTheirQueue() async throws {
        let directory = try temporaryDirectory("wispad-diagnostic")
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in "fixture-key" }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        let snapshot = AppDiagnostics.snapshot(model: model)
        let store = model.store
        let report = directory.appendingPathComponent("diagnostic.json")
        let exported = await waitsForHeldQueue(AppDiagnostics.exports) {
            (try? await AppDiagnostics.export(snapshot: snapshot, store: store, to: report)) != nil
        }
        #expect(exported.waited)
        #expect(exported.value)
        #expect(FileManager.default.fileExists(atPath: report.path))
    }

    // MARK: - Installation d'une mise à jour

    /// Disque téléchargé relu en entier (taille, SHA-256), signature contrôlée, outils du système attendus jusqu'à leur
    /// fin (`hdiutil`, `ditto`) : sur la file de l'installation (`UpdateTools`).
    @Test func installerWorkRunsOnTheUpdateQueue() async throws {
        let directory = try temporaryDirectory("wispad-installation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("Wispad.dmg")
        let contents = Data("Disque fictif".utf8)
        try contents.write(to: image)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let asset = DiskImageAsset(url: image, size: Int64(contents.count), sha256: digest)
        let checked = await waitsForHeldQueue(UpdateTools.queue) {
            (try? await UpdateTools.check(image, asset: asset)) != nil
        }
        #expect(checked.waited)
        #expect(checked.value)
        let app = directory.appendingPathComponent("Wispad.app", isDirectory: true)
        let verified = await waitsForHeldQueue(UpdateTools.queue) {
            await UpdateTools.verify(app, teamID: "ABCDE12345")
        }
        #expect(verified.waited)
        #expect(!verified.value)
        let ran = await waitsForHeldQueue(UpdateTools.queue) {
            await UpdateTools.run("/usr/bin/true", []).status
        }
        #expect(ran.waited)
        #expect(ran.value == 0)
    }
}
