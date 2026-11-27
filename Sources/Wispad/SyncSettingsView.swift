import AppKit
import SwiftUI
import WispadCore

/// Onglet « Synchronisation » dans Réglages : BYOS 100 % open source, chiffré de bout en bout, texte seul,
/// configuration en 2 à 3 clics (Dossier iCloud/OneDrive/Dropbox, Cloudflare R2 / S3, ou WebDAV).
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingInput = ""
    @State private var showQR = false
    @State private var cachedQRURI = ""
    @State private var cachedQRImage: NSImage?
    @State private var detectedFolders: [DetectedCloudFolder] = []
    @State private var copiedLink = false
    @State private var importFeedback: String?

    private var sync: SyncController { model.sync }

    private var effectiveBackend: SyncBackendKind {
        sync.config.backend == .off ? .folder : sync.config.backend
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Open source, sans compte, chiffré de bout en bout")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Wispad est entièrement gratuit et n'héberge aucun serveur central. La synchronisation est facultative et utilise ton propre stockage (dossier iCloud/OneDrive, Cloudflare R2 gratuit ou WebDAV), chiffré localement en AES-256-GCM.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Texte seul (quelques kilo-octets) : tes dictées, notes de réunion, dictionnaire et réglages d'écriture suivent tous tes appareils. L'audio reste sur l'appareil qui l'a enregistré pour éviter de saturer ton stockage et ton débit. Tes clés API ne sont jamais synchronisées.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            detectedFolders = SyncController.detectedCloudFolders()
            refreshQRCacheIfNeeded()
        }
        .alert(
            String(localized: "Rejoindre ce coffre de synchronisation ?"),
            isPresented: Binding(
                get: { sync.pendingPairingURI != nil },
                set: { if !$0 { sync.cancelPendingPairing() } }
            )
        ) {
            Button(String(localized: "Annuler"), role: .cancel) {
                sync.cancelPendingPairing()
            }
            Button(String(localized: "Connecter")) {
                sync.confirmPendingPairing(model: model)
                refreshQRCacheIfNeeded()
            }
        } message: {
            Text(String(localized: "Ce lien remplacera ta configuration de synchronisation actuelle par : \(sync.pendingPairingSummary ?? ""). Ne valide que si ce lien vient de l'un de tes appareils."))
        }

        Section("Activation") {
            Toggle("Activer la synchronisation", isOn: Binding(
                get: { sync.config.enabled },
                set: { enabled in
                    if enabled && sync.config.backend == .off {
                        sync.config.backend = .folder
                    }
                    sync.config.enabled = enabled
                    if enabled { _ = sync.ensureSyncKey() }
                    sync.saveConfig()
                    if enabled, sync.config.isStorageConfigured {
                        Task { await sync.syncNow(model: model) }
                    }
                }
            ))
            TextField("Nom de cet appareil", text: Binding(
                get: { sync.config.deviceName },
                set: { sync.config.deviceName = $0; sync.saveConfig() }
            ))
            Toggle("Synchroniser les réglages d'écriture (langue, correction, tons)", isOn: Binding(
                get: { sync.config.syncSharedSettings },
                set: { sync.config.syncSharedSettings = $0; sync.saveConfig() }
            ))
        }

        Section("Stockage (BYOS)") {
            Picker("Mode de stockage", selection: Binding(
                get: { effectiveBackend },
                set: {
                    sync.config.backend = $0
                    sync.connectionStatus = .idle
                    sync.saveConfig()
                    refreshQRCacheIfNeeded()
                }
            )) {
                Text("Dossier").tag(SyncBackendKind.folder)
                Text("Cloudflare R2 / S3").tag(SyncBackendKind.s3)
                Text("WebDAV").tag(SyncBackendKind.webdav)
            }
            .pickerStyle(.segmented)

            switch effectiveBackend {
            case .off, .folder:
                folderConfig
            case .s3:
                s3Config
            case .webdav:
                webdavConfig
            }
        }

        Section("État et actions") {
            HStack(spacing: 10) {
                Button("Tester la connexion") {
                    Task { await sync.testConnection() }
                }
                .disabled(sync.connectionStatus == .testing)

                Button("Synchroniser maintenant") {
                    Task { await sync.syncNow(model: model) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sync.config.enabled || !sync.config.isStorageConfigured || sync.isSyncing)

                Spacer()
                statusLabel
            }
            if let summary = sync.lastSummary {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let err = sync.lastError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }
        }

        Section("Connecter un iPhone, un PC Windows ou un autre Mac") {
            if let uri = sync.pairingURI() {
                HStack(spacing: 10) {
                    Button(showQR ? String(localized: "Masquer le QR code") : String(localized: "Afficher le QR code")) {
                        showQR.toggle()
                        if showQR { refreshQRCacheIfNeeded() }
                    }
                    Button(copiedLink ? String(localized: "Lien copié") : String(localized: "Copier le lien d'appairage")) {
                        sync.copyPairingURI(uri)
                        copiedLink = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedLink = false
                        }
                    }
                }
                if showQR, let image = cachedQRImage {
                    HStack(spacing: 16) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 170, height: 170)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scanne ce QR code depuis Wispad iOS, ou colle le lien sur Wispad Windows.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("Ce lien contient ta clé de chiffrement locale : ne le partage jamais publiquement.")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Text("Complète d'abord la configuration du stockage ci-dessus pour générer un QR code d'appairage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Rejoindre un coffre existant")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    SecureField("", text: $pairingInput, prompt: Text(verbatim: "wispad-sync://v1?data=…"))
                        .textFieldStyle(.roundedBorder)
                    Button("Connecter") {
                        if sync.applyPairingURI(pairingInput) {
                            pairingInput = ""
                            refreshQRCacheIfNeeded()
                            importFeedback = String(localized: "Coffre connecté : synchronisation lancée.")
                            if sync.config.enabled {
                                Task { await sync.syncNow(model: model) }
                            }
                        } else {
                            importFeedback = sync.lastError
                        }
                    }
                    .disabled(pairingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let msg = importFeedback {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshQRCacheIfNeeded() {
        let uri = sync.pairingURI() ?? ""
        guard uri != cachedQRURI else { return }
        cachedQRURI = uri
        cachedQRImage = uri.isEmpty ? nil : SyncController.qrImage(from: uri, dimension: 190)
    }

    @ViewBuilder
    private var folderConfig: some View {
        if !detectedFolders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configuration en un clic")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(detectedFolders) { folder in
                        Button {
                            sync.config.backend = .folder
                            sync.config.folderPath = folder.path
                            _ = sync.ensureSyncKey()
                            sync.config.enabled = true
                            sync.connectionStatus = .idle
                            sync.saveConfig()
                            refreshQRCacheIfNeeded()
                            Task { await sync.syncNow(model: model) }
                        } label: {
                            Label(folder.name, systemImage: folder.symbol)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        HStack(spacing: 8) {
            TextField("Chemin du dossier", text: Binding(
                get: { sync.config.folderPath },
                set: { sync.config.folderPath = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
            ))
            .textFieldStyle(.roundedBorder)
            Button("Choisir…") {
                chooseFolder()
            }
        }
        Text("Tous les fichiers écrits dans ce dossier sont chiffrés localement avant d'être synchronisés par iCloud Drive, OneDrive, Dropbox ou Syncthing.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var s3Config: some View {
        HStack {
            Text("Cloudflare R2 offre 10 Go gratuits sans frais de sortie (suffisant pour des millions de dictées texte).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            if let url = URL(string: "https://dash.cloudflare.com/?to=/:account/r2/overview") {
                Link("Ouvrir Cloudflare R2", destination: url)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
        Toggle("Endpoint S3 personnalisé (Backblaze B2, MinIO, AWS)", isOn: Binding(
            get: { sync.config.useCustomS3Endpoint },
            set: { sync.config.useCustomS3Endpoint = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        if !sync.config.useCustomS3Endpoint {
            TextField("ID de compte Cloudflare", text: Binding(
                get: { sync.config.cloudflareAccountId },
                set: { sync.config.cloudflareAccountId = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
            ))
        } else {
            TextField("Endpoint S3 (https://…)", text: Binding(
                get: { sync.config.s3.endpoint },
                set: { sync.config.s3.endpoint = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
            ))
            TextField("Région (ex. auto, us-east-1)", text: Binding(
                get: { sync.config.s3.region },
                set: { sync.config.s3.region = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
            ))
        }
        TextField("Nom du bucket", text: Binding(
            get: { sync.config.s3.bucket },
            set: { sync.config.s3.bucket = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        TextField("Access Key ID", text: Binding(
            get: { sync.config.s3.accessKeyId },
            set: { sync.config.s3.accessKeyId = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        SecureField("Secret Access Key", text: Binding(
            get: { sync.config.s3.secretAccessKey },
            set: { sync.config.s3.secretAccessKey = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
    }

    @ViewBuilder
    private var webdavConfig: some View {
        TextField("URL WebDAV (ex. https://cloud.exemple.org/remote.php/dav/files/nom/WispadSync)", text: Binding(
            get: { sync.config.webdav.url },
            set: { sync.config.webdav.url = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        TextField("Sous-dossier optionnel (laisser vide si déjà dans l'URL)", text: Binding(
            get: { sync.config.webdav.prefix },
            set: { sync.config.webdav.prefix = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        TextField("Identifiant", text: Binding(
            get: { sync.config.webdav.username },
            set: { sync.config.webdav.username = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
        SecureField("Mot de passe ou mot de passe d'application", text: Binding(
            get: { sync.config.webdav.password },
            set: { sync.config.webdav.password = $0; sync.connectionStatus = .idle; sync.saveConfig(); refreshQRCacheIfNeeded() }
        ))
    }

    @ViewBuilder
    private var statusLabel: some View {
        if sync.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Synchronisation…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch sync.connectionStatus {
            case .idle:
                if let date = sync.lastSyncedAt {
                    Text("Dernière synchro : \(date.formatted(.dateTime.hour().minute().locale(appLocale)))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            case .testing:
                ProgressView().controlSize(.small)
            case .ok:
                Label(String(localized: "Connecté"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
            case .failed:
                Label(String(localized: "Échec"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choisir")
        if panel.runModal() == .OK, let url = panel.url {
            sync.config.backend = .folder
            sync.config.folderPath = url.path
            _ = sync.ensureSyncKey()
            sync.connectionStatus = .idle
            sync.saveConfig()
            refreshQRCacheIfNeeded()
        }
    }
}
