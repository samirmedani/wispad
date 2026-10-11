import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
private final class RenderedRows {
    var ids = Set<String>()
}

/// Toutes les données sont fictives et restent en mémoire ou dans un dossier temporaire.
@MainActor
@Suite(.serialized)
struct HistoryRowModelTests {
    @Test func rowItemPrecomputesEveryDisplayedLabel() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let item = HistoryRowItem(record(id: "a", at: date, app: "Mail", bundle: "com.apple.mail", audio: "/tmp/a.wav"))

        #expect(item.id == "a")
        #expect(item.time == date.formatted(.dateTime.hour().minute().locale(appLocale)))
        #expect(item.meta == "Mail · 6 mots · fixture")
        #expect(item.metaHelp == "fixture · fixture-model")
        #expect(item.status == HistoryStatus(InsertionStatus.inserted.rawValue))
        #expect(item.targetBundle == "com.apple.mail")
        #expect(item.hasAudio)
        #expect(!item.mayOverflow)
    }

    @Test func rowItemKeepsPlaceholdersAndProviderNames() {
        var source = record(id: "b", at: Date(), app: nil, bundle: nil, audio: nil)
        source.provider = ProviderID.xai.rawValue
        source.insertionStatus = InsertionStatus.transcriptionFailed.rawValue
        let item = HistoryRowItem(source)

        #expect(item.meta == "— · 6 mots · xAI")
        #expect(item.status.text == "À retranscrire")
        #expect(item.targetBundle == nil)
        #expect(!item.hasAudio)
    }

    @Test func onlyLongOrMultilineTextsNeedMeasuring() {
        let threshold = HistoryRowItem.overflowCharacterThreshold
        func item(_ text: String) -> HistoryRowItem {
            var source = record(id: "c", at: Date(), app: nil, bundle: nil, audio: nil)
            source.finalText = text
            return HistoryRowItem(source)
        }

        #expect(!item(String(repeating: "a", count: threshold)).mayOverflow)
        #expect(item(String(repeating: "a", count: threshold + 1)).mayOverflow)
        #expect(item("Première ligne\nDeuxième ligne").mayOverflow)
        #expect(!item("").mayOverflow)
    }

    @Test func cacheReusesAnItemUntilItsDictationChanges() {
        let cache = HistoryRowCache()
        var source = record(id: "d", at: Date(), app: "Notes", bundle: nil, audio: nil)

        let first = cache.item(for: source)
        #expect(cache.item(for: source) == first)
        #expect(cache.itemCount == 1)

        source.insertionStatus = InsertionStatus.failed.rawValue
        source.finalText = "Texte retranscrit."
        let updated = cache.item(for: source)
        #expect(updated.status.text == "Insertion échouée")
        #expect(updated.text == "Texte retranscrit.")
        #expect(cache.itemCount == 1)
    }

    @Test func truncationIsRememberedPerDictationTextAndWidth() {
        let cache = HistoryRowCache()
        #expect(cache.overflows(id: "e", text: "long", width: 600) == nil)

        cache.store(.init(text: "long", width: 600, overflows: true), id: "e")
        #expect(cache.overflows(id: "e", text: "long", width: 600) == true)
        #expect(cache.overflows(id: "e", text: "long", width: 600.3) == true)
        // Largeur encore inconnue (ligne qui réapparaît) : la dernière mesure sert en attendant.
        #expect(cache.overflows(id: "e", text: "long", width: 0) == true)
        // Autre largeur ou texte retranscrit : nouvelle mesure.
        #expect(cache.overflows(id: "e", text: "long", width: 480) == nil)
        #expect(cache.overflows(id: "e", text: "autre", width: 600) == nil)
        #expect(cache.overflows(id: "f", text: "long", width: 600) == nil)

        cache.store(.init(text: "long", width: 480, overflows: false), id: "e")
        #expect(cache.overflows(id: "e", text: "long", width: 480) == false)
        #expect(cache.overflows(id: "e", text: "long", width: 600) == nil)

        cache.store(.init(text: "long", width: 0, overflows: true), id: "g")
        #expect(cache.overflows(id: "g", text: "long", width: 0) == nil)
    }

    @Test func cacheStaysBounded() {
        let cache = HistoryRowCache(limit: 3)
        for index in 0..<10 {
            _ = cache.item(for: record(id: "h\(index)", at: Date(), app: nil, bundle: nil, audio: nil))
            cache.store(.init(text: "t", width: 100, overflows: false), id: "h\(index)")
            #expect(cache.itemCount <= 3)
            #expect(cache.overflowCount <= 3)
        }
        // La dernière dictée vue reste disponible après le vidage.
        #expect(cache.overflows(id: "h9", text: "t", width: 100) == false)
        cache.removeAll()
        #expect(cache.itemCount == 0)
        #expect(cache.overflowCount == 0)
    }

    @Test func renderedLongRowsStoreTheirTruncation() async throws {
        // Ligne réellement rendue hors écran : la mesure cachée doit remplir le cache,
        // sans quoi « Afficher tout » n'apparaîtrait jamais et chaque retour remesurerait.
        let prefix = "truncation-\(UUID().uuidString)-"
        let long = Array(repeating: "Une phrase fictive assez longue pour dépasser quatre lignes dans la carte.",
                         count: 12).joined(separator: " ")
        let rendered = try await render(count: 12) { index, source in
            source.id = "\(prefix)\(index)"
            source.finalText = index.isMultiple(of: 2) ? long : "Court."
        }
        let cache = HistoryRowCache.shared
        let longIDs = rendered.filter { $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count))?.isMultiple(of: 2) == true }
        let shortIDs = rendered.filter { $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count))?.isMultiple(of: 2) == false }

        #expect(!longIDs.isEmpty)
        #expect(!shortIDs.isEmpty)
        for id in longIDs {
            #expect(cache.overflows(id: id, text: long, width: 0) == true)
        }
        for id in shortIDs {
            #expect(cache.overflows(id: id, text: "Court.", width: 0) == nil)
        }
    }

    private func record(id: String, at date: Date, app: String?, bundle: String?, audio: String?) -> DictationRecord {
        DictationRecord(
            id: id,
            createdAt: date,
            finalText: "Phrase fictive pour vérifier l'historique.",
            rawText: "Phrase fictive pour vérifier l'historique.",
            durationSeconds: 3,
            wordCount: 6,
            provider: "fixture",
            model: "fixture-model",
            targetApp: app,
            targetBundle: bundle,
            insertionStatus: InsertionStatus.inserted.rawValue,
            audioPath: audio
        )
    }

    private func render(count: Int, configure: (Int, inout DictationRecord) -> Void) async throws -> Set<String> {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispad-history-row-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        model.history = (0..<count).map { index in
            var source = record(id: "row-\(index)", at: noon.addingTimeInterval(-Double(index)), app: nil, bundle: nil, audio: nil)
            configure(index, &source)
            return source
        }
        let log = RenderedRows()
        let host = NSHostingView(rootView: HistoryView()
            .environment(model)
            .environment(\.historyRowDidRender, { log.ids.insert($0) }))
        let window = OffscreenWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 980, height: 660),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        // La fenêtre n'est jamais présentée ; quelques passes laissent arriver les mesures de géométrie.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        host.layoutSubtreeIfNeeded()
        return log.ids
    }
}
