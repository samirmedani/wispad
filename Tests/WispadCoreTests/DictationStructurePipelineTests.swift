import Foundation
import Testing
@testable import WispadCore

/// Requêtes de correction simulées : aucune clé réelle, aucun réseau et aucune fenêtre.
private actor StructurePipelineHTTPStub {
    enum Step: Sendable {
        case reply(String, reportsUsage: Bool = true)
        case failure
    }

    struct Call: Sendable {
        var host: String
        var system: String
        var user: String
    }

    private var steps: [Step]
    private(set) var calls: [Call] = []

    init(_ steps: [Step]) { self.steps = steps }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]] ?? []
        calls.append(Call(
            host: request.url?.host ?? "",
            system: messages.first(where: { $0["role"] == "system" })?["content"] ?? "",
            user: messages.first(where: { $0["role"] == "user" })?["content"] ?? ""
        ))
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .failure:
            throw URLError(.timedOut)
        case .reply(let content, let reportsUsage):
            var payload: [String: Any] = [
                "choices": [["message": ["content": content], "finish_reason": "stop"]]
            ]
            if reportsUsage { payload["usage"] = ["prompt_tokens": 10, "completion_tokens": 5] }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: payload), response)
        }
    }
}

struct DictationStructurePipelineTests {
    private static let semanticTranscript = "Pour demain il faut vérifier le build lancer les tests et publier la release. Je reste disponible pour relire le résultat."
    private static let semanticOutput = """
    Pour demain, il faut :
    - Vérifier le build.
    - Lancer les tests.
    - Publier la release.

    Je reste disponible pour relire le résultat.
    """
    private static let explicitTranscript = "Première puce vérifier le build. Deuxième puce lancer les tests."
    private static let explicitOutput = "- Vérifier le build.\n- Lancer les tests."

    private static func speech(primary: Bool = true, relay: Bool = true, vocalKey: String = "fixture-vocal") -> SpeechRequest {
        SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: vocalKey,
                      language: .french, keyterms: [], prompt: "",
                      cleanupKey: primary ? "fixture-primary" : nil,
                      fallbackKey: relay ? "fixture-relay" : nil)
    }

    private static func clean(
        _ stub: StructurePipelineHTTPStub,
        transcript: String = semanticTranscript,
        structure: Bool = true,
        cleanup: Bool = true,
        speech: SpeechRequest = speech(),
        nearbyText: String? = nil
    ) async -> CleanupOutcome {
        await TextCleaner.clean(
            transcript: transcript,
            request: CorrectionRequest(transcript: transcript, nearbyText: nearbyText, structureDictation: structure),
            speech: speech,
            enabled: cleanup,
            transport: { try await stub.request($0) }
        )
    }

    @Test func aLoneBulletWithoutASpokenCommandBecomesASentence() async {
        let transcript = "OK, ajoute à la liste dix-huit modules de seize gigas."
        let stub = StructurePipelineHTTPStub([.reply("- OK, ajoute à la liste 18 modules de 16 gigas.")])
        let result = await Self.clean(stub, transcript: transcript)
        #expect(result.text == "OK, ajoute à la liste 18 modules de 16 gigas.")
        let system = await stub.calls.first?.system ?? ""
        #expect(system.contains("« OK, ajoute à la liste »"))
        #expect(system.contains("« rajoute »"))
    }

    @Test func semanticBulletsAndParagraphsUseTheExistingSingleCorrectionCall() async throws {
        let stub = StructurePipelineHTTPStub([.reply(Self.semanticOutput)])
        let result = await Self.clean(stub)
        #expect(result.text == Self.semanticOutput)
        #expect(result.text.components(separatedBy: "\n\n").count == 2)
        #expect(result.text.split(separator: "\n").filter { $0.hasPrefix("- ") }.count == 3)
        let usage = try #require(result.usage)
        #expect(usage.api == .deepSeekCleanup)
        #expect(usage.tokens == TokenUsage(input: 10, output: 5))
        #expect(usage.succeeded)
        #expect(usage.fallback == nil)
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.calls.map(\.host) == ["api.deepseek.com"])
    }

    @Test func relayPreservesEveryLineAndCountsOnlyTheExistingRequests() async throws {
        let stub = StructurePipelineHTTPStub([.failure, .reply(Self.semanticOutput)])
        let result = await Self.clean(stub)
        #expect(result.text == Self.semanticOutput)
        let usage = try #require(result.usage)
        #expect(usage.api == .openAICleanup)
        #expect(usage.tokens == TokenUsage(input: 10, output: 5))
        #expect(usage.succeeded)
        #expect(usage.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(result.fallback == "OpenAI")
        #expect(result.failedUsages.count == 1)
        #expect(result.failedUsages.first?.api == .deepSeekCleanup)
        #expect(result.failedUsages.first?.costUSD == nil)
        #expect(result.failedUsages.first?.id != usage.id)
        #expect(await stub.calls.map(\.host) == ["api.deepseek.com", "api.openai.com"])
    }

    @Test func disabledCleanupStillFormatsExplicitCommandsLocallyWithoutUsage() async {
        let stub = StructurePipelineHTTPStub([])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript, cleanup: false)
        #expect(result.text == Self.explicitOutput)
        #expect(result.usage == nil)
        #expect(result.failedUsages.isEmpty)
        #expect(result.fallback == nil)
        #expect(await stub.calls.isEmpty)
    }

    @Test func optingOutWithCleanupDisabledReturnsTheUnstructuredDictation() async {
        let stub = StructurePipelineHTTPStub([])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript, structure: false, cleanup: false)
        #expect(result.text == Self.explicitTranscript)
        #expect(result.usage == nil)
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.calls.isEmpty)
    }

    @Test func missingRoutesStillFormatExplicitCommandsWithoutInventingAnAPICall() async {
        let stub = StructurePipelineHTTPStub([])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript,
                                     speech: Self.speech(primary: false, relay: false, vocalKey: ""))
        #expect(result.text == Self.explicitOutput)
        #expect(result.usage == nil)
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.calls.isEmpty)
    }

    @Test func failedServicesKeepTheLocalListAndUnknownCosts() async throws {
        let stub = StructurePipelineHTTPStub([.failure, .failure])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript)
        #expect(result.text == Self.explicitOutput)
        let last = try #require(result.usage)
        let calls = result.failedUsages + [last]
        #expect(calls.map(\.api) == [.deepSeekCleanup, .openAICleanup])
        #expect(calls.allSatisfy { !$0.succeeded && $0.costUSD == nil && $0.tokens == TokenUsage() })
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(last.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(result.fallback == nil)
        #expect(await stub.calls.count == 2)
    }

    @Test func optingOutPreservesRawCommandsWhenServicesFail() async {
        let stub = StructurePipelineHTTPStub([.failure, .failure])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript, structure: false)
        #expect(result.text == Self.explicitTranscript)
        #expect(result.failedUsages.count == 1)
        #expect(await stub.calls.count == 2)
    }

    @Test func tenShortNumberedItemsAreNotRejectedAsAddedContent() async {
        let items = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet"]
        let transcript = items.joined(separator: " ")
        let output = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let stub = StructurePipelineHTTPStub([.reply(output)])
        let result = await Self.clean(stub, transcript: transcript)
        #expect(result.text == output)
        #expect(result.text.split(separator: "\n").count == 10)
        #expect(await stub.calls.count == 1)
    }

    @Test func restoringAnEnglishWordKeepsBulletAndParagraphWhitespace() async {
        let transcript = "L'agent sélectionne le bon tool. Ensuite il vérifie le build. On publie demain."
        let modelOutput = "- L'agent sélectionne le bon outil.\n- Ensuite, il vérifie le build.\n\nOn publie demain."
        let expected = "- L'agent sélectionne le bon tool.\n- Ensuite, il vérifie le build.\n\nOn publie demain."
        let stub = StructurePipelineHTTPStub([.reply(modelOutput)])
        let result = await Self.clean(stub, transcript: transcript)
        #expect(result.text == expected)
        #expect(await stub.calls.count == 1)
    }

    @Test func modelMarkdownWrapperIsRemovedWithoutLeavingItsLanguageTag() async {
        let stub = StructurePipelineHTTPStub([.reply("```markdown\n\(Self.semanticOutput)\n```")])
        let result = await Self.clean(stub)
        #expect(result.text == Self.semanticOutput)
        #expect(!result.text.contains("```"))
        #expect(!result.text.hasPrefix("markdown"))
        #expect(await stub.calls.count == 1)
    }

    @Test func successfulStructuringWithoutReportedTokensKeepsCostUnknown() async throws {
        let stub = StructurePipelineHTTPStub([.reply(Self.semanticOutput, reportsUsage: false)])
        let result = await Self.clean(stub)
        #expect(result.text == Self.semanticOutput)
        let usage = try #require(result.usage)
        #expect(usage.succeeded)
        #expect(usage.costUSD == nil)
        #expect(usage.tokens == TokenUsage())
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.calls.count == 1)
    }

    @Test(arguments: [true, false])
    func primaryAndRelayReceiveTheSameRequestedStructuringMode(structure: Bool) async throws {
        let output = structure ? Self.semanticOutput : Self.semanticTranscript
        let stub = StructurePipelineHTTPStub([.failure, .reply(output)])
        let result = await Self.clean(stub, structure: structure)
        #expect(result.text == output)
        let calls = await stub.calls
        #expect(calls.map(\.host) == ["api.deepseek.com", "api.openai.com"])
        let first = try #require(calls.first)
        let last = try #require(calls.last)
        #expect(!first.system.isEmpty)
        #expect(first.system == last.system)
        #expect(first.user == last.user)
        #expect(first.user.contains(Self.semanticTranscript))
        let enabled = CorrectionPrompt.system(for: CorrectionRequest(transcript: Self.semanticTranscript, structureDictation: true))
        let disabled = CorrectionPrompt.system(for: CorrectionRequest(transcript: Self.semanticTranscript, structureDictation: false))
        #expect(enabled != disabled)
        #expect(first.system == (structure ? enabled : disabled))
        #expect(result.failedUsages.count == 1)
    }

    @Test func rejectedContextCopyFallsBackToTheExplicitListWithTheActualUsage() async throws {
        let context = "La prochaine réunion aura lieu mercredi dans la grande salle du bâtiment principal."
        let stub = StructurePipelineHTTPStub([.reply(context + "\n" + Self.explicitOutput)])
        let result = await Self.clean(stub, transcript: Self.explicitTranscript, nearbyText: context)
        #expect(result.text == Self.explicitOutput)
        #expect(!result.text.contains("réunion"))
        let usage = try #require(result.usage)
        #expect(usage.succeeded)
        #expect(usage.tokens == TokenUsage(input: 10, output: 5))
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.calls.count == 1)
    }

    @Test(arguments: [
        (
            "```markdown\n- Vérifier le build.\n- Lancer les tests.\n\nOn publie demain.\n```",
            "Vérifier le build. Lancer les tests. On publie demain.",
            "- Vérifier le build.\n- Lancer les tests.\n\nOn publie demain."
        ),
        (
            "```plaintext\nBonjour.\n\nMerci pour ton aide.\n```",
            "Bonjour. Merci pour ton aide.",
            "Bonjour.\n\nMerci pour ton aide."
        ),
        (
            "~~~markdown\n- Vérifier le build.\n- Lancer les tests.\n~~~",
            "Vérifier le build. Lancer les tests.",
            "- Vérifier le build.\n- Lancer les tests."
        ),
        (
            "```swift\nlet fixture = 1\n```",
            "```swift\nlet fixture = 1\n```",
            "```swift\nlet fixture = 1\n```"
        ),
        (
            "```text\nExemple dicté.\n```",
            "```text\nExemple dicté.\n```",
            "```text\nExemple dicté.\n```"
        ),
        (
            "```json\n{\"fixture\": 1}\n```",
            "Une fixture vaut 1.",
            "```json\n{\"fixture\": 1}\n```"
        ),
        (
            "```markdown\n- Vérifier le build.\n- Lancer les tests.",
            "Vérifier le build. Lancer les tests.",
            "```markdown\n- Vérifier le build.\n- Lancer les tests."
        ),
        (
            "Bonjour.\n\nMerci.\n```",
            "Bonjour. Merci.",
            "Bonjour.\n\nMerci.\n```"
        ),
        (
            "```markdown\nUn exemple :\n```swift\nlet fixture = 1\n```\n\nMerci.\n```",
            "Un exemple. Merci.",
            "Un exemple :\n```swift\nlet fixture = 1\n```\n\nMerci."
        )
    ])
    func modelWrapperCleaningPreservesLiteralCodeAndInnerLayout(_ fixture: (String, String, String)) {
        #expect(CorrectionPrompt.cleanModelOutput(fixture.0, fallback: fixture.1) == fixture.2)
    }
}
