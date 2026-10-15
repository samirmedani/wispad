import Foundation

/// Objet JSON enregistré sur ce Mac (bloc de réglages, fichier de clés), lu et réécrit sans rien perdre de ce que
/// cette version ne sait pas lire : partie abîmée, valeur ou champ ajoutés par une version plus récente.
public enum StoredJSON {
    /// Objet lu aussi loin qu'il est intact. `intact` faux : bloc abîmé (fin tronquée, octet invalide, texte en trop) ;
    /// seules ses paires complètes sont rendues, chacune vérifiée seule (une paire illisible est écartée, ses voisines
    /// restent), jusqu'au premier endroit où sa structure se perd. nil : pas un objet JSON du tout.
    public static func object(from data: Data) -> (object: [String: Any], intact: Bool)? {
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let read = parsed ?? salvaged(data) else { return nil }
        // Une valeur que JSONSerialization ne saurait pas réécrire (nombre démesuré) est écartée : réécrire le bloc
        // ne doit jamais échouer.
        let object = read.filter { JSONSerialization.isValidJSONObject([$0.value]) }
        return (object, parsed != nil && object.count == read.count)
    }

    /// Valeur à enregistrer pour une clé du bloc. `current` : celle de cette version, en mémoire ; `read` : ce que
    /// cette version a lu de la valeur enregistrée `stored`, réécrit. Inchangée depuis la lecture, la valeur enregistrée
    /// reste telle quelle, même illisible ici (fournisseur, modèle ou mode d'une version plus récente). Changée, la
    /// nouvelle valeur la remplace ; dans un objet, les champs inchangés et ceux que cette version ne lit pas restent.
    public static func merged(stored: Any?, read: Any?, current: Any) -> Any {
        guard let stored else { return current }
        if let read, same(read, current) { return stored }
        guard let current = current as? [String: Any], let stored = stored as? [String: Any] else { return current }
        let read = read as? [String: Any] ?? [:]
        // Champ que cette version n'a ni lu ni écrit (inconnu, ou entrée illisible d'une table) : gardé. Champ lu puis
        // absent de la nouvelle valeur (entrée retirée d'une table) : retiré.
        var result = stored.filter { read[$0.key] == nil && current[$0.key] == nil }
        for (key, value) in current {
            result[key] = merged(stored: stored[key], read: read[key], current: value)
        }
        return result
    }

    /// Même valeur JSON, à l'ordre des clés près.
    public static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject([lhs]), JSONSerialization.isValidJSONObject([rhs]),
              let left = try? JSONSerialization.data(withJSONObject: [lhs], options: .sortedKeys),
              let right = try? JSONSerialization.data(withJSONObject: [rhs], options: .sortedKeys) else { return false }
        return left == right
    }

    private static func salvaged(_ data: Data) -> [String: Any]? {
        var salvage = Salvage(bytes: Array(data))
        return salvage.object()
    }
}

/// Lecture d'un objet JSON abîmé, paire par paire. Seule la fin de chaque valeur est cherchée ici (chaînes, objets et
/// listes imbriqués) ; chaque paire est ensuite vérifiée par JSONSerialization.
private struct Salvage {
    let bytes: [UInt8]
    var index = 0

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let spaces: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    /// Ce qui termine un nombre ou un mot (true, false, null).
    private static let delimiters: Set<UInt8> = Self.spaces.union([UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")])

    private var next: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func object() -> [String: Any]? {
        skipSpaces()
        guard next == UInt8(ascii: "{") else { return nil }
        index += 1
        var object: [String: Any] = [:]
        while true {
            skipSpaces()
            guard next == Self.quote, let keyEnd = endOfString(from: index) else { return object }
            var pair: [UInt8] = [UInt8(ascii: "{")]
            pair += bytes[index..<keyEnd]
            index = keyEnd
            skipSpaces()
            guard next == UInt8(ascii: ":") else { return object }
            index += 1
            skipSpaces()
            guard let valueEnd = endOfValue(from: index) else { return object }
            pair.append(UInt8(ascii: ":"))
            pair += bytes[index..<valueEnd]
            pair.append(UInt8(ascii: "}"))
            index = valueEnd
            if let read = (try? JSONSerialization.jsonObject(with: Data(pair))) as? [String: Any] {
                object.merge(read) { _, new in new }
            }
            skipSpaces()
            guard next == UInt8(ascii: ",") else { return object }
            index += 1
        }
    }

    private mutating func skipSpaces() {
        while let byte = next, Self.spaces.contains(byte) { index += 1 }
    }

    /// Fin (exclue) de la chaîne ouverte à `start`, nil si elle n'est pas fermée.
    private func endOfString(from start: Int) -> Int? {
        var position = start + 1
        while position < bytes.count {
            switch bytes[position] {
            case Self.backslash: position += 2
            case Self.quote: return position + 1
            default: position += 1
            }
        }
        return nil
    }

    /// Fin (exclue) de la valeur qui commence à `start`, nil si elle n'est pas finie. Un nombre ou un mot n'est fini
    /// que suivi d'un séparateur : « 4 » au bout d'un bloc tronqué peut être le début de « 40 ».
    private func endOfValue(from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case Self.quote:
            return endOfString(from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var position = start
            while position < bytes.count {
                switch bytes[position] {
                case Self.quote:
                    guard let end = endOfString(from: position) else { return nil }
                    position = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return position + 1 }
                default:
                    break
                }
                position += 1
            }
            return nil
        default:
            var position = start
            while position < bytes.count, !Self.delimiters.contains(bytes[position]) { position += 1 }
            return position < bytes.count ? position : nil
        }
    }
}
