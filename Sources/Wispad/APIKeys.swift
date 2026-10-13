import Foundation
import os
import WispadCore

/// Où vivent les clés API.
/// - `file` (par défaut) : fichier de l'app (`Application Support/Wispad/api-keys.json`), lisible par le seul
///   utilisateur du Mac.
/// - `vault` : coffre de secrets choisi par l'utilisateur, sans rien écrire sur le Mac. C'est une commande qui répond
///   à `get NOM` (valeur sur la sortie, code 1 si absente) et `put NOM` (valeur sur l'entrée), indiquée par
///   `WISPAD_SECRET_COMMAND` ou la préférence `wispad.secretCommand`. Clés gardées en mémoire.
enum KeyStoreKind: Equatable {
    case vault
    case file

    /// Le coffre n'est utilisé que si sa commande est indiquée et exécutable ; `WISPAD_KEYSTORE=file` (ou la
    /// préférence `wispad.keystore` à `file`) force le fichier.
    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment,
                       defaults: UserDefaults = .standard,
                       vaultTool: URL? = APIKeys.Vault.tool) -> KeyStoreKind {
        if environment["WISPAD_KEYSTORE"] == "file" || defaults.string(forKey: "wispad.keystore") == "file" {
            return .file
        }
        guard let vaultTool else { return .file }
        return FileManager.default.isExecutableFile(atPath: vaultTool.path) ? .vault : .file
    }

    /// « dans le coffre » / « sur ce Mac », pour les messages.
    var place: String {
        switch self {
        case .vault: return String(localized: "dans ton coffre de secrets")
        case .file: return String(localized: "sur ce Mac")
        }
    }

    /// Une clé se supprime depuis l'app seulement dans le fichier ; le coffre se gère avec son propre outil.
    var allowsDeletion: Bool { self == .file }
}

/// Clés API de l'app, lues une fois puis gardées en mémoire. Aucune n'est journalisée ni affichée.
enum APIKeys {
    static let xaiManagement = "xai-management"
    static let typesafe = "typesafe"
    static let accounts = [ProviderID.xai.rawValue, ProviderID.openAI.rawValue, CleanupModel.deepSeekAccount, xaiManagement, typesafe]

    static let kind = KeyStoreKind.detect()
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())
    private static let log = Logger.wispad("cles")

    static func cached(_ account: String) -> String? {
        cache.withLock { $0[account] }
    }

    /// Relit toutes les clés. Faux si le coffre ne répond pas ou si le fichier est illisible.
    static func refresh() async -> Bool {
        let results: [(String, String?, Bool)]
        switch kind {
        case .vault: results = await Vault.readAll(accounts)
        case .file: results = await LocalFile.readAll(accounts)
        }
        cache.withLock { values in
            for (account, value, reachable) in results where reachable {
                values[account] = value
            }
        }
        let reachable = results.allSatisfy(\.2)
        if !reachable { log.error("lecture des clés incomplète") }
        return reachable
    }

    static func save(_ account: String, _ secret: String) async -> Bool {
        let saved: Bool
        switch kind {
        case .vault: saved = await Vault.write(account, secret)
        case .file: saved = await LocalFile.write(account, secret)
        }
        if saved { cache.withLock { $0[account] = secret } }
        return saved
    }

    static func delete(_ account: String) async -> Bool {
        guard kind.allowsDeletion else { return false }
        let deleted = await LocalFile.delete(account)
        if deleted { cache.withLock { $0[account] = nil } }
        return deleted
    }

    // MARK: - Coffre de secrets (commande externe)

    enum Vault {
        static let tool = configuredTool()

        /// Commande indiquée par `WISPAD_SECRET_COMMAND`, sinon par la préférence `wispad.secretCommand` (« ~ » accepté).
        static func configuredTool(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   defaults: UserDefaults = .standard) -> URL? {
            let raw = environment["WISPAD_SECRET_COMMAND"] ?? defaults.string(forKey: "wispad.secretCommand")
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        /// Noms dédiés à l'app : une clé manquante ne réutilise jamais une clé partagée.
        static func names(for account: String) -> [String] {
            switch account {
            case ProviderID.xai.rawValue: return ["WISPAD_XAI_API_KEY"]
            case ProviderID.openAI.rawValue: return ["WISPAD_OPENAI_API_KEY"]
            case CleanupModel.deepSeekAccount: return ["WISPAD_DEEPSEEK_API_KEY"]
            case APIKeys.xaiManagement: return ["WISPAD_XAI_MANAGEMENT_KEY"]
            case APIKeys.typesafe: return ["TYPESAFE_API_KEY"]
            default: return []
            }
        }

        static func readAll(_ accounts: [String]) async -> [(String, String?, Bool)] {
            await withTaskGroup(of: (String, String?, Bool).self) { group in
                for account in accounts {
                    group.addTask { await read(account) }
                }
                var collected: [(String, String?, Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }
        }

        /// Pauses avant de redemander une clé au coffre : au lancement, plusieurs connexions partent ensemble
        /// et l'une peut échouer (9 octobre : clés lues sauf une). 1 = absente, autre code = coffre injoignable.
        static let retryDelays: [Double] = [0.5, 1.5]

        private static func read(_ account: String) async -> (String, String?, Bool) {
            for name in names(for: account) {
                var attempt = 0
                while true {
                    let (status, output) = await run(["get", name])
                    if status == 0 {
                        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty { return (account, value, true) }
                        break
                    }
                    if status == 1 { break }
                    guard attempt < retryDelays.count else { return (account, nil, false) }
                    try? await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                    attempt += 1
                }
            }
            return (account, nil, true)
        }

        static func write(_ account: String, _ secret: String) async -> Bool {
            guard let name = names(for: account).first else { return false }
            let (status, _) = await run(["put", name], input: secret)
            return status == 0
        }

        static func run(_ arguments: [String], input: String? = nil, tool: URL? = Vault.tool) async -> (Int32, String) {
            guard let tool else { return (-1, "") }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = tool
                    process.arguments = arguments
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    let stdin = Pipe()
                    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: (-1, ""))
                        return
                    }
                    if let input {
                        // La clé passe par l'entrée standard, jamais en argument de commande.
                        send(input, to: stdin.fileHandleForWriting)
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }
        }

        /// Une commande qui se termine sans lire son entrée (coffre qui refuse `put`) ferme le tuyau : l'écriture
        /// échoue alors sans arrêter Wispad, au lieu du signal SIGPIPE ou de l'exception de `write(_:)`.
        private static func send(_ input: String, to handle: FileHandle) {
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? handle.write(contentsOf: Data(input.utf8))
            try? handle.close()
        }
    }

    // MARK: - Fichier local

    enum LocalFile {
        static var defaultURL: URL {
            ((try? AppPaths.supportDirectory()) ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("api-keys.json")
        }

        static func readAll(_ accounts: [String], url: URL = defaultURL) async -> [(String, String?, Bool)] {
            await Task.detached(priority: .userInitiated) {
                guard let stored = load(url) else { return accounts.map { ($0, nil, false) } }
                return accounts.map { account in
                    let value = stored[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (account, value?.isEmpty == false ? value : nil, true)
                }
            }.value
        }

        static func write(_ account: String, _ secret: String, url: URL = defaultURL) async -> Bool {
            await Task.detached(priority: .userInitiated) {
                guard var stored = load(url) else { return false }
                stored[account] = secret
                return save(stored, to: url)
            }.value
        }

        static func delete(_ account: String, url: URL = defaultURL) async -> Bool {
            await Task.detached(priority: .userInitiated) {
                guard var stored = load(url) else { return false }
                stored[account] = nil
                return save(stored, to: url)
            }.value
        }

        /// Clés enregistrées ; un fichier absent est vide, un fichier illisible rend nil.
        static func load(_ url: URL) -> [String: String]? {
            guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
            return stored
        }

        /// Écriture complète d'un coup, fichier créé lisible par le seul utilisateur (0600) avant d'y mettre les clés.
        static func save(_ stored: [String: String], to url: URL) -> Bool {
            guard let data = try? JSONEncoder().encode(stored) else { return false }
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(".api-keys-\(UUID().uuidString).json")
            guard fileManager.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            do {
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: url)
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch {
                try? fileManager.removeItem(at: staged)
                return false
            }
        }
    }
}
