import Foundation

/// Audio du micro gardé tant que la transcription en direct n'est pas branchée, puis transmis dans l'ordre :
/// le micro s'ouvre sans attendre le contexte de l'app ni la connexion, et les premiers mots ne sont pas perdus.
public final class PCMRelay: @unchecked Sendable {
    /// Au-delà (environ 4 min à 16 kHz), le plus ancien est jeté ; le fichier WAV, lui, garde tout.
    public static let limit = 8_000_000

    private let lock = NSLock()
    private var buffer = Data()
    private var sink: (@Sendable (Data) -> Void)?
    private var closed = false

    public init() {}

    /// Appelé par le fil audio, paquet par paquet.
    public func push(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !data.isEmpty else { return }
        if let sink {
            sink(data)
            return
        }
        buffer.append(data)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
        }
    }

    /// Branche la transcription : l'audio gardé part d'abord, d'un bloc, puis chaque paquet à son arrivée.
    public func attach(_ sink: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if !buffer.isEmpty {
            sink(buffer)
            buffer = Data()
        }
        self.sink = sink
    }

    /// Fin de l'écoute : plus rien n'est transmis.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        sink = nil
        buffer = Data()
    }

    public var bufferedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}
