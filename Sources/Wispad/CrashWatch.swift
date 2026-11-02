import Foundation
import WispadCore

/// Relance après un plantage. Une petite veille, lancée à chaque démarrage de la version publiée, attend la fin de ce
/// Wispad. Si macOS écrit alors un rapport de plantage de Wispad, elle le relance en arrière-plan avec « --recovered ».
/// Une fermeture normale, une fermeture forcée ou une mise à jour n'écrivent pas de rapport : rien n'est relancé.
/// Deux plantages en moins de deux minutes : la seconde relance n'a pas lieu, pour ne jamais boucler.
enum CrashWatch {
    static let script = """
        pid=$1; app=$2; guard=$3
        stamp="${TMPDIR:-/tmp}/wispad-veille-$pid"
        : > "$stamp"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 1; done
        reports="$HOME/Library/Logs/DiagnosticReports"
        i=0
        while [ "$i" -lt 20 ]; do
          if /usr/bin/find "$reports" -maxdepth 1 -name 'Wispad-*.ips' -newer "$stamp" 2>/dev/null | /usr/bin/grep -q .; then
            if [ -f "$guard" ] && /usr/bin/find "$guard" -mmin -2 2>/dev/null | /usr/bin/grep -q .; then break; fi
            if ! /usr/bin/pgrep -x Wispad >/dev/null; then
              : > "$guard"
              /usr/bin/open -g "$app" --args --background --recovered
            fi
            break
          fi
          /bin/sleep 1
          i=$((i + 1))
        done
        /bin/rm -f "$stamp"
        """

    /// Arguments de la veille pour ce Wispad : son processus, son app, le témoin de la dernière relance.
    static func arguments(pid: Int32, app: URL, guardFile: URL) -> [String] {
        ["-c", script, "wispad-veille", String(pid), app.path, guardFile.path]
    }

    /// Lancement de la version publiée seulement : un build de développement ou un aperçu ne se relance jamais seul.
    static func shouldWatch(arguments: [String], kind: BuildKind) -> Bool {
        let tools = ["--design-preview", "--offscreen", "--status-diagnostic", "--window-context-probe"]
        return kind == .release && !arguments.contains(where: tools.contains)
    }

    static func start() {
        guard shouldWatch(arguments: CommandLine.arguments, kind: BuildKind(info: Bundle.main.infoDictionary)),
              let support = try? AppPaths.supportDirectory() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier, app: Bundle.main.bundleURL,
                                      guardFile: support.appendingPathComponent(".relance-apres-plantage"))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
