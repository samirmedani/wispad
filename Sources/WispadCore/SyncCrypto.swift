import CryptoKit
import Foundation

/// Chiffrement de bout en bout (E2EE) de `WispadSync` v1 : AES-256-GCM avec dérivation HKDF-SHA256.
/// Format binaire identique sur macOS, iOS et Windows (Rust) :
/// `WSP1` (4 octets) || nonce aléatoire (12 octets) || chiffré || tag GCM (16 octets),
/// avec AAD = UTF-8(`"wispad-sync-v1:" + relativePath`).
public enum SyncCryptoError: Error, Equatable, Sendable {
    case invalidKey
    case invalidBlob
    case decryptionFailed
}

public struct SyncKey: Equatable, Sendable {
    public static let byteCount = 32
    public static let magic = Data("WSP1".utf8)
    private static let hkdfSalt = Data("wispad-sync-v1".utf8)
    private static let hkdfInfo = Data("vault-aes256gcm".utf8)
    private static let vaultIDPrefix = Data("wispad-vault-id-v1:".utf8)

    public let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else { throw SyncCryptoError.invalidKey }
        self.rawBytes = rawBytes
    }

    public static func generate() -> SyncKey {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        return try! SyncKey(rawBytes: bytes)
    }

    /// Encodage base64url sans remplissage (43 caractères), sûr dans une URL ou un QR code.
    public var base64URL: String {
        Self.encodeBase64URL(rawBytes)
    }

    public init(base64URL: String) throws {
        let trimmed = base64URL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Self.decodeBase64URL(trimmed), decoded.count == Self.byteCount else {
            throw SyncCryptoError.invalidKey
        }
        self.rawBytes = decoded
    }

    /// Empreinte courte du coffre (16 caractères hex minuscules) : vérifie que deux appareils partagent la même clé
    /// sans jamais exposer la clé elle-même dans `manifest.json`.
    public var vaultID: String {
        var input = Data()
        input.append(Self.vaultIDPrefix)
        input.append(rawBytes)
        let digest = SHA256.hash(data: input)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func derivedSymmetricKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawBytes),
            salt: Self.hkdfSalt,
            info: Self.hkdfInfo,
            outputByteCount: Self.byteCount
        )
    }

    /// Chiffre `plaintext` pour le chemin relatif `relativePath` (utilisé en AAD pour empêcher toute substitution).
    public func seal(_ plaintext: Data, relativePath: String, nonce: Data? = nil) throws -> Data {
        let aesNonce: AES.GCM.Nonce
        if let nonce {
            guard nonce.count == 12, let parsed = try? AES.GCM.Nonce(data: nonce) else {
                throw SyncCryptoError.invalidBlob
            }
            aesNonce = parsed
        } else {
            aesNonce = AES.GCM.Nonce()
        }
        let aad = Data(("wispad-sync-v1:" + relativePath).utf8)
        let sealed = try AES.GCM.seal(plaintext, using: derivedSymmetricKey(), nonce: aesNonce, authenticating: aad)
        guard let combined = sealed.combined else { throw SyncCryptoError.invalidBlob }
        var out = Data(capacity: 4 + combined.count)
        out.append(Self.magic)
        out.append(combined)
        return out
    }

    /// Déchiffre et authentifie un bloc `.wsp.enc` pour `relativePath`.
    public func open(_ blob: Data, relativePath: String) throws -> Data {
        guard blob.count >= 4 + 12 + 16, blob.prefix(4) == Self.magic else {
            throw SyncCryptoError.invalidBlob
        }
        let combined = blob.dropFirst(4)
        let aad = Data(("wispad-sync-v1:" + relativePath).utf8)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: derivedSymmetricKey(), authenticating: aad)
        } catch {
            throw SyncCryptoError.decryptionFailed
        }
    }

    public static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ text: String) -> Data? {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 2 { standard += "==" }
        else if remainder == 3 { standard += "=" }
        else if remainder == 1 { return nil }
        return Data(base64Encoded: standard)
    }
}
