import Foundation
import Testing
@testable import WispadCore

/// Objet JSON enregistré (bloc de réglages, fichier de clés) : un bloc abîmé garde ses paires complètes, et une
/// réécriture garde ce que cette version ne sait pas lire.
struct StoredJSONTests {
    private func read(_ text: String) -> (object: [String: Any], intact: Bool)? {
        StoredJSON.object(from: Data(text.utf8))
    }

    @Test func intactObjectIsReadAsIs() throws {
        let block = try #require(read(#"{"provider": "openai", "keyCode": 61, "dateFormat": {"order": "iso"}, "liste": [1, "a"]}"#))
        #expect(block.intact)
        #expect(StoredJSON.same(block.object, ["provider": "openai", "keyCode": 61, "dateFormat": ["order": "iso"], "liste": [1, "a"]]))
    }

    @Test func somethingElseThanAnObjectIsUnreadable() {
        for text in ["", "   ", "pas du JSON", "[1, 2]", "42", #""texte""#, "}{"] {
            #expect(read(text) == nil, "\(text)")
        }
    }

    /// Bloc coupé à chaque octet : chaque paire entière avant la coupure est rendue telle quelle, aucune autre. Un
    /// nombre ou un booléen n'est entier que suivi d'un séparateur (« 6 » peut être le début de « 61 »).
    @Test func truncatedObjectKeepsEveryCompletePair() throws {
        let pairs: [(key: String, json: String, scalar: Bool)] = [
            ("dateFormat", #"{"clock":"twelveHour","order":"iso"}"#, false),
            ("keyCode", "61", true),
            ("microphoneUID", #""Micro \"USB\" « bureau » / é""#, false),
            ("modifierFlags", "8388608", true),
            ("onboardingCompleted", "false", true),
            ("overlayPlacement", #"{"anchors":{"info":{"x":0.25,"y":0.75}},"avoidsInput":false}"#, false),
            ("provider", #""openai""#, false),
            ("reglageFutur", #"[{"texte":"a, b } ] {","n":[1,[2]]}]"#, false),
            ("typingWPM", "52.5", true),
            ("xaiModel", #""grok-voice-transcribe-1.0""#, false),
        ]
        var text = "{"
        var ends: [(key: String, end: Int, scalar: Bool)] = []
        for (index, pair) in pairs.enumerated() {
            text += (index == 0 ? "" : ",") + "\"\(pair.key)\":" + pair.json
            ends.append((pair.key, text.utf8.count, pair.scalar))
        }
        text += "}"
        let full = try #require(read(text))
        #expect(full.intact)
        #expect(full.object.count == pairs.count)

        let bytes = Array(text.utf8)
        #expect(StoredJSON.object(from: Data()) == nil)
        for cut in 1..<bytes.count {
            let block = try #require(StoredJSON.object(from: Data(bytes[..<cut])), "coupé à \(cut)")
            #expect(!block.intact, "coupé à \(cut)")
            let complete = ends.filter { cut >= $0.end + ($0.scalar ? 1 : 0) }.map(\.key)
            #expect(Set(block.object.keys) == Set(complete), "coupé à \(cut)")
            for key in complete {
                #expect(StoredJSON.same(try #require(block.object[key]), try #require(full.object[key])), "\(key) coupé à \(cut)")
            }
        }
    }

    /// Une paire illisible (octet invalide, caractère de contrôle) est écartée seule ; la lecture s'arrête là où la
    /// structure se perd, ou au texte en trop.
    @Test func damagedPairIsDroppedAndItsNeighboursKept() throws {
        var bytes = Array(#"{"a":"avant","b":"abîmé","c":3,"d":"après"}"#.utf8)
        bytes[try #require(bytes.firstIndex(of: UInt8(ascii: "m")))] = 0xFF
        let invalidByte = try #require(StoredJSON.object(from: Data(bytes)))
        #expect(!invalidByte.intact)
        #expect(StoredJSON.same(invalidByte.object, ["a": "avant", "c": 3, "d": "après"]))

        let control = try #require(read("{\"a\":1,\"b\":\"ligne\ncoupée\",\"c\":true}"))
        #expect(!control.intact)
        #expect(StoredJSON.same(control.object, ["a": 1, "c": true]))

        let lostStructure = try #require(read(#"{"a":1,"b" 2,"c":3}"#))
        #expect(StoredJSON.same(lostStructure.object, ["a": 1]))

        let trailing = try #require(read(#"{"a":1,"b":{"c":[2]}} et la suite"#))
        #expect(!trailing.intact)
        #expect(StoredJSON.same(trailing.object, ["a": 1, "b": ["c": [2]]]))
    }

    /// Ce qui est lu peut toujours être réécrit : un nombre démesuré est écarté, ses voisins restent.
    @Test func whatIsReadCanAlwaysBeWrittenBack() throws {
        let block = try #require(read(#"{"a": 1e400, "b": 2}"#))
        #expect(JSONSerialization.isValidJSONObject(block.object))
        #expect(StoredJSON.same(try #require(block.object["b"]), 2))
    }

    /// Réglage inchangé depuis la lecture : la valeur enregistrée reste, même illisible pour cette version.
    @Test func unchangedValueKeepsWhatWasStored() {
        #expect(StoredJSON.same(StoredJSON.merged(stored: "fournisseur-futur", read: "xai", current: "xai"), "fournisseur-futur"))
        #expect(StoredJSON.same(StoredJSON.merged(stored: 9_999, read: 250, current: 250), 9_999))
        #expect(StoredJSON.same(StoredJSON.merged(stored: ["a": 1], read: [String: Any](), current: [String: Any]()), ["a": 1]))
    }

    /// Réglage changé ou absent du bloc : la nouvelle valeur est écrite.
    @Test func changedOrMissingValueIsWritten() {
        #expect(StoredJSON.same(StoredJSON.merged(stored: "fournisseur-futur", read: "xai", current: "openai"), "openai"))
        #expect(StoredJSON.same(StoredJSON.merged(stored: nil, read: "xai", current: "xai"), "xai"))
        #expect(StoredJSON.same(StoredJSON.merged(stored: "illisible", read: nil, current: 3), 3))
        #expect(StoredJSON.same(StoredJSON.merged(stored: "illisible", read: ["a": 1], current: ["a": 2]), ["a": 2]))
    }

    /// Objet changé : ses champs inchangés gardent leur valeur enregistrée et ses champs inconnus restent ; une entrée
    /// lue puis retirée (table) disparaît.
    @Test func changedObjectKeepsWhatThisVersionDoesNotRead() {
        let format = StoredJSON.merged(
            stored: ["order": "ordre-futur", "separator": "dot", "champFutur": "court"],
            read: ["order": "dayMonthYear", "separator": "dot"],
            current: ["order": "dayMonthYear", "separator": "hyphen"]
        )
        #expect(StoredJSON.same(format, ["order": "ordre-futur", "separator": "hyphen", "champFutur": "court"]))

        let tones = StoredJSON.merged(
            stored: ["email": "ton-futur", "notes": "casual", "développement": "polished"],
            read: ["notes": "casual", "développement": "polished"],
            current: ["développement": "casual"]
        )
        #expect(StoredJSON.same(tones, ["email": "ton-futur", "développement": "casual"]))

        let placement = StoredJSON.merged(
            stored: ["avoidsInput": true, "anchors": ["roleFutur": ["x": 0.1, "y": 0.2], "dictation": ["x": 0.5, "y": 0]]],
            read: ["avoidsInput": true, "anchors": ["dictation": ["x": 0.5, "y": 0]]],
            current: ["avoidsInput": true, "anchors": ["dictation": ["x": 0.5, "y": 0], "info": ["x": 0.9, "y": 0.9]]]
        )
        #expect(StoredJSON.same(placement, ["avoidsInput": true, "anchors": [
            "roleFutur": ["x": 0.1, "y": 0.2], "dictation": ["x": 0.5, "y": 0], "info": ["x": 0.9, "y": 0.9],
        ]]))
    }

    @Test func sameComparesValuesNotKeyOrder() {
        #expect(StoredJSON.same(["a": 1, "b": [true, "x"]], ["b": [true, "x"], "a": 1]))
        #expect(!StoredJSON.same(["a": 1], ["a": 2]))
        #expect(!StoredJSON.same("1", 1))
        #expect(!StoredJSON.same(true, "true"))
        #expect(!StoredJSON.same(["a": 1], ["a": 1, "b": 2]))
    }
}
