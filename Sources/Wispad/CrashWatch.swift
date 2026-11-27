import Foundation
import WispadCore

/// Relance après un plantage. Une petite veille, lancée à chaque démarrage de la version publiée, attend la fin de ce
/// Wispad. Si macOS écrit alors un rapport de plantage de Wispad, elle le relance en arrière-plan avec « --recovered ».
/// Une fermeture normale, une fermeture forcée ou une mise à jour n'écrivent pas de rapport : rien n'est relancé.
/// Deux plantages en moins de deux minutes : la seconde relance n'a pas lieu, pour ne jamais boucler.
enum CrashWatch {
    /// Tuyau maintenu ouvert tant que Wispad tourne : dès que le processus se termine ou plante, le noyau ferme le
    /// bout d'écriture et la veille se réveille instantanément, sans aucun réveil CPU ni fork périodique.
    nonisolated(unsafe) private static var holdPipe: Pipe?

    static let script = """
        pid=$1; app=$2; guard=$3
        stamp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wispad-veille.XXXXXX") || exit 0
        /bin/cat >/dev/null 2>&1 || true
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        reports="$HOME/Library/Logs/DiagnosticReports"
        uid=$(/usr/bin/id -u)
        i=0
        while [ "$i" -lt 20 ]; do
          if /usr/bin/find "$reports" -maxdepth 1 -name 'Wispad-*.ips' -newer "$stamp" 2>/dev/null | /usr/bin/grep -q .; then
            if [ -f "$guard" ] && /usr/bin/find "$guard" -mmin -2 2>/dev/null | /usr/bin/grep -q .; then break; fi
            if ! /usr/bin/pgrep -u "$uid" -x Wispad >/dev/null; then
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
        guard holdPipe == nil,
              shouldWatch(arguments: CommandLine.arguments, kind: BuildKind(info: Bundle.main.infoDictionary)),
              let support = try? AppPaths.supportDirectory() else { return }
        let pipe = Pipe()
        // Empêche le bout d'écriture d'être hérité par des sous-processus (ex. coffre de clés),
        // ce qui maintiendrait la veille bloquée même après un plantage de Wispad.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        holdPipe = pipe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier, app: Bundle.main.bundleURL,
                                      guardFile: support.appendingPathComponent(".relance-apres-plantage"))
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        try? pipe.fileHandleForReading.close()
    }
}
