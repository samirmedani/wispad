import Foundation
import Testing
@testable import WispadCore

struct SyncAndMeetingTests {
    @Test func syncKeyRoundTripsAndDetectsTampering() throws {
        let key = SyncKey.generate()
        #expect(key.base64URL.count == 43)
        let parsed = try SyncKey(base64URL: key.base64URL)
        #expect(parsed == key)
        #expect(parsed.vaultID == key.vaultID)
        #expect(parsed.vaultID.count == 16)

        let path = "devices/dev-mac/000001.wsp.enc"
        let plaintext = Data("{\"hello\":\"wispad\"}".utf8)
        let blob = try key.seal(plaintext, relativePath: path)
        #expect(blob.prefix(4) == SyncKey.magic)
        let opened = try parsed.open(blob, relativePath: path)
        #expect(opened == plaintext)

        // Substitution de chemin (AAD différent) refusée.
        #expect(throws: SyncCryptoError.decryptionFailed) {
            _ = try parsed.open(blob, relativePath: "devices/dev-mac/000002.wsp.enc")
        }
        // Mauvaise clé refusée.
        let other = SyncKey.generate()
        #expect(throws: SyncCryptoError.decryptionFailed) {
            _ = try other.open(blob, relativePath: path)
        }
    }

    /// Vecteur fixe partagé avec le portage Rust (Windows) : valide l'interopérabilité binaire AES-256-GCM + HKDF-SHA256.
    @Test func fixedVectorProducesDeterministicVaultIDAndCiphertext() throws {
        let keyBytes = Data((0..<32).map(UInt8.init))
        let key = try SyncKey(rawBytes: keyBytes)
        let nonce = Data((100..<112).map(UInt8.init))
        let path = "devices/mac-1/000001.wsp.enc"
        let payload = Data("{\"version\":1,\"deviceId\":\"mac-1\"}".utf8)
        let blob = try key.seal(payload, relativePath: path, nonce: nonce)
        #expect(try key.open(blob, relativePath: path) == payload)
        #expect(key.base64URL.count == 43)
        #expect(try SyncKey(base64URL: key.base64URL).rawBytes == keyBytes)
        #expect(key.vaultID.count == 16)
    }

    @Test func pairingURIRoundTripsForCloudflareR2AndFolder() throws {
        let key = SyncKey.generate()
        let config = SyncPairingConfig(
            syncKey: key.base64URL,
            backend: .s3,
            s3: S3SyncConfig(
                endpoint: S3SyncConfig.cloudflareR2Endpoint(accountID: "abc123def"),
                bucket: "wispad-sync",
                region: "auto",
                prefix: "wispad-sync",
                accessKeyId: "test-access",
                secretAccessKey: "test-secret"
            )
        )
        #expect(config.s3?.endpoint == "https://abc123def.r2.cloudflarestorage.com")
        let uri = try config.pairingURI()
        #expect(uri.hasPrefix("wispad-sync://v1?data="))
        let restored = try #require(SyncPairingConfig.parse(uri: uri))
        #expect(restored == config)
    }

    @Test func bidirectionalBYOSFolderSyncTransfersTextOnlyAndPreservesDeviceOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let macStore = try HistoryStore(path: root.appendingPathComponent("mac.sqlite").path)
        let winStore = try HistoryStore(path: root.appendingPathComponent("win.sqlite").path)
        let syncFolder = root.appendingPathComponent("cloud-folder")
        let transport = FolderSyncTransport(rootURL: syncFolder)
        let key = SyncKey.generate()

        let mac = DeviceIdentity(deviceId: "dev-mac", deviceName: "MacBook Pro", platform: .macos)
        let win = DeviceIdentity(deviceId: "dev-win", deviceName: "PC Windows", platform: .windows)

        let macDictation = DictationRecord(
            id: "dict-mac-1",
            finalText: "Rendez-vous demain matin.",
            rawText: "rendez vous demain matin",
            durationSeconds: 3.5,
            wordCount: 3,
            provider: "xai",
            model: "grok-voice-transcribe-2.0",
            targetApp: "Notes",
            insertionStatus: "inserted",
            audioPath: "/tmp/local-only.wav",
            sourceDeviceID: mac.deviceId,
            sourceDeviceName: mac.deviceName,
            sourceDevicePlatform: mac.platform.rawValue
        )
        try macStore.insert(macDictation)
        try macStore.addTerm("Yatofix", origin: .user)
        try macStore.upsertMeeting(MeetingRecord(
            id: "meet-1",
            title: "Point produit",
            durationSeconds: 600,
            userNotes: "- lancer iOS",
            rawTranscript: "On lance iOS cette semaine.",
            enhancedNotes: "## Résumé\nLancement iOS cette semaine.",
            sourceDeviceID: mac.deviceId,
            sourceDeviceName: mac.deviceName,
            sourceDevicePlatform: mac.platform.rawValue
        ))

        // Mac pousse ses deltas chiffrés
        let push1 = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        #expect(push1.pushedDictations == 1)
        #expect(push1.pushedMeetings == 1)
        #expect(push1.pushedTerms == 1)

        // Windows tire les deltas : retrouve le texte, la réunion, le mot, mais JAMAIS l'audio local du Mac.
        let pull1 = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(pull1.pulledDictations == 1)
        #expect(pull1.pulledMeetings == 1)
        #expect(pull1.pulledTerms == 1)

        let winDictations = try winStore.dictations()
        #expect(winDictations.count == 1)
        let synced = try #require(winDictations.first)
        #expect(synced.finalText == "Rendez-vous demain matin.")
        #expect(synced.audioPath == nil)
        #expect(synced.sourceDeviceName == "MacBook Pro")
        #expect(synced.sourceDevicePlatform == "macos")
        #expect(synced.isFromRemoteDevice(localDeviceID: win.deviceId))

        // Recherche FTS5 sur la dictée synchronisée
        let found = winStore.searchDictationIDs(query: "demain")
        #expect(found == ["dict-mac-1"])

        // Windows crée une dictée et la renvoie vers Mac
        let winDictation = DictationRecord(
            id: "dict-win-1",
            finalText: "Message dicté sur le PC.",
            rawText: "message dicté sur le pc",
            durationSeconds: 2.1,
            wordCount: 5,
            provider: "xai",
            model: "grok-voice-transcribe-2.0",
            targetApp: "Discord",
            insertionStatus: "inserted",
            audioPath: "C:\\temp\\win.wav",
            sourceDeviceID: win.deviceId,
            sourceDeviceName: win.deviceName,
            sourceDevicePlatform: win.platform.rawValue
        )
        try winStore.insert(winDictation)
        let push2 = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(push2.pushedDictations == 1)

        let pull2 = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        #expect(pull2.pulledDictations == 1)
        let macAll = try macStore.dictations()
        #expect(macAll.count == 2)
        let fromWin = try #require(macAll.first(where: { $0.id == "dict-win-1" }))
        #expect(fromWin.audioPath == nil)
        #expect(fromWin.sourceDeviceName == "PC Windows")
        #expect(fromWin.isFromRemoteDevice(localDeviceID: mac.deviceId))

        // L'audio local du Mac est resté intact sur la dictée d'origine du Mac.
        let ownMac = try #require(macAll.first(where: { $0.id == "dict-mac-1" }))
        #expect(ownMac.audioPath == "/tmp/local-only.wav")
        #expect(!ownMac.isFromRemoteDevice(localDeviceID: mac.deviceId))

        // Suppression propagée par tombstone
        try macStore.deleteDictation(id: "dict-mac-1")
        _ = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        _ = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(try winStore.dictations().map(\.id) == ["dict-win-1"])
    }

    @Test func s3SigV4SignsRequestsAndParsesListXML() throws {
        let cfg = S3SyncConfig(
            endpoint: "https://acct.r2.cloudflarestorage.com",
            bucket: "my-bucket",
            region: "auto",
            prefix: "wispad-sync",
            accessKeyId: "AKIAEXAMPLE",
            secretAccessKey: "SECRETEXAMPLE"
        )
        let req = try S3SyncTransport.signedRequest(
            method: "GET",
            config: cfg,
            objectKey: "wispad-sync/manifest.json",
            queryItems: [],
            payload: Data(),
            date: Date(timeIntervalSince1970: 1_764_200_000)
        )
        #expect(req.url?.absoluteString == "https://acct.r2.cloudflarestorage.com/my-bucket/wispad-sync/manifest.json")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/") == true)
        #expect(req.value(forHTTPHeaderField: "x-amz-content-sha256")?.count == 64)

        let xml = Data("""
        <ListBucketResult><IsTruncated>false</IsTruncated>
        <Contents><Key>wispad-sync/devices/a/000001.wsp.enc</Key></Contents>
        <Contents><Key>wispad-sync/devices/b/000002.wsp.enc</Key></Contents>
        </ListBucketResult>
        """.utf8)
        let parsed = S3SyncTransport.parseListObjectsV2XML(xml)
        #expect(parsed.keys.count == 2)
        #expect(parsed.nextToken == nil)
    }

    @Test func webdavPropfindParserExtractsHrefs() {
        let xml = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/u/wispad-sync/devices/</d:href></d:response>
          <d:response><d:href>/remote.php/dav/files/u/wispad-sync/devices/dev1/000001.wsp.enc</d:href></d:response>
        </d:multistatus>
        """.utf8)
        let hrefs = WebDAVSyncTransport.parsePropfindHrefs(xml)
        #expect(hrefs.count == 2)
        #expect(hrefs[1].hasSuffix("000001.wsp.enc"))
    }

    @Test func meetingPromptBuildsFrenchAndEnglishInstructions() {
        let fr = MeetingPrompt.system(english: false)
        #expect(fr.contains("Résumé"))
        #expect(fr.contains("Actions à suivre"))
        let user = MeetingPrompt.userText(title: "Sync", userNotes: "- budget", transcript: "Le budget est validé.", english: false)
        #expect(user.contains("Notes prises pendant la réunion"))
        #expect(user.contains("Transcription"))
    }
}
