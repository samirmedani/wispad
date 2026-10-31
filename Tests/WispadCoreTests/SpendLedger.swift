import Foundation

// Plafond cumulé des tests qui appellent les vraies API (LiveAPITests). Outil de test seulement : il ne fait plus
// partie de l'app, mais garde le même fichier pour que le cumul déjà dépensé ne reparte pas de zéro.
// 6 $ depuis le 31 octobre 2026 : le mainteneur a ajouté 1 $ aux 5 $ d'origine, atteints ce jour-là.

public enum SpendLedgerError: Error, CustomStringConvertible {
    case cap(spent: Double, attempted: Double, cap: Double)
    public var description: String {
        switch self {
        case .cap(let spent, let attempted, let cap):
            return String(format: "Plafond de test %.2f $ atteint (déjà %.4f, demande %.4f).", cap, spent, attempted)
        }
    }
}

public struct SpendLedger: Sendable {
    public static let defaultCapUSD = 6.0
    public var url: URL
    public var capUSD: Double

    public init(url: URL, capUSD: Double = SpendLedger.defaultCapUSD) {
        self.url = url
        self.capUSD = capUSD
    }

    public static func wispadDefault() -> SpendLedger {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispad", isDirectory: true)
        return SpendLedger(url: base.appendingPathComponent("api-test-spend.json"))
    }

    public func spent() -> Double {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["usd"] as? Double else { return 0 }
        return value
    }

    public func reserve(_ usd: Double) throws {
        let current = spent()
        guard current + usd <= capUSD + 0.000_001 else {
            throw SpendLedgerError.cap(spent: current, attempted: usd, cap: capUSD)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = ["usd": current + usd]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url, options: .atomic)
    }
}
