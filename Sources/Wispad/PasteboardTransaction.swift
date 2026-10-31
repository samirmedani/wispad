import AppKit
import os

/// Restore only the pasteboard version written by this transaction. Never erase
/// a copy performed by the user (or another application) while paste is pending.
@MainActor
struct PasteboardTransaction {
    private static let log = Logger.wispad("insertion")
    private let pasteboard: NSPasteboard
    private let backup: [NSPasteboardItem]
    private let ownedChangeCount: Int
    /// Fournit la dictée à la demande et note quand une app la lit : le presse-papiers peut revenir aussitôt.
    private let provider: DictationProvider
    /// Formats du presse-papiers précédent qui n'ont pas pu être relus (fournis à la demande par une app).
    let skippedTypes: Int

    /// Marque reconnue par les gestionnaires de presse-papiers (nspasteboard.org) : contenu posé le temps d'un
    /// collage, à ne pas garder dans leur historique ni à lire d'avance.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init?(text: String, pasteboard: NSPasteboard = .general) {
        let initialCount = pasteboard.changeCount
        var copies: [NSPasteboardItem] = []
        var skipped = 0
        // Un format illisible (promesse d'une app, image ou fichier fournis à la demande) est laissé de côté :
        // le 5 octobre, un seul format illisible faisait échouer tout le collage de la dictée.
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            var kept = 0
            for type in item.types {
                if let data = item.data(forType: type), copy.setData(data, forType: type) {
                    kept += 1
                } else {
                    skipped += 1
                }
            }
            if kept > 0 { copies.append(copy) }
        }
        if skipped > 0 {
            Self.log.notice("presse-papiers : \(skipped, privacy: .public) format(s) illisible(s) non sauvegardé(s)")
        }
        // Une copie faite pendant la sauvegarde est relue une fois ; ensuite on colle quand même.
        if pasteboard.changeCount != initialCount {
            Self.log.notice("presse-papiers modifié pendant la sauvegarde")
        }
        skippedTypes = skipped
        self.pasteboard = pasteboard
        backup = copies
        provider = DictationProvider(text: text)
        let item = NSPasteboardItem()
        pasteboard.clearContents()
        guard item.setDataProvider(provider, forTypes: [.string]),
              item.setData(Data(), forType: Self.transientType),
              pasteboard.writeObjects([item]) else {
            pasteboard.clearContents()
            if !copies.isEmpty { pasteboard.writeObjects(copies) }
            return nil
        }
        ownedChangeCount = pasteboard.changeCount
    }

    var stillOwnsContents: Bool { pasteboard.changeCount == ownedChangeCount }

    /// À appeler juste avant ⌘V : une lecture antérieure (service système, presse-papiers universel) ne compte pas.
    func expectPaste() { provider.expectPaste() }

    /// Attend que l'app lise la dictée après ⌘V, au plus `limit` secondes. Vrai si elle l'a lue.
    func waitForPasteRead(within limit: Double) async -> Bool {
        await provider.waitForRead(within: limit)
    }

    func restoreIfUnchanged() {
        guard stillOwnsContents else { return }
        pasteboard.clearContents()
        if !backup.isEmpty { pasteboard.writeObjects(backup) }
    }
}

/// Texte d'une dictée fourni à la demande. AppKit l'appelle quand une app lit le presse-papiers : la première
/// lecture après ⌘V est celle du collage.
private final class DictationProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private struct State {
        var pasteSent = false
        var read = false
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    private let text: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(text: String) { self.text = text }

    func expectPaste() { state.withLock { $0.pasteSent = true } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        let pending = state.withLock { current -> [CheckedContinuation<Bool, Never>] in
            guard current.pasteSent, !current.read else { return [] }
            current.read = true
            defer { current.waiters.removeAll() }
            return Array(current.waiters.values)
        }
        pending.forEach { $0.resume(returning: true) }
    }

    func waitForRead(within limit: Double) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let already = state.withLock { current -> Bool in
                if current.read { return true }
                current.waiters[id] = continuation
                return false
            }
            if already { continuation.resume(returning: true); return }
            Task { [state] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
    }
}
