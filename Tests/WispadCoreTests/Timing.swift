import Foundation

/// Chronométrage des tests de coût : le plus court de plusieurs essais, peu sensible à une machine occupée. Les tests
/// comparent toujours deux mesures prises ensemble, jamais une durée fixe.
enum Timing {
    static func fastest(of runs: Int = 7, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<max(1, runs)).map { _ in clock.measure(work) }.min() ?? .zero
    }
}
