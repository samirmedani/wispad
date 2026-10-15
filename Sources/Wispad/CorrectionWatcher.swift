import AppKit
import ApplicationServices
import WispadCore
import os

/// Observe le champ pendant ~30 s après un collage pour repérer les mots corrigés à la main.
/// Les valeurs lues restent en mémoire le temps de la comparaison : le journal ne reçoit que des comptes.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()
    /// Le délai d'une question d'accessibilité reste 0,5 s (`ContextProbe`).
    private nonisolated static let settleNanoseconds: UInt64 = 150_000_000
    private nonisolated static let log = Logger.wispad("apprentissage")

    /// Une lecture du champ de l'app (champ précédent connu) ; remplacée dans les tests.
    typealias Reader = @Sendable (pid_t, AXUIElement?) -> Read

    private let reader: Reader
    private var task: Task<Void, Never>?

    init(reader: @escaping Reader = { CorrectionWatcher.read(pid: $0, previous: $1) }) {
        self.reader = reader
    }

    func watch(inserted: String, pid: pid_t, known: [String], corrected: @escaping @MainActor ([CorrectionLearner.Candidate]) -> Void) {
        // Une nouvelle dictée clôt l'observation précédente : elle est évaluée sur ce qui a été vu.
        task?.cancel()
        let reader = self.reader
        // Les lectures du champ se font hors du fil principal : une app lente ne retarde ni le raccourci ni la bulle.
        // Chacune attend l'app jusqu'à 0,5 s par question : sur la file de cette surveillance, jamais sur un fil de Swift
        // concurrency (les minuteries de la dictée suivante en dépendent).
        let reads = BlockingQueue(label: "wispad.apprentissage", qos: .utility)
        task = Task.detached(priority: .utility) {
            Self.log.notice("Surveillance démarrée")
            var watch = CorrectionWatch(inserted: inserted, known: known)
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            var element: AXUIElement?
            var outcome: CorrectionWatch.Outcome?
            if !Task.isCancelled {
                let read = await Self.sample(pid: pid, previous: element, with: reader, on: reads)
                outcome = Self.advance(&watch, read: read, element: &element)
            }
            if outcome == nil {
                for _ in 0..<CorrectionWatch.pollCount {
                    try? await Task.sleep(nanoseconds: CorrectionWatch.pollIntervalNanoseconds)
                    if Task.isCancelled { break }
                    let read = await Self.sample(pid: pid, previous: element, with: reader, on: reads)
                    if let stopped = Self.advance(&watch, read: read, element: &element) {
                        outcome = stopped
                        break
                    }
                }
            }
            let result = outcome ?? (Task.isCancelled ? watch.interrupt() : watch.timeOut())
            Self.log(result)
            if !result.candidates.isEmpty {
                await MainActor.run { corrected(result.candidates) }
            }
        }
    }

    /// Une lecture sur la file de la surveillance ; l'élément précédent n'y est lu que par elle.
    private nonisolated static func sample(pid: pid_t, previous: AXUIElement?, with reader: @escaping Reader,
                                           on reads: BlockingQueue) async -> Read {
        let previous = UncheckedSendable(previous)
        return await reads.run { reader(pid, previous.value) }
    }

    private nonisolated static func advance(_ watch: inout CorrectionWatch, read: Read, element: inout AXUIElement?) -> CorrectionWatch.Outcome? {
        switch watch.observe(read.sample) {
        case .continueWatching(let adopt):
            if (adopt || read.sample.sameElement), let focused = read.element {
                element = focused
            }
            return nil
        case .stop(let outcome):
            return outcome
        }
    }

    /// Ce qu'une lecture a vu. L'élément passe d'un fil à l'autre, un seul à la fois.
    struct Read: @unchecked Sendable {
        var element: AXUIElement?
        var sample: CorrectionWatch.FocusSample
    }

    /// Champ de cette app seulement. Un élément recréé est accepté plus loin si la dictée y est encore.
    nonisolated static func read(pid: pid_t, previous: AXUIElement?) -> Read {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return Read(element: previous, sample: CorrectionWatch.FocusSample(sameApplication: false, sameElement: false, value: nil))
        }
        guard let focused = focusedElement(pid: pid), !ContextProbe.isSecure(focused) else {
            return Read(element: previous, sample: CorrectionWatch.FocusSample(sameApplication: true, sameElement: false, value: nil))
        }
        let same = previous.map { CFEqual($0, focused) } ?? false
        return Read(
            element: focused,
            sample: CorrectionWatch.FocusSample(sameApplication: true, sameElement: same, value: ContextProbe.valueForCheck(focused))
        )
    }

    /// `ContextProbe.focusedElement` peut retomber sur l'élément système : on n'en veut pas ici.
    private nonisolated static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard let element = ContextProbe.focusedElement(pid: pid) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    private nonisolated static func log(_ outcome: CorrectionWatch.Outcome) {
        let count = outcome.candidates.count
        switch outcome.stop {
        case .fieldGone:
            log.notice("Arrêt : champ vidé ou envoyé, candidats \(count)")
        case .appLeft:
            log.notice("Arrêt : application quittée, candidats \(count)")
        case .timeout:
            log.notice("Arrêt : délai, candidats \(count)")
        case .unreadable:
            log.notice("Champ illisible, candidats \(count)")
        case .interrupted:
            log.notice("Arrêt : interrompue, candidats \(count)")
        }
    }
}
