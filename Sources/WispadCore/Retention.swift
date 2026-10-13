import Foundation

public enum RetentionMode: String, Codable, Sendable, CaseIterable {
    case deleteOnSuccess
    case temporary
    case keepWithHistory

    public var title: String {
        switch self {
        case .deleteOnSuccess: return "Supprimer après une insertion réussie"
        case .temporary: return "Conserver temporairement"
        case .keepWithHistory: return "Conserver avec l'historique"
        }
    }
}

public struct StoredAudio: Equatable, Sendable {
    public var id: String
    public var path: String
    public var bytes: Int
    public var createdAt: Date
    public var expiresAt: Date?

    public init(id: String, path: String, bytes: Int, createdAt: Date, expiresAt: Date?) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Taille du fichier, comme `FileManager.attributesOfItem(atPath:)[.size]` : le lien lui-même s'il en est un,
    /// 0 s'il est absent ou illisible. Un seul `lstat`, sans construire tout le dictionnaire d'attributs : la purge
    /// relit chaque audio gardé, chaque minute et après chaque dictée, sur le fil principal.
    public static func bytes(atPath path: String) -> Int {
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0 ? Int(info.st_size) : 0
    }
}

public enum RetentionPolicy {
    public static func expiry(mode: RetentionMode, temporaryHours: Int, now: Date, insertionSucceeded: Bool) -> Date? {
        switch mode {
        case .deleteOnSuccess:
            return insertionSucceeded ? now : nil
        case .temporary:
            return now.addingTimeInterval(Double(max(1, temporaryHours)) * 3600)
        case .keepWithHistory:
            return nil
        }
    }

    public static func shouldDeleteImmediately(mode: RetentionMode, insertionSucceeded: Bool) -> Bool {
        mode == .deleteOnSuccess && insertionSucceeded
    }

    /// Expired files first, then the oldest files until the byte budget is met.
    public static func idsToDelete(files: [StoredAudio], now: Date, maxBytes: Int) -> [String] {
        let sorted = files.sorted { $0.createdAt < $1.createdAt }
        var victims: [String] = []
        let remaining = sorted.filter { file in
            if let expiresAt = file.expiresAt, expiresAt <= now {
                victims.append(file.id)
                return false
            }
            return true
        }
        var total = remaining.reduce(0) { $0 + max(0, $1.bytes) }
        // Du plus ancien au plus récent, sans décaler toute la liste à chaque audio retiré : avec des milliers
        // d'audios et un plafond abaissé, c'était quadratique, sur le fil principal.
        var oldest = remaining.startIndex
        while total > maxBytes, oldest < remaining.endIndex {
            victims.append(remaining[oldest].id)
            total -= max(0, remaining[oldest].bytes)
            oldest += 1
        }
        return victims
    }
}
