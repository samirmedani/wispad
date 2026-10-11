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
    /// Formats du presse-papiers précédent qui n'ont pas pu être relus (fournis à la demande par une app).
    let skippedTypes: Int

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
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if !copies.isEmpty { pasteboard.writeObjects(copies) }
            return nil
        }
        ownedChangeCount = pasteboard.changeCount
    }

    var stillOwnsContents: Bool { pasteboard.changeCount == ownedChangeCount }

    func restoreIfUnchanged() {
        guard stillOwnsContents else { return }
        pasteboard.clearContents()
        if !backup.isEmpty { pasteboard.writeObjects(backup) }
    }
}
