import Foundation
import os
import WispadCore

/// Où vivent les clés API.
/// - `file` (par défaut) : fichier de l'app (`Application Support/Wispad/api-keys.json`), lisible par le seul
///   utilisateur du Mac.
/// - `vault` : coffre de secrets choisi par l'utilisateur, sans rien écrire sur le Mac. Soit une commande qui répond
///   à `get NOM` (valeur sur la sortie, code 1 si absente) et `put NOM` (valeur sur l'entrée), indiquée par
///   `WISPAD_SECRET_COMMAND` ou la préférence `wispad.secretCommand` ; soit une source distante en lecture seule,
///   choisie dans Fournisseurs : une ligne de commande où « {name} » devient le nom de la clé (serveur par SSH,
///   1Password, Doppler, Infisical, curl…). Clés gardées en mémoire.
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
        if let vaultTool, FileManager.default.isExecutableFile(atPath: vaultTool.path) { return .vault }
        return APIKeys.Vault.remoteCommand(defaults: defaults) == nil ? .file : .vault
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

    /// Nom d'un compte de clé dans Fournisseurs.
    static func title(_ account: String) -> String {
        switch account {
        case ProviderID.xai.rawValue: return "xAI"
        case ProviderID.openAI.rawValue: return "OpenAI"
        case CleanupModel.deepSeekAccount: return "DeepSeek"
        case xaiManagement: return String(localized: "xAI (gestion)")
        case typesafe: return "TypeSafe"
        default: return account
        }
    }

    /// Ce à quoi sert la clé de ce compte.
    static func purpose(_ account: String) -> String {
        switch account {
        case ProviderID.xai.rawValue: return String(localized: "Voix recommandée, correction Grok")
        case ProviderID.openAI.rawValue: return String(localized: "Voix, relais et correction")
        case CleanupModel.deepSeekAccount: return String(localized: "Correction la moins chère")
        case xaiManagement: return String(localized: "Affiche le solde prépayé xAI")
        case typesafe: return String(localized: "Jev, premier avis sur les mots à apprendre ; sans lui, le service de correction juge")
        default: return ""
        }
    }

    /// Fournisseur qui vérifie la clé de ce compte (la clé de gestion xAI se vérifie chez xAI).
    static func provider(_ account: String) -> String {
        account == xaiManagement ? "xAI" : title(account)
    }

    /// Source des clés, relue quand on la change dans Fournisseurs (« reconfigure »).
    private static let source = OSAllocatedUnfairLock(initialState: KeyStoreKind.detect())
    static var kind: KeyStoreKind { source.withLock { $0 } }

    /// Relit la source choisie (fichier, coffre ou source distante), puis toutes les clés.
    @discardableResult
    static func reconfigure() async -> Bool {
        let detected = KeyStoreKind.detect()
        source.withLock { $0 = detected }
        cache.withLock { $0.removeAll() }
        return await refresh()
    }
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())
    private static let log = Logger.wispad("cles")

    static func cached(_ account: String) -> String? {
        cache.withLock { $0[account] }
    }

    /// Relit toutes les clés. Faux si le coffre ne répond pas ou si le fichier est illisible.
    static func refresh() async -> Bool {
        let began = Date()
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
        let milliseconds = Int(Date().timeIntervalSince(began) * 1_000)
        if reachable {
            log.notice("clés lues en \(milliseconds, privacy: .public) ms")
        } else {
            log.error("lecture des clés incomplète après \(milliseconds, privacy: .public) ms")
        }
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
        static var tool: URL? { configuredTool() }

        /// Source distante choisie dans Fournisseurs : la commande, si « wispad.keystore » vaut « remote ».
        static func remoteCommand(defaults: UserDefaults = .standard) -> String? {
            guard defaults.string(forKey: "wispad.keystore") == "remote",
                  let command = defaults.string(forKey: "wispad.remoteCommand")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  command.contains("{name}") else { return nil }
            return command
        }

        /// Une source distante se lit seulement : une nouvelle clé s'ajoute avec son propre outil.
        static var canWrite: Bool {
            guard let tool else { return false }
            return FileManager.default.isExecutableFile(atPath: tool.path)
        }

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
        /// Juste après une mise à jour, macOS réenregistre la nouvelle app pour le réseau local : un coffre lu par
        /// SSH sur le réseau de la maison reste muet une vingtaine de secondes (31 octobre, 0.7.4). Des essais
        /// courts et rapprochés le retrouvent dès qu'il répond, au lieu d'attendre la fin de chaque connexion.
        static let retryDelays: [Double] = [0.5, 1, 1.5, 2, 3]

        /// Durée maximale d'une lecture : au-delà, la commande est arrêtée et la lecture recommence.
        static let readTimeout: TimeInterval = 5

        private static func read(_ account: String, command: String? = nil) async -> (String, String?, Bool) {
            // Commande à essayer : celle donnée (test d'une source pas encore choisie), le coffre s'il existe, sinon la
            // source distante.
            let remote = command ?? (canWrite ? nil : remoteCommand())
            for name in names(for: account) {
                var attempt = 0
                while true {
                    let answer: (Int32, String)
                    if let remote {
                        answer = await runRemote(remote, name: name)
                    } else {
                        answer = await run(["get", name], timeout: readTimeout)
                    }
                    let status = answer.0
                    let output = answer.1
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
            guard canWrite, let name = names(for: account).first else { return false }
            let (status, _) = await run(["put", name], input: secret)
            return status == 0
        }

        /// Teste une source distante sans la choisir : pour chaque compte, clé trouvée ou non, et source joignable.
        static func probe(command: String) async -> [(account: String, found: Bool, reachable: Bool)] {
            await withTaskGroup(of: (String, Bool, Bool).self) { group in
                for account in APIKeys.accounts {
                    group.addTask {
                        let (_, value, reachable) = await read(account, command: command)
                        return (account, value != nil, reachable)
                    }
                }
                var results: [(account: String, found: Bool, reachable: Bool)] = []
                for await (account, found, reachable) in group { results.append((account, found, reachable)) }
                return APIKeys.accounts.compactMap { account in results.first { $0.account == account } }
            }
        }

        /// Délai d'une lecture distante (connexion SSH, déverrouillage d'un gestionnaire…).
        static let remoteTimeout: TimeInterval = 20

        /// Lance la commande distante dans un shell de connexion (PATH de l'utilisateur : Homebrew, op, doppler…),
        /// « {name} » remplacé par le nom de la clé, un nom fixe en capitales choisi par l'app. Rien n'est envoyé sur
        /// l'entrée ; la valeur est lue sur la sortie et n'apparaît jamais en argument. Code 0 avec une valeur : clé
        /// trouvée ; code 0 vide ou code 1 : absente ; autre code ou délai dépassé : source injoignable.
        static func runRemote(_ command: String, name: String) async -> (Int32, String) {
            let line = command.replacingOccurrences(of: "{name}", with: name)
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-l", "-c", line]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: (-1, ""))
                        return
                    }
                    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + remoteTimeout, execute: deadline)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    deadline.cancel()
                    let status = process.terminationReason == .uncaughtSignal ? -2 : process.terminationStatus
                    continuation.resume(returning: (status, String(decoding: data, as: UTF8.self)))
                }
            }
        }

        /// `timeout` : commande arrêtée au-delà (code -2, comme une source injoignable).
        static func run(_ arguments: [String], input: String? = nil, tool: URL? = Vault.tool,
                        timeout: TimeInterval? = nil) async -> (Int32, String) {
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
                    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    deadline.cancel()
                    let status = process.terminationReason == .uncaughtSignal ? -2 : process.terminationStatus
                    continuation.resume(returning: (status, String(decoding: data, as: UTF8.self)))
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
        /// File des lectures et écritures du fichier des clés : jamais sur un fil de Swift concurrency (un disque lent ou
        /// un dossier réseau feraient attendre ce fil), et l'une après l'autre. Deux enregistrements faits ensemble (deux
        /// vérifications qui finissent en même temps) relisaient le fichier chacun sur son fil, et le dernier écrasait
        /// l'autre.
        static let queue = BlockingQueue(label: "wispad.cles")

        static var defaultURL: URL {
            ((try? AppPaths.supportDirectory()) ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("api-keys.json")
        }

        static func readAll(_ accounts: [String], url: URL = defaultURL) async -> [(String, String?, Bool)] {
            await queue.run {
                guard let file = read(url) else { return accounts.map { ($0, nil, false) } }
                return accounts.map { account in
                    let value = (file.keys[account] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = value?.isEmpty == false ? value : nil
                    // Fichier abîmé : un compte hors de sa partie intacte est dit illisible, pas absent.
                    return (account, key, key != nil || file.intact)
                }
            }
        }

        static func write(_ account: String, _ secret: String, url: URL = defaultURL) async -> Bool {
            await queue.run {
                guard var stored = load(url) else { return false }
                stored[account] = secret
                return save(stored, to: url)
            }
        }

        static func delete(_ account: String, url: URL = defaultURL) async -> Bool {
            await queue.run {
                guard var stored = load(url) else { return false }
                stored[account] = nil
                return save(stored, to: url)
            }
        }

        /// Contenu du fichier, entrée par entrée : un fichier absent est vide ; un fichier abîmé (tronqué, invalide) rend
        /// les entrées de sa partie intacte, `intact` faux ; nil s'il n'est pas lisible du tout.
        static func read(_ url: URL) -> (keys: [String: Any], intact: Bool)? {
            guard FileManager.default.fileExists(atPath: url.path) else { return ([:], true) }
            guard let data = try? Data(contentsOf: url), let file = StoredJSON.object(from: data) else { return nil }
            return (file.object, file.intact)
        }

        /// Entrées à réécrire ; nil si le fichier est abîmé ou illisible : il n'est alors jamais réécrit. Une entrée
        /// qui n'est pas une clé lisible ici (autre type, ajoutée par une version plus récente) reste telle quelle.
        static func load(_ url: URL) -> [String: Any]? {
            guard let file = read(url), file.intact else { return nil }
            return file.keys
        }

        /// Écriture complète d'un coup, fichier créé lisible par le seul utilisateur (0600) avant d'y mettre les clés.
        static func save(_ stored: [String: Any], to url: URL) -> Bool {
            guard JSONSerialization.isValidJSONObject(stored),
                  let data = try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]) else { return false }
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
