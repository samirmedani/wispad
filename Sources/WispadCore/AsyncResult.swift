import Foundation

/// A one-shot result that can arrive before or after its waiter. Resolution and
/// registration share a lock; continuations are always resumed outside the lock.
public final class AsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    public init() {}

    public func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let available: Result<Value, Error>? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil as Result<Value, Error>?
            }
            if let available { continuation.resume(with: available) }
        }
    }

    public func resolve(_ result: Result<Value, Error>) {
        let pending: [CheckedContinuation<Value, Error>] = lock.withLock {
            guard self.result == nil else { return [] }
            self.result = result
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(with: result) }
    }
}
