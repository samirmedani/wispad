import SwiftUI

/// La sélection seule est observée ici : les ticks du lecteur ne recalculent pas la liste.
struct HistoryAudioDock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.historyPlayer.recordID {
            let record = model.history.first { $0.id == id }
            HistoryAudioControls(
                player: model.historyPlayer,
                title: record.map {
                    String(localized: "Dictée du \($0.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale)))")
                } ?? String(localized: "Audio de la dictée")
            )
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .background(Theme.canvas)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct HistoryAudioControls: View {
    let player: HistoryAudioPlayer
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.brand)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                control("xmark", label: String(localized: "Fermer le lecteur"), action: player.close)
            }
            HStack(spacing: 8) {
                control("gobackward.10", label: String(localized: "Reculer de 10 secondes")) { player.skip(by: -10) }
                Button(action: player.togglePlayPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.brand))
                        .contentShape(Circle())
                }
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .help(player.isPlaying ? String(localized: "Mettre en pause") : String(localized: "Lire l'audio"))
                .accessibilityLabel(player.isPlaying ? String(localized: "Mettre en pause") : String(localized: "Lire l'audio"))
                control("goforward.10", label: String(localized: "Avancer de 10 secondes")) { player.skip(by: 10) }
                control("stop.fill", label: String(localized: "Arrêter et revenir au début"), action: player.stop)
                Slider(
                    value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.001),
                    onEditingChanged: { editing in
                        if editing { player.beginSeeking() } else { player.endSeeking() }
                    }
                )
                .disabled(player.duration <= 0)
                .accessibilityLabel("Position dans l'audio")
                .accessibilityValue("\(time(player.position)) sur \(time(player.duration))")
                Text("\(time(player.position)) / \(time(player.duration))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let error = player.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(treatment: .icon))
        .help(label)
        .accessibilityLabel(label)
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value).rounded(.down))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
