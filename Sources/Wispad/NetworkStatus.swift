import Foundation
import Network
import os

/// Connexion à internet, suivie en continu par le système. Rien n'est envoyé : macOS dit seulement si une route existe.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    /// Supposée présente tant que le système n'a rien dit : on ne bascule jamais sur le Mac à tort au lancement.
    private let online = OSAllocatedUnfairLock(initialState: true)

    private init() {
        monitor.pathUpdateHandler = { [online] path in
            online.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.yatofix.wispad.network", qos: .utility))
    }

    var isOnline: Bool { online.withLock { $0 } }
}
