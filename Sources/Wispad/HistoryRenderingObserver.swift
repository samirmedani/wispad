import SwiftUI

/// Instrumentation locale, inactive dans l'app : la sonde et les tests comptent les lignes évaluées.
typealias HistoryRowRenderCallback = @MainActor @Sendable (String) -> Void

private struct HistoryRowRenderKey: EnvironmentKey {
    static let defaultValue: HistoryRowRenderCallback? = nil
}

extension EnvironmentValues {
    var historyRowDidRender: HistoryRowRenderCallback? {
        get { self[HistoryRowRenderKey.self] }
        set { self[HistoryRowRenderKey.self] = newValue }
    }
}
