import Foundation

/// Retouches prudentes d'une transcription franglaise, avant et après la correction.
/// Chaque règle ne se déclenche que sur un indice que le français correct ne produit pas
/// (accord impossible, forme verbale impossible, référence matérielle reconnue, contexte OAuth explicite) :
/// ce n'est pas une table de remplacement mot à mot, et une phrase en français normal n'est jamais touchée.
public enum FranglaisNormalizer {
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = joinHardwareReferences(result)
        result = restoreOAuth(result)
        result = keepEnglishPastParticiple(result)
        result = restoreEnvironmentVariable(result)
        result = fixKnownMishearings(result)
        return result
    }

    // MARK: - Références matérielles

    /// La reconnaissance coupe les références alphanumériques comme on les prononce : « 7950X 3D »,
    /// « i5 13600 K F », « RTX 50 70 TI ». On ne recolle qu'après un nom de gamme connu, et seulement avec
    /// un suffixe qui existe chez ce fabricant : « une BMW i3 2018 » ou « un MacBook i9 2019 » restent intacts.
    static func joinHardwareReferences(_ text: String) -> String {
        var result = text
        // Numéros dits en deux morceaux : « RTX 50 70 » → « RTX 5070 », « Ryzen 9 7 950X » → « Ryzen 9 7950X ».
        result = replace(result, #"\b(RTX|GTX) ([1-5]0) ([1-9]0)\b"#, "$1 $2$3")
        result = replace(result, #"\b(Ryzen [3579]|Threadripper(?: PRO)?|Core i[3579]|i[3579]|RTX|GTX|RX) (\d{1,2})[ \x{00A0}\x{202F}](\d{3})(?!\d)"#, "$1 $2$3")
        // AMD : suffixes collés au numéro (X3D, X, XT, HX…).
        result = joinSuffix(result, pattern: #"\b(Ryzen(?: [3579])?|Threadripper(?: PRO)?) (\d{4,5})((?: ?(?:3 ?D|[A-Z])){1,3})(?![\p{L}\d])"#,
                            allowed: ["X3D", "X", "XT", "G", "GE", "HX", "HS", "H", "U", "WX"]) { "\($0) \($1)\($2)" }
        result = joinSuffix(result, pattern: #"\b((?:Radeon )?RX) (\d{4})((?: ?[A-Z]){1,3})(?![\p{L}\d])"#,
                            allowed: ["XT", "XTX", "GRE"]) { "\($0) \($1) \($2)" }
        // « 7950X 3D » sans gamme : un « X 3D » détaché derrière un numéro n'existe que chez AMD.
        result = replace(result, #"\b(\d{4,5})X 3D\b"#, "$1X3D")
        // Intel Core Ultra : « Core Ultra 9 285 K » → « Core Ultra 9 285K ».
        result = joinSuffix(result, pattern: #"\b(Core Ultra [3579]) (\d{3})((?: ?[A-Z]){1,2})(?![\p{L}\d])"#,
                            allowed: ["K", "KF", "H", "HX", "U", "V"]) { "\($0) \($1)\($2)" }
        result = joinIntel(result)
        // NVIDIA : « TI » s'écrit « Ti ».
        result = replace(result, #"\b(RTX|GTX) (\d{3,4}) ?(?:TI|ti)\b"#, "$1 $2 Ti")
        // Apple : « MacBook Pro M 4 Pro » → « MacBook Pro M4 Pro ».
        result = replace(result, #"\b(MacBook(?: Pro| Air)?|Mac(?: mini| Studio| Pro)?|iMac|puce) M ([1-6])\b"#, "$1 M$2")
        return result
    }

    /// Intel Core : « i5 13600 K » → « i5-13600K ». Sans suffixe, il faut un numéro à 5 chiffres ou « Core » devant,
    /// pour ne pas confondre avec une année (« i7 2018 »).
    private static func joinIntel(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\b(Core )?i([3579])[ -]?(\d{4,5})((?: ?[A-Z]){0,2})(?![\p{L}\d])"#)
        return rewrite(text, regex) { match, text in
            let core = group(match, 1, in: text)
            let digits = group(match, 3, in: text)
            let suffix = group(match, 4, in: text).replacingOccurrences(of: " ", with: "")
            guard ["", "K", "KF", "KS", "F", "H", "HX", "HK", "U", "T"].contains(suffix),
                  !suffix.isEmpty || digits.count == 5 || !core.isEmpty else { return nil }
            return "\(core)i\(group(match, 2, in: text))-\(digits)\(suffix)"
        }
    }

    private static func joinSuffix(_ text: String, pattern: String, allowed: Set<String>, build: (String, String, String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return rewrite(text, regex) { match, text in
            let suffix = group(match, 3, in: text).replacingOccurrences(of: " ", with: "")
            guard allowed.contains(suffix) else { return nil }
            return build(group(match, 1, in: text), group(match, 2, in: text), suffix)
        }
    }

    // MARK: - OAuth

    /// « O Auth » et « O-Auth » sont toujours OAuth. « Auth » suivi d'une version d'OAuth (2.0, 1.0a, 2) aussi.
    /// « Auth » seul ne devient OAuth que si la phrase contient un signal propre à OAuth (permissions, scopes,
    /// consentement, redirect, callback, client id…), ou si la dictée parle déjà d'OAuth et que la phrase évoque
    /// des tokens, un login ou une API. Jamais dans un nom de produit ou de schéma (Basic Auth, NextAuth,
    /// Better Auth, Firebase Auth, Auth0, Auth.js, Firebase.Auth…).
    static func restoreOAuth(_ text: String) -> String {
        let result = replace(text, #"\bO[ -]Auth\b"#, "OAuth")
        let candidates = try! NSRegularExpression(pattern: #"(?<![\p{L}\d.])Auth(?!\p{L}|\.\p{L}| ?0\b| (?:zéro|zero)\b)"#)
        let product = try! NSRegularExpression(pattern: #"(?i)(?:next|better|basic|digest|bearer|firebase|supabase|clerk|stack|lucia|amplify|cognito|passport|kinde|nuxt|sveltekit)[ -]?$"#)
        let version = try! NSRegularExpression(pattern: #"^(?: (?:1\.0a?|2\.[01])|2)(?![\d.]\d)"#)
        let strong = try! NSRegularExpression(pattern: #"(?i)\b(permissions?|scopes?|consentement|consent|redirect\w*|callback|client[ _-]?(?:id|secret)|pkce|refresh token|access token|authorization code|code d'autorisation)\b"#)
        let weak = try! NSRegularExpression(pattern: #"(?i)\b(tokens?|login|logout|connexion|API|provider|autorisations?|SSO)\b"#)
        let mentionsOAuth = result.contains("OAuth")
        return rewrite(result, candidates) { match, text in
            let ns = text as NSString
            let before = ns.substring(with: NSRange(location: max(0, match.range.location - 12), length: min(12, match.range.location)))
            guard product.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil else { return nil }
            let after = ns.substring(from: match.range.location + match.range.length)
            if version.firstMatch(in: after, range: NSRange(location: 0, length: min((after as NSString).length, 8))) != nil {
                return "OAuth"
            }
            let sentence = sentenceAround(match.range, in: ns)
            let range = NSRange(location: 0, length: (sentence as NSString).length)
            if strong.firstMatch(in: sentence, range: range) != nil { return "OAuth" }
            if mentionsOAuth, weak.firstMatch(in: sentence, range: range) != nil { return "OAuth" }
            return nil
        }
    }

    // MARK: - Verbes anglais au passé composé

    /// « j'ai fixe le problème » → « j'ai fix le problème ». Après l'auxiliaire avoir, le français demanderait
    /// « fixé » : un « fixe » nu suivi de son complément ne peut être que le verbe anglais prononcé tel quel.
    /// « on a fixe, internet et télé » (le nom : la ligne fixe) reste intact, faute de complément.
    static func keepEnglishPastParticiple(_ text: String) -> String {
        let auxiliary = #"(?:ai|as|a|avons|avez|ont|avais|avait|avions|aviez|avaient|aurai|auras|aura|aurons|aurez|auront|aurais|aurait|aurions|auriez|auraient)"#
        let adverb = #"(?: (?:déjà|bien|pas|enfin|encore|aussi|vite|finalement|rapidement|jamais|tout|pas encore))?"#
        let object = #"(?:le|la|les|l['’]|un|une|des|du|ce|cet|cette|ces|mon|ton|son|ma|ta|sa|mes|tes|ses|notre|votre|leur|nos|vos|leurs|ça|tout|deux|trois)"#
        var result = replace(text, #"(?i)(?<![\p{L}])((?:[jtn]['’])?"# + auxiliary + adverb + #") fixe (?="# + object + #"\b)"#, "$1 fix ")
        // Pronom complément devant l'auxiliaire : « je l'ai fixe », « on l'a fixe. »
        result = replace(result, #"(?i)(?<![\p{L}])((?:[jn]['’])?l['’]"# + auxiliary + adverb + #") fixe(?=[\s,.;:!?…)»]|$)"#, "$1 fix")
        return result
    }

    // MARK: - environment variable

    /// « une environnement variable » → « une environment variable » : « environnement » est masculin, un déterminant
    /// féminin ne peut porter que sur « variable », donc sur l'expression anglaise. Au pluriel, « les environnement
    /// variables » (nom singulier, adjectif pluriel) est tout aussi impossible. Les déterminants des deux genres
    /// (leur, notre, chaque…) ne prouvent rien : « leur environnement variable » reste intact.
    static func restoreEnvironmentVariable(_ text: String) -> String {
        let feminine = #"(?:une|la|cette|aucune|toute|ma|ta|sa|quelle|certaine)"#
        let adjective = #"(?: (?:autre|nouvelle|seule|première|deuxième|dernière|bonne|mauvaise|même))?"#
        var result = replace(text, #"(?i)(?<![\p{L}])("# + feminine + adjective + #") environnement variable\b"#, "$1 environment variable")
        result = replace(result, #"(?i)(?<![\p{L}])((?:les|des|ces|mes|tes|ses|nos|vos|leurs|plusieurs|quelques|certaines|aucune|deux|trois)(?: (?:autres|nouvelles|bonnes|mêmes))?) environnement variables\b"#, "$1 environment variables")
        return result
    }

    // MARK: - Outils

    /// Expressions mal entendues malgré les mots-clés, relevées sur de vraies dictées (octobre 2026) :
    /// « services functions » pour « serverless functions », « day inference » pour « AI inference ».
    /// Ces suites n'existent ni en français ni en anglais : les remplacer ne touche aucune phrase juste.
    static func fixKnownMishearings(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [
            (#"(?i)(?<![\p{L}\p{N}])(?:services?|server less|serveur less|serveurless) functions(?![\p{L}\p{N}])"#, "serverless functions"),
            (#"(?i)(?<![\p{L}\p{N}])day inference(?![\p{L}\p{N}])"#, "AI inference"),
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let startsUpper = result[range].first?.isUppercase == true
                let fixed = startsUpper && replacement.first?.isLowercase == true
                    ? replacement.prefix(1).uppercased() + replacement.dropFirst()
                    : replacement
                result.replaceSubrange(range, with: fixed)
            }
        }
        return result
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Remplace chaque occurrence par la valeur calculée, ou la laisse si le calcul renvoie nil.
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, _ replacement: (NSTextCheckingResult, String) -> String?) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            if let value = replacement(match, text) { output.replaceCharacters(in: match.range, with: value) }
        }
        return output as String
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (text as NSString).substring(with: range)
    }

    /// Phrase qui contient `range` : bornée par . ! ? … suivis d'un espace ou d'une fin de ligne, ou par un retour
    /// à la ligne. Un point collé (Node.js, 2.0, accounts.google.com) ne coupe pas.
    private static func sentenceAround(_ range: NSRange, in text: NSString) -> String {
        let boundary = try! NSRegularExpression(pattern: #"[.!?…](?=\s|$)|\n"#)
        var start = 0
        var end = text.length
        for match in boundary.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let position = match.range.location + match.range.length
            if position <= range.location { start = position }
            else if match.range.location >= range.location + range.length { end = position; break }
        }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
