import Foundation

/// Instants clés d'une dictée, sur l'horloge des frappes (ms).
@MainActor
final class LatencyMarks {
    var pressed: Int?
    var bubble: Int?
    var microphone: Int?
    var firstAudio: Int?
    var stream: Int?
    var released: Int?
    var pasteSent: Int?
    var pasted: Int?

    init(pressed: Int?) {
        self.pressed = pressed
    }
}

/// Journal des latences de la dictée, sans aucun texte : une ligne par dictée, 500 lignes au plus, dans
/// `latence.log` du dossier de Wispad. Il montre si la bulle, le micro et le collage suivent l'appui sans délai.
enum LatencyLog {
    static let maxLines = 500
    static let fileName = "latence.log"
    private static let queue = DispatchQueue(label: "com.yatofix.wispad.latence", qos: .utility)

    @MainActor
    static func line(_ marks: LatencyMarks, mode: ListenMode, status: String, date: Date = Date()) -> String {
        func span(_ from: Int?, _ to: Int?) -> String {
            guard let from, let to else { return "—" }
            return "\(max(0, to - from)) ms"
        }
        // Dictée lancée depuis le menu : pas d'appui, on compte depuis la bulle.
        let origin = marks.pressed ?? marks.bubble
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return [
            formatter.string(from: date),
            mode == .toggle ? "mains libres" : "maintien",
            "appui→bulle \(span(marks.pressed, marks.bubble))",
            "appui→micro \(span(origin, marks.microphone))",
            "appui→audio \(span(origin, marks.firstAudio))",
            "appui→flux \(span(origin, marks.stream))",
            "fin→envoi \(span(marks.released, marks.pasteSent))",
            "fin→collé \(span(marks.released, marks.pasted))",
            status
        ].joined(separator: "  ")
    }

    static func append(_ line: String, to url: URL) {
        queue.async {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = existing.split(separator: "\n").map(String.init)
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
