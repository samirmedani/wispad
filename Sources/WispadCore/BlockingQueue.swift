import Foundation

/// File GCD série pour un appel qui attend : question à macOS (autorisations, accessibilité d'une autre app), SQLite,
/// fichier, processus. L'appel n'occupe jamais un fil de Swift concurrency : ces fils, autant que de cœurs (3 sur la
/// machine de vérification), servent toute l'app, minuteries de la dictée comprises, et macOS n'en ajoute pas quand
/// l'un d'eux attend (le 14 octobre, une lecture d'autorisation dans `Task.detached` figeait une dictée de test sur
/// la CI). L'appelant attend sans occuper de fil. Jamais `Task.detached`, ni une fonction `async` non isolée, autour
/// d'un appel qui attend.
public struct BlockingQueue: Sendable {
    private let queue: DispatchQueue

    /// File partagée : ses appels passent l'un après l'autre, dans l'ordre où ils sont demandés.
    public init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    public func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    public func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Une file neuve pour ce seul appel : il n'attend aucun autre appel, comme sur un fil à lui. Pour ce qui ne doit
    /// rien retarder d'autre : une app figée fait attendre chaque question d'accessibilité 0,5 s, et la lecture d'une
    /// autre app ne doit pas l'attendre.
    public static func run<Value: Sendable>(label: String, qos: DispatchQoS = .userInitiated,
                                            _ work: @escaping @Sendable () -> Value) async -> Value {
        await BlockingQueue(label: label, qos: qos).run(work)
    }

    public static func run<Value: Sendable>(label: String, qos: DispatchQoS = .userInitiated,
                                            _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await BlockingQueue(label: label, qos: qos).run(work)
    }
}
