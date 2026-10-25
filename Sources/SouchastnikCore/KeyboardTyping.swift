import Foundation

/// Text-only rules shared by the extension and its regression tests.
public enum KeyboardTyping {
    public enum Capitalization: Sendable { case none, sentences, words, allCharacters }

    public static func capitalize(before: String?, mode: Capitalization) -> Bool {
        switch mode {
        case .none: return false
        case .allCharacters: return true
        case .words: return before == nil || before!.isEmpty || before!.last!.isWhitespace
        case .sentences:
            guard let before, !before.isEmpty else { return true }
            if before.last == "\n" { return true }
            guard before.last?.isWhitespace == true else { return false }
            let previous = before.trimmingCharacters(in: .whitespaces)
                .reversed().drop(while: { "\"'’”»)]}".contains($0) }).first
            return previous.map { ".!?…".contains($0) } ?? true
        }
    }

    public static func canInsertPeriod(before: String, elapsed: TimeInterval, hasSelection: Bool) -> Bool {
        guard !hasSelection, elapsed >= 0, elapsed < 0.33, before.last == " ", before.count > 1 else { return false }
        let previous = before.dropLast().last!
        return previous.isLetter || previous.isNumber || "\"'’”»)]}".contains(previous)
    }

    public static func currentWord(before: String) -> String {
        String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
    }

    public static func deletionCount(before: String) -> Int {
        let tail = before.suffix(128)
        let spaces = tail.reversed().prefix(while: \.isWhitespace).count
        return max(1, spaces + tail.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count)
    }

    /// A same-length but unrelated dictionary guess must not replace typed text.
    public static func isNearbyCorrection(_ original: String, _ replacement: String) -> Bool {
        let a = Array(original), b = Array(replacement)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count == b.count {
                if i + 1 < a.count, a[i] == b[j + 1], a[i + 1] == b[j] { i += 2; j += 2 }
                else { i += 1; j += 1 }
            } else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    public static func alternatives(for key: String, language: KeyboardLanguage) -> [String] {
        let letters: [String: [String]] = language == .russian
            ? ["е": ["е", "ё"], "ь": ["ь", "ъ"]]
            : ["a": ["a", "à", "á", "â", "ä", "æ", "ã", "å", "ā"],
               "e": ["e", "è", "é", "ê", "ë", "ē", "ė", "ę"],
               "i": ["i", "ì", "í", "î", "ï", "ī", "į"],
               "o": ["o", "ò", "ó", "ô", "ö", "õ", "ø", "œ", "ō"],
               "u": ["u", "ù", "ú", "û", "ü", "ū"], "s": ["s", "ß", "ś", "š"],
               "c": ["c", "ç", "ć", "č"], "n": ["n", "ñ", "ń"], "y": ["y", "ÿ"]]
        let punctuation = [".": [".", "…"], "-": ["-", "–", "—", "•"],
                           "\"": ["\"", "«", "»", "“", "”", "„"], "'": ["'", "‘", "’", "`"],
                           "₽": ["₽", "$", "€", "£", "¥", "₩"], "$": ["$", "€", "£", "¥", "₽", "₩"],
                           "?": ["?", "¿"], "!": ["!", "¡"], "0": ["0", "°"]]
        let result = letters[key.lowercased()] ?? punctuation[key] ?? []
        return key != key.lowercased() ? result.map { $0.uppercased() } : result
    }
}
