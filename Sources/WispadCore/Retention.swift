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
        var remaining = sorted.filter { file in
            if let expiresAt = file.expiresAt, expiresAt <= now {
                victims.append(file.id)
                return false
            }
            return true
        }
        var total = remaining.reduce(0) { $0 + max(0, $1.bytes) }
        while total > maxBytes, !remaining.isEmpty {
            let oldest = remaining.removeFirst()
            victims.append(oldest.id)
            total -= max(0, oldest.bytes)
        }
        return victims
    }
}
