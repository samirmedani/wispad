import Foundation

/// A small, local fallback for unambiguous spoken formatting. The correction model
/// handles implicit lists and paragraph meaning; this formatter never guesses them.
public enum DictationStructure {
    public static func format(_ text: String) -> String {
        // Respect a layout already supplied by the speaker or correction model.
        // Protected prose is left intact rather than partially rewritten.
        guard !text.isEmpty,
              !text.contains(where: { $0.isNewline }),
              !containsProtectedContent(text),
              !matches(text, existingList),
              !matches(text, metalanguage) else { return text }

        return formatBreakCommands(formatExplicitList(text))
    }

    /// Une seule puce ou un seul numéro, sans commande de liste dans la dictée, redevient une phrase.
    public static func collapseLoneItem(_ text: String, transcript: String) -> String {
        guard !text.isEmpty, !hasExplicitListCommand(transcript) else { return text }
        var lines = text.components(separatedBy: "\n")
        let hits = lines.indices.filter { line in
            loneItem.firstMatch(in: lines[line], range: NSRange(lines[line].startIndex..., in: lines[line])) != nil
        }
        guard hits.count == 1, let index = hits.first,
              let match = loneItem.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])),
              let range = Range(match.range, in: lines[index]) else { return text }
        lines[index].removeSubrange(range)
        return lines.joined(separator: "\n")
    }

    private enum Family {
        case bullets
        case numbered
    }

    private struct Marker {
        var range: NSRange
        var ordinal: Int
        var family: Family
    }

    private static let lexemes: [String: (Family, Int)] = {
        var words: [String: (Family, Int)] = [:]
        let french = [
            ["première", "premiere"], ["deuxième", "deuxieme", "seconde"],
            ["troisième", "troisieme"], ["quatrième", "quatrieme"],
            ["cinquième", "cinquieme"], ["sixième", "sixieme"],
            ["septième", "septieme"], ["huitième", "huitieme"],
            ["neuvième", "neuvieme"], ["dixième", "dixieme"]
        ]
        let english = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        for (index, forms) in french.enumerated() {
            for form in forms { words["\(form) puce"] = (.bullets, index + 1) }
            let points = index == 0 ? ["premier"] : index == 1 ? ["deuxième", "deuxieme", "second"] : forms
            for form in points { words["\(form) point"] = (.numbered, index + 1) }
            let adverbs = index == 0 ? ["premièrement", "premierement"] : forms.filter { $0 != "seconde" }.map { "\($0)ment" }
            for form in adverbs { words[form] = (.numbered, index + 1) }
            words["\(english[index]) bullet"] = (.bullets, index + 1)
            words["\(english[index]) point"] = (.numbered, index + 1)
        }
        for (index, word) in ["firstly", "secondly", "thirdly", "fourthly", "fifthly"].enumerated() {
            words[word] = (.numbered, index + 1)
        }
        return words
    }()

    private static let markers = expression(
        #"(?i)(?<![\p{L}\p{N}])(?:"# + lexemes.keys.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")(?![\p{L}\p{N}])"#
    )
    private static let existingList = expression(#"^\s*(?:[-*•]\s|\d+[.)]\s)"#)
    private static let loneItem = expression(#"^[\t \x{00A0}\x{202F}]*(?:[-*•]|[0-9]+[.)])[\t \x{00A0}\x{202F}]+(?=\S)"#)
    private static let protectedAddress = expression(#"(?i)\b(?:https?://|ftp://|mailto:|www\.)|\b[\p{L}\p{N}-]+\.(?:com|net|org|io|dev|fr|ai|app|co|uk)\b"#)
    private static let protectedCode = expression(#"(?:=>|</?[A-Za-z][^>]*>|\b(?:let|var|func|function|class|return|import)\s+[^.!?]*[=({;])"#)
    private static let singleQuotation = expression(#"(?<![\p{L}\p{N}])['‘][^'’]+['’](?![\p{L}\p{N}])"#)
    private static let metalanguage = expression(
        #"(?i)\b(?:expression|phrase|mots?|termes?|commandes?)\b[^.!?\n]{0,80}\b(?:nouveau paragraphe|à la ligne|a la ligne|nouvelle ligne|premier point|première puce|premiere puce|premièrement|premierement|new paragraph|new line|first bullet|first point|firstly)\b"#
    )
    private static let descriptiveItem = expression(#"(?i)^(?:est|était|etait|sera|concerne|porte sur|consiste|signifie|veut dire|s['’]appelle|c['’]est|is|was|means|concerns)\b"#)
    private static let conclusion = expression(#"(?i)(?<=[.!?])[ \t]+(?=(?:en conclusion|pour conclure|in conclusion|to conclude)\b)"#)
    private static let listEnd = expression(#"(?i)(?:^|(?<=[.!?]))[ \t]*(?:fin de (?:la )?liste|end of (?:the )?list)[ \t]*[.!?](?:[ \t]+|$)"#)
    private static let breakCommands = expression(
        #"(?im)(?:^|(?<=[.!?]))[ \t]*(nouveau paragraphe|new paragraph|à la ligne|a la ligne|nouvelle ligne|new line)[ \t]*[.!?]"#
    )

    private static func hasExplicitListCommand(_ transcript: String) -> Bool {
        markers.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil
    }

    private static func containsProtectedContent(_ text: String) -> Bool {
        if text.contains(where: { "\"“”«»`{}".contains($0) }) { return true }
        // Apostrophes within French words are ordinary prose. Single quotation
        // marks surrounding a phrase, however, must keep their literal contents.
        if matches(text, singleQuotation) { return true }
        return matches(text, protectedAddress) || matches(text, protectedCode)
    }

    private static func formatExplicitList(_ text: String) -> String {
        let source = text as NSString
        let found = markers.matches(in: text, range: NSRange(location: 0, length: source.length))
        let candidates: [Marker] = found.compactMap { match in
            let word = source.substring(with: match.range).lowercased()
            guard let (family, ordinal) = lexemes[word] else { return nil }
            return Marker(range: match.range, ordinal: ordinal, family: family)
        }
        guard candidates.count >= 2,
              let first = candidates.first,
              first.ordinal == 1,
              startsClause(first.range.location, in: source),
              candidates.enumerated().allSatisfy({ index, marker in
                  marker.ordinal == index + 1 && marker.family == first.family &&
                  (index == 0 || startsClause(marker.range.location, in: source) || !hasArticleBefore(marker.range.location, in: source))
              }) else { return text }

        var items: [String] = []
        var ending = ""
        for (index, marker) in candidates.enumerated() {
            let start = NSMaxRange(marker.range)
            let end = index + 1 < candidates.count ? candidates[index + 1].range.location : source.length
            var item = source.substring(with: NSRange(location: start, length: end - start))
            item = item.trimmingCharacters(in: .whitespaces)
            // Punctuation attached to a spoken label is presentation, not content.
            while let head = item.first,
                  head == ":" || ",.-".contains(head) && item.dropFirst().first?.isWhitespace == true {
                item.removeFirst()
                item = item.trimmingCharacters(in: .whitespaces)
            }
            if index == candidates.count - 1 {
                (item, ending) = splitEnding(item)
            }
            guard item.contains(where: { $0.isLetter || $0.isNumber }),
                  !matches(item, descriptiveItem) else { return text }
            items.append(capitalizingFirstWord(item))
        }

        let prefix = source.substring(to: first.range.location)
        let leading = prefix.prefix(while: { $0.isWhitespace })
        let introduction = prefix.trimmingCharacters(in: .whitespaces)
        let trailing = ending.isEmpty ? String(text.reversed().prefix(while: { $0.isWhitespace }).reversed()) : ""
        let list = items.enumerated().map { index, item in
            first.family == .bullets ? "- \(item)" : "\(index + 1). \(item)"
        }.joined(separator: "\n")
        let head = introduction.isEmpty ? String(leading) : String(leading) + introduction + "\n\n"
        return head + list + (ending.isEmpty ? trailing : "\n\n" + ending)
    }

    private static func splitEnding(_ item: String) -> (String, String) {
        let source = item as NSString
        let range = NSRange(location: 0, length: source.length)
        if let end = listEnd.firstMatch(in: item, range: range) {
            let body = source.substring(to: end.range.location).trimmingCharacters(in: .whitespaces)
            let rest = source.substring(from: NSMaxRange(end.range)).trimmingCharacters(in: .whitespaces)
            return (body, rest)
        }
        if let end = conclusion.firstMatch(in: item, range: range) {
            return (source.substring(to: end.range.location), source.substring(from: NSMaxRange(end.range)))
        }
        return (item, "")
    }

    private static func formatBreakCommands(_ text: String) -> String {
        let source = text as NSString
        let found = breakCommands.matches(in: text, range: NSRange(location: 0, length: source.length))
        struct Edit {
            var range: NSRange
            var lines: Int
        }
        var edits: [Edit] = []
        for command in found {
            var start = command.range.location
            while start > 0, " \t\n".utf16.contains(source.character(at: start - 1)) { start -= 1 }
            var end = NSMaxRange(command.range)
            while end < source.length, " \t\n".utf16.contains(source.character(at: end)) { end += 1 }
            let commandRange = NSRange(location: start, length: end - start)
            // A control alone, or at an outer edge, cannot establish two blocks.
            guard !source.substring(to: command.range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let word = source.substring(with: command.range(at: 1)).lowercased()
            let requested = word == "nouveau paragraphe" || word == "new paragraph" ? 2 : 1
            let existing = source.substring(with: commandRange).contains("\n\n") ? 2 : 1
            let lines = max(requested, existing)
            if let last = edits.last, NSMaxRange(last.range) >= commandRange.location {
                edits[edits.count - 1] = Edit(range: NSRange(location: last.range.location, length: NSMaxRange(commandRange) - last.range.location), lines: max(last.lines, lines))
            } else {
                edits.append(Edit(range: commandRange, lines: lines))
            }
        }
        let result = NSMutableString(string: text)
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: String(repeating: "\n", count: edit.lines))
        }
        return result as String
    }

    private static func startsClause(_ location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0, let scalar = UnicodeScalar(source.character(at: index)), CharacterSet.whitespaces.contains(scalar) { index -= 1 }
        return index < 0 || ".!?;:,".utf16.contains(source.character(at: index))
    }

    private static func hasArticleBefore(_ location: Int, in source: NSString) -> Bool {
        // An item may be unpunctuated; an ordinal preceded by an article is
        // nevertheless ordinary prose ("étudier le deuxième point").
        let prefix = source.substring(to: location).lowercased()
        let word = prefix.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        return ["le", "la", "les", "un", "une", "mon", "ton", "son", "ma", "ta", "sa", "du", "ce", "cette", "the", "a", "my", "your", "our"].contains(word)
    }

    private static func capitalizingFirstWord(_ text: String) -> String {
        guard let first = text.first else { return text }
        let word = text.prefix(while: { $0.isLetter || $0.isNumber })
        // xAI, iOS, eBay and model references retain their deliberately mixed case.
        guard !word.dropFirst().contains(where: { $0.isUppercase || $0.isNumber }) else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // All expressions are fixed developer-authored patterns.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
