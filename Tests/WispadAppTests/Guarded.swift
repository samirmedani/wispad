import Foundation

/// État d'un faux, lu par le test sur le fil principal et modifié par l'app depuis un autre fil (démarrage du micro,
/// vumètre) : chaque lecture et chaque écriture passent par un verrou. Sans lui, Thread Sanitizer signale ces faux,
/// et il doit rester muet pour garder le code de l'app sous surveillance (`swift test --sanitize=thread`).
@propertyWrapper
struct Guarded<Value>: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let box: Box

    init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    var wrappedValue: Value {
        get { box.lock.withLock { box.value } }
        nonmutating set { box.lock.withLock { box.value = newValue } }
    }
}
