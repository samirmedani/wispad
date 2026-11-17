import CoreGraphics
import Foundation
import Testing
@testable import WispadCore

/// Choix du champ probable, sur des scènes relevées en lecture seule (Discord et X dans Chrome, 17 novembre 2026) et
/// sur les cas où il faut renoncer.
struct InputTargetingTests {
    private let discord = CGRect(x: 0, y: 33, width: 1512, height: 890)
    private let chrome = CGRect(x: 0, y: 114, width: 1512, height: 868)
    private let form = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func area(_ x: Double, _ y: Double, _ width: Double, _ height: Double, in window: CGRect) -> CGRect {
        CGRect(x: window.minX + x, y: window.minY + y, width: width, height: height)
    }

    private var discordComposer: InputCandidate {
        InputCandidate(role: "AXTextArea", frame: area(444, 825, 590, 56, in: discord), multiline: true,
                       hint: InputTargeting.normalize("Envoyer un message à @ami"),
                       domClasses: ["markup_ku1OHH", "editor_SHcSVi", "slateTextArea_q99V_-"], landmark: .main)
    }

    private var discordSearch: InputCandidate {
        InputCandidate(role: "AXTextArea", frame: area(1261, 47, 218, 22, in: discord), multiline: true, length: 23,
                       hint: InputTargeting.normalize("Rechercher ami"), domClasses: ["editor_uNafB1"])
    }

    private var xCompose: InputCandidate {
        InputCandidate(role: "AXTextArea", frame: area(572, 76, 514, 28, in: chrome), multiline: true,
                       hint: InputTargeting.normalize("Quoi de neuf ?!"),
                       domClasses: ["notranslate", "public-DraftEditor-content"], landmark: .main)
    }

    private var xSearch: InputCandidate {
        InputCandidate(role: "AXComboBox", frame: area(1165, 9, 318, 40, in: chrome),
                       hint: InputTargeting.normalize("Requête de recherche"), domClasses: ["r-30o5oe"], landmark: .banner)
    }

    @Test func theMessageBoxWinsOverTheSearchEvenWithAnUnreadableFocus() {
        for strict in [false, true] {
            let scene = InputScene(window: discord, strict: strict)
            #expect(InputTargeting.choose([discordSearch, discordComposer], in: scene)?.index == 1)
        }
        #expect(InputTargeting.choose([xSearch, xCompose], in: InputScene(window: chrome))?.index == 1)
    }

    /// Codex, relevé le 17 novembre 2026 : seul champ de la fenêtre, en bas, éditeur ProseMirror. Choisi même quand
    /// Codex n'annonce pas son focus.
    @Test func theCodexComposerIsChosenEvenWithAnUnreadableFocus() {
        let window = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let composer = InputCandidate(role: "AXTextArea", frame: area(447, 845, 713, 40, in: window), multiline: true,
                                      hint: InputTargeting.normalize("Travaillez avec Codex"),
                                      domClasses: ["ProseMirror"])
        #expect(InputTargeting.choose([composer], in: InputScene(window: window, strict: true))?.index == 0)
        #expect(InputTargeting.score(composer, in: InputScene(window: window)) >= 7.5)
    }

    /// Fenêtre de réponse ouverte par-dessus le fil : elle passe devant la zone de la page.
    @Test func aReplyDialogComesBeforeThePage() {
        let reply = InputCandidate(role: "AXTextArea", frame: area(500, 200, 500, 100, in: chrome), multiline: true,
                                   hint: InputTargeting.normalize("Postez votre réponse"),
                                   domClasses: ["public-DraftEditor-content"], inDialog: true)
        #expect(InputTargeting.choose([xCompose, xSearch, reply], in: InputScene(window: chrome))?.index == 2)
    }

    @Test func similarFormFieldsOrALoneSearchGiveNoChoice() {
        let fields = ["Nom", "Prénom", "E-mail"].enumerated().map { index, label in
            InputCandidate(role: "AXTextField", frame: area(100, 100 + Double(index) * 50, 300, 30, in: form),
                           hint: InputTargeting.normalize(label))
        }
        #expect(InputTargeting.choose(fields, in: InputScene(window: form)) == nil)
        #expect(InputTargeting.choose([xSearch], in: InputScene(window: chrome)) == nil)
        #expect(InputTargeting.choose([], in: InputScene(window: chrome)) == nil)
        // Un seul champ ordinaire, focus lisible : c'est lui.
        let lone = InputCandidate(role: "AXTextField", frame: area(100, 100, 300, 30, in: form))
        #expect(InputTargeting.choose([lone], in: InputScene(window: form))?.index == 0)
    }

    /// Deux zones de commentaire identiques : sans indice, rien ; un clic sur l'une la désigne.
    @Test func aClickSettlesTwoIdenticalBoxes() {
        let boxes = [300.0, 600.0].map { y in
            InputCandidate(role: "AXTextArea", frame: area(300, y, 600, 60, in: form), multiline: true,
                           hint: InputTargeting.normalize("Ajouter un commentaire"))
        }
        #expect(InputTargeting.choose(boxes, in: InputScene(window: form)) == nil)
        var clicked = boxes
        clicked[0].clickHit = true
        let choice = InputTargeting.choose(clicked, in: InputScene(window: form, click: CGPoint(x: 400, y: 320)))
        #expect(choice?.index == 0 && choice?.signals == ["clic"])
        // Un clic juste à côté de la première compte aussi, sans la toucher.
        #expect(InputTargeting.score(boxes[0], in: InputScene(window: form, click: CGPoint(x: 400, y: 290)))
            > InputTargeting.score(boxes[1], in: InputScene(window: form, click: CGPoint(x: 400, y: 290))))
    }

    /// Fil de discussion et salon ouverts côte à côte : le champ où la dictée a commencé l'emporte.
    @Test func theStartFieldSettlesTwoMessageBoxes() {
        let window = CGRect(x: 0, y: 0, width: 1400, height: 800)
        var thread = InputCandidate(role: "AXTextArea", frame: area(900, 700, 400, 60, in: window), multiline: true,
                                    hint: InputTargeting.normalize("Envoyer un message"))
        let channel = InputCandidate(role: "AXTextArea", frame: area(300, 700, 500, 60, in: window), multiline: true,
                                     hint: InputTargeting.normalize("Envoyer un message"))
        #expect(InputTargeting.choose([thread, channel], in: InputScene(window: window)) == nil)
        thread.isStart = true
        #expect(InputTargeting.choose([thread, channel], in: InputScene(window: window))?.index == 0)
    }

    /// Focus illisible ou parcours incomplet : un champ quelconque ne suffit plus, il faut un signal ou une évidence.
    @Test func anUnreadableFocusOrAPartialScanNeedsStrongEvidence() {
        var lone = InputCandidate(role: "AXTextField", frame: area(100, 100, 300, 30, in: form))
        #expect(InputTargeting.choose([lone], in: InputScene(window: form, strict: true)) == nil)
        lone.isLastTarget = true
        #expect(InputTargeting.choose([lone], in: InputScene(window: form, strict: true))?.signals == ["dernier"])
        var composer = discordComposer
        #expect(InputTargeting.choose([composer], in: InputScene(window: discord, complete: false)) == nil)
        composer.learned = 3
        #expect(InputTargeting.choose([composer], in: InputScene(window: discord, complete: false))?.signals == ["habitude"])
    }

    /// Note déjà écrite, seule zone de la fenêtre : la dictée peut s'y ajouter à la fin.
    @Test func aFilledNoteCanStillBeTheOnlyChoice() {
        let note = InputCandidate(role: "AXTextArea", frame: area(300, 50, 900, 700, in: form), multiline: true,
                                  length: 420, caretMovable: true)
        #expect(InputTargeting.choose([note], in: InputScene(window: form))?.index == 0)
        var locked = note
        locked.caretMovable = false
        #expect(InputTargeting.score(locked, in: InputScene(window: form)) < InputTargeting.score(note, in: InputScene(window: form)))
    }

    @Test func hintsAreComparedWithoutAccentsOrCurlyApostrophes() {
        #expect(InputTargeting.normalize("Écris à Léa\u{2019}s") == "ecris a lea's")
    }

    // MARK: - Habitudes

    @Test func signaturesAndPlacesAreStableAndOpaque() {
        let first = InputTargeting.signature(role: "AXTextArea", multiline: true, domIdentifier: "prompt-textarea",
                                             domClasses: ["ProseMirror"], frame: area(200, 700, 800, 60, in: form),
                                             window: form)
        let again = InputTargeting.signature(role: "AXTextArea", multiline: true, domIdentifier: "prompt-textarea",
                                             domClasses: ["ProseMirror"], frame: area(210, 690, 790, 70, in: form),
                                             window: form)
        let top = InputTargeting.signature(role: "AXTextArea", multiline: true, domIdentifier: "prompt-textarea",
                                           domClasses: ["ProseMirror"], frame: area(200, 40, 800, 60, in: form),
                                           window: form)
        #expect(first == again && first != top)
        #expect(!first.contains("prompt"))
        let place = InputTargeting.placeKey(bundleID: "com.google.Chrome", host: "x.com")
        #expect(place == InputTargeting.placeKey(bundleID: "com.google.Chrome", host: "X.com"))
        #expect(place != InputTargeting.placeKey(bundleID: "com.google.Chrome", host: "discord.com"))
        #expect(!place.contains("x.com") && !place.contains("Chrome"))
    }

    @Test func memoryCountsAndForgetsTheOldest() throws {
        var memory = InputMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        memory.record(place: "p", signature: "a", at: start)
        memory.record(place: "p", signature: "a", at: start.addingTimeInterval(1))
        #expect(memory.count(place: "p", signature: "a") == 2)
        #expect(memory.count(place: "p", signature: "b") == 0)
        for index in 0..<InputMemory.maxShapes {
            memory.record(place: "p", signature: "forme-\(index)", at: start.addingTimeInterval(10 + Double(index)))
        }
        #expect(memory.places["p"]?.count == InputMemory.maxShapes)
        #expect(memory.count(place: "p", signature: "a") == 0)
        for index in 0...InputMemory.maxPlaces {
            memory.record(place: "lieu-\(index)", signature: "a", at: start.addingTimeInterval(100 + Double(index)))
        }
        #expect(memory.places.count == InputMemory.maxPlaces)
        #expect(memory.places["p"] == nil)
        let decoded = try JSONDecoder().decode(InputMemory.self, from: JSONEncoder().encode(memory))
        #expect(decoded == memory)
    }
}

