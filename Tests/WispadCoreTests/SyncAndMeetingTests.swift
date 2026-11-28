import Foundation
import Testing
@testable import WispadCore

struct SyncAndMeetingTests {
    @Test func syncKeyRoundTripsEmptyAndNonEmptyAndDetectsTampering() throws {
        let key = SyncKey.generate()
        #expect(key.base64URL.count == 43)
        let parsed = try SyncKey(base64URL: key.base64URL)
        #expect(parsed == key)
        #expect(parsed.vaultID == key.vaultID)
        #expect(parsed.vaultID.count == 16)

        // Plaintext vide autorisé (header 4 + nonce 12 + tag 16 = 32 octets).
        let emptyBlob = try key.seal(Data(), relativePath: "devices/dev-mac/empty.wsp.enc")
        #expect(emptyBlob.count == 32)
        #expect(try parsed.open(emptyBlob, relativePath: "devices/dev-mac/empty.wsp.enc").isEmpty)

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

    @Test func pairingURIRoundTripsAndRejectsMalformedURIs() throws {
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
        // Pas de double suffixe si l'utilisateur colle l'hôte complet sans https://
        #expect(S3SyncConfig.cloudflareR2Endpoint(accountID: "abc123def.r2.cloudflarestorage.com") == "https://abc123def.r2.cloudflarestorage.com")
        let uri = try config.pairingURI()
        #expect(uri.hasPrefix("wispad-sync://v1?data="))
        let restored = try #require(SyncPairingConfig.parse(uri: uri))
        #expect(restored == config)

        // Mauvais hôte de version ou config S3 incomplète refusés.
        #expect(SyncPairingConfig.parse(uri: uri.replacingOccurrences(of: "wispad-sync://v1", with: "wispad-sync://v99")) == nil)
        let incompleteS3 = SyncPairingConfig(syncKey: key.base64URL, backend: .s3, s3: S3SyncConfig())
        let badURI = try incompleteS3.pairingURI()
        #expect(SyncPairingConfig.parse(uri: badURI) == nil)
    }

    @Test func bidirectionalBYOSFolderSyncTransfersTextOnlyWithZeroEchoLoopAndNoResurrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let macStore = try HistoryStore(path: root.appendingPathComponent("mac.sqlite").path)
        let winStore = try HistoryStore(path: root.appendingPathComponent("win.sqlite").path)
        let syncFolder = root.appendingPathComponent("cloud-folder")
        // Dossier choisi par l'utilisateur : il existe, la synchro ne le crée jamais.
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
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
        // Zéro boucle d'écho : Windows ne repousse rien qu'il vient de recevoir du Mac.
        #expect(pull1.totalPushed == 0)
        #expect(pull1.pushedSequence == nil)

        // Second cycle sans mutation : zéro push, zéro pull.
        let noopWin = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(noopWin.totalPushed == 0)
        #expect(noopWin.totalPulled == 0)

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
        #expect(pull2.totalPushed == 0)
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

        // Suppression propagée par tombstone (dictée + réunion + terme)
        try macStore.deleteDictation(id: "dict-mac-1")
        try macStore.deleteMeeting(id: "meet-1")
        if let term = try macStore.dictionary().first {
            try macStore.deleteTerm(id: term.id)
        }
        _ = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        _ = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(try winStore.dictations().map(\.id) == ["dict-win-1"])
        #expect(try winStore.meetings().isEmpty)
        #expect(try winStore.dictionary().isEmpty)

        // Survie réinstallation : nouvelle base locale avec le même deviceId n'écrase jamais 000001.wsp.enc.
        let freshMacStore = try HistoryStore(path: root.appendingPathComponent("mac-reinstall.sqlite").path)
        try freshMacStore.insert(DictationRecord(id: "dict-mac-reinstall", finalText: "Après réinstallation.", rawText: "après réinstallation", durationSeconds: 1.2, wordCount: 2, provider: "xai", model: "grok", insertionStatus: "inserted"))
        let reinstallSync = try await WispadSyncEngine.sync(store: freshMacStore, device: mac, key: key, transport: transport)
        #expect((reinstallSync.pushedSequence ?? 0) >= 3)

        // Isolation d'un fichier pair corrompu : n'empêche pas le push local ni les autres pairs.
        try await transport.put(path: "devices/dev-corrupt/000001.wsp.enc", data: Data("corrupted".utf8))
        let isolated = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        #expect(isolated.skippedPeerBlobs == 1)
    }

    @Test func s3SigV4SignsRequestsWithUnicodeAndBasePathAndParsesXML() throws {
        let cfg = S3SyncConfig(
            endpoint: "https://acct.r2.cloudflarestorage.com:443/custom-base",
            bucket: "my-bucket",
            region: "auto",
            prefix: "wispad-sync",
            accessKeyId: "TESTACCESSKEY",
            secretAccessKey: "TESTSECRETKEY"
        )
        let req = try S3SyncTransport.signedRequest(
            method: "GET",
            config: cfg,
            objectKey: "wispad-sync/devices/café 1/000001.wsp.enc",
            queryItems: [("list-type", "2")],
            payload: Data(),
            date: Date(timeIntervalSince1970: 1_764_200_000)
        )
        let urlString = try #require(req.url?.absoluteString)
        #expect(urlString.contains("/custom-base/my-bucket/wispad-sync/devices/caf%C3%A9%201/000001.wsp.enc"))
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=TESTACCESSKEY/") == true)
        #expect(req.value(forHTTPHeaderField: "x-amz-content-sha256")?.count == 64)

        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>tok+1/2=</NextContinuationToken>
          <Contents><Key>wispad-sync/devices/a&amp;b/000001.wsp.enc</Key></Contents>
          <Contents><Key>wispad-sync/devices/b/000002.wsp.enc</Key></Contents>
        </ListBucketResult>
        """.utf8)
        let parsed = S3SyncTransport.parseListObjectsV2XML(xml)
        #expect(parsed.keys == ["wispad-sync/devices/a&b/000001.wsp.enc", "wispad-sync/devices/b/000002.wsp.enc"])
        #expect(parsed.nextToken == "tok+1/2=")
    }

    @Test func webdavPropfindParserExtractsHrefsAndCollections() {
        let xml = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote.php/dav/files/u/Mon%20Dossier/devices</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/u/Mon%20Dossier/devices/dev1/000001.wsp.enc</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
        let entries = WebDAVSyncTransport.parsePropfindEntries(xml)
        #expect(entries.count == 2)
        #expect(entries[0].isCollection == true)
        #expect(entries[1].isCollection == false)
        #expect(entries[1].href.hasSuffix("000001.wsp.enc"))
    }

    @Test func wavChunkerSplitsOversizedWAVIntoValidAlignedChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-chunk-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let wavURL = root.appendingPathComponent("long-meeting.wav")
        let pcmBytes = 10_000
        var wav = WAVHeader.make(dataBytes: pcmBytes, sampleRate: 16_000)
        wav.append(Data(repeating: 0x11, count: pcmBytes))
        try wav.write(to: wavURL)

        // Sous la limite : retourne le fichier original sans découpage.
        let single = try WAVChunker.splitIfNeeded(fileURL: wavURL, maxChunkBytes: 20_000)
        #expect(single.urls == [wavURL])
        #expect(single.temporaryURLs.isEmpty)

        // Au-dessus de la limite : découpe en morceaux WAV alignés sur 2 octets avec en-tête RIFF valide.
        let split = try WAVChunker.splitIfNeeded(fileURL: wavURL, maxChunkBytes: 4_000)
        defer { for url in split.temporaryURLs { try? FileManager.default.removeItem(at: url) } }
        #expect(split.urls.count == 3)
        var totalPCM = 0
        for chunkURL in split.urls {
            let chunkData = try Data(contentsOf: chunkURL)
            #expect(chunkData.prefix(4) == Data("RIFF".utf8))
            #expect((chunkData.count - 44) % 2 == 0)
            totalPCM += chunkData.count - 44
        }
        #expect(totalPCM == pcmBytes)
    }

    @Test func meetingEnhancerReturnsEmptyWithoutRoutesInsteadOfEchoingNotes() async {
        let speech = SpeechRequest(
            provider: .xai,
            liveModel: "grok",
            fileModel: "grok",
            apiKey: "",
            language: .french,
            keyterms: [],
            prompt: ""
        )
        let outcome = await TextCleaner.enhanceMeeting(
            title: "Point",
            userNotes: "- ne pas recopier ceci comme synthèse IA",
            transcript: "",
            language: .french,
            speech: speech
        )
        #expect(outcome.text.isEmpty)
        #expect(outcome.usage == nil)
    }

    @Test func meetingPromptBuildsFrenchAndEnglishInstructions() {
        let fr = MeetingPrompt.system(english: false)
        #expect(fr.contains("Résumé"))
        #expect(fr.contains("Actions à suivre"))
        let user = MeetingPrompt.userText(title: "Sync", userNotes: "- budget", transcript: "Le budget est validé.", english: false)
        #expect(user.contains("Notes prises pendant la réunion"))
        #expect(user.contains("Transcription"))
    }

    @Test func apiCallsReachTheOtherDeviceOnceWithTheirCostAndNoEcho() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-sync-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("coffre", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let macStore = try HistoryStore(path: root.appendingPathComponent("mac.sqlite").path)
        let winStore = try HistoryStore(path: root.appendingPathComponent("win.sqlite").path)
        let transport = FolderSyncTransport(rootURL: folder)
        let key = SyncKey.generate()
        let mac = DeviceIdentity(deviceId: "dev-mac", deviceName: "MacBook Pro", platform: .macos)
        let win = DeviceIdentity(deviceId: "dev-win", deviceName: "PC Windows", platform: .windows)

        try macStore.insertUsage(UsageEvent(
            id: "appel-1", createdAt: Date(timeIntervalSince1970: 1_800_000_000), api: .deepSeekCleanup,
            model: "deepseek-flash", tokens: TokenUsage(input: 120, cachedInput: 40, output: 30), costUSD: 0.00012,
            latencyMs: 310
        ))
        try macStore.insertUsage(UsageEvent(
            id: "appel-2", createdAt: Date(timeIntervalSince1970: 1_800_000_010), api: .xaiStreaming,
            model: "grok-voice-transcribe-2.0", audioSeconds: 12, costUSD: nil, succeeded: false, failureCause: .timeout
        ))

        let pushed = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        #expect(pushed.pushedSequence == 1)
        _ = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)

        let received = try winStore.usageEvents()
        #expect(received.count == 2)
        let cleanup = try #require(received.first(where: { $0.id == "appel-1" }))
        #expect(cleanup.api == .deepSeekCleanup)
        #expect(cleanup.costUSD == 0.00012)
        #expect(cleanup.tokens == TokenUsage(input: 120, cachedInput: 40, output: 30))
        let failed = try #require(received.first(where: { $0.id == "appel-2" }))
        #expect(failed.costUSD == nil)
        #expect(!failed.succeeded)
        #expect(failed.failureCause == .timeout)

        // Reçus d'un autre appareil : jamais renvoyés, jamais comptés deux fois.
        #expect(try winStore.pendingSyncBatch(localDevice: win).apiCalls.isEmpty)
        _ = try await WispadSyncEngine.sync(store: winStore, device: win, key: key, transport: transport)
        _ = try await WispadSyncEngine.sync(store: macStore, device: mac, key: key, transport: transport)
        #expect(try macStore.usageEvents().count == 2)
        #expect(try winStore.usageEvents().count == 2)
    }

    @Test func folderTransportNeverRecreatesAMissingSyncFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-partage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        // Partage démonté : le dossier choisi n'existe plus.
        let root = parent.appendingPathComponent("WispadSync", isDirectory: true)
        let transport = FolderSyncTransport(rootURL: root)
        #expect(try await transport.list(prefix: "devices").isEmpty)
        #expect(try await transport.get(path: "manifest.json") == nil)
        await #expect(throws: SyncTransportError.folderUnavailable) {
            try await transport.put(path: "manifest.json", data: Data("{}".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // Partage revenu : l'écriture reprend, sous-dossiers compris.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await transport.put(path: "devices/dev-mac/000001.wsp.enc", data: Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("devices/dev-mac/000001.wsp.enc").path))
    }
}
