import Testing
@testable import WispadCore

struct StructuredWordCountTests {
    @Test(arguments: [
        "- Acheter du lait.\n- Appeler OpenAI.",
        "1. Acheter du lait.\n2. Appeler OpenAI.",
        "1) Acheter du lait.\n2) Appeler OpenAI.",
        "* Acheter du lait.\n* Appeler OpenAI.",
        "• Acheter du lait.\n• Appeler OpenAI.",
        "+ Acheter du lait.\n+ Appeler OpenAI.",
        "\t- Acheter du lait.\n  2. Appeler OpenAI.",
        "\u{00A0}-\u{202F}Acheter du lait.\r\n\u{2003}2) Appeler OpenAI."
    ])
    func listPresentationDoesNotCountAsDictatedWords(_ text: String) {
        #expect(WordCount.count(text) == WordCount.count("Acheter du lait. Appeler OpenAI."))
        #expect(WordCount.count(text) == 5)
    }

    @Test(arguments: [
        ("-12 degrés et 3.14 litres.", 5),
        ("3.14 litres le 03.10.2026 à 12:30.", 6),
        ("Le signe - est conservé.", 5),
        ("Le signe + et le signe * aussi.", 8),
        ("1. Acheter du lait. 2. Appeler OpenAI.", 6),
        ("-Acheter du lait. 2.Appeler OpenAI.", 5),
        ("Version 1. et section 2) intactes.", 6),
        ("# Titre\n> Citation", 4),
        ("1.5 valeur\n2026-10-03 date\n12:30 heure", 6),
        ("1.", 1),
        ("  -  \n\t•\n2)", 3),
        ("", 0)
    ])
    func NumbersInlineSignsAndOtherPunctuationKeepExistingCounting(_ fixture: (String, Int)) {
        #expect(WordCount.count(fixture.0) == fixture.1)
    }

    @Test(arguments: [
        "```text\n- one two\n1. three four\n```",
        "~~~text\n- one two\n1. three four\n~~~",
        "````\n```\n- one two\n```\n1. three four\n````",
        "~~~\n```\n- one two\n```\n1. three four\n~~~",
        "  ``` text\n  - one two\n  1. three four\n  ```",
        "```text\n- one two\n1. three four"
    ])
    func FencedCodeRetainsEveryToken(_ text: String) {
        let previousCount = text.split { $0.isWhitespace || $0.isNewline }.count
        #expect(WordCount.count(text) == previousCount)
    }

    @Test func ClosingFenceRestoresListCounting() {
        let text = "- Outside.\n```text\n- Inside.\n```\n1. Outside again."
        #expect(WordCount.count(text) == 7)
    }
}
