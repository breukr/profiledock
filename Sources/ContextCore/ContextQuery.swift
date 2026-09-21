import Foundation

public enum ContextSearchMode: String, CaseIterable, Sendable {
    case allWords, anyWord, exactPhrase
    public var label: String {
        switch self { case .allWords: return "All words"; case .anyWord: return "Any word"; case .exactPhrase: return "Exact phrase" }
    }
}

public struct ContextQuery: Sendable {
    public let mode: ContextSearchMode
    public let terms: [String]
    public let phrase: String

    public init(_ value: String, mode: ContextSearchMode = .allWords) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("“") && trimmed.hasSuffix("”"))
        let text = quoted && trimmed.count > 1 ? String(trimmed.dropFirst().dropLast()) : trimmed
        self.mode = quoted ? .exactPhrase : mode
        phrase = Self.normalize(text)
        let stop: Set<String> = ["de", "het", "een", "en", "van", "voor", "over", "met", "in", "op", "ons", "onze", "zoek", "eerder", "gesprek", "gesprekken", "the", "a", "an", "and", "of", "for", "about", "with", "is", "this", "that", "please", "find", "show", "me", "our", "my", "earlier", "conversation", "conversations"]
        let words = phrase.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        terms = self.mode == .exactPhrase ? (phrase.isEmpty ? [] : [phrase]) : Array(Set(words.filter { !stop.contains($0) })).sorted()
    }

    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public func score(title: String, body: String) -> Int? {
        guard !terms.isEmpty else { return nil }
        let title = Self.normalize(title), body = Self.normalize(body)
        let inBody = terms.filter { body.contains($0) }.count
        let inTitle = terms.filter { title.contains($0) }.count
        switch mode {
        case .allWords: guard terms.allSatisfy({ body.contains($0) || title.contains($0) }) else { return nil }
        case .anyWord: guard inBody + inTitle > 0 else { return nil }
        case .exactPhrase: guard body.contains(phrase) || title.contains(phrase) else { return nil }
        }
        return inBody * 8 + inTitle * 6 + (inBody == terms.count ? 12 : 0)
            + (inTitle == terms.count ? 20 : 0) + (body.contains(phrase) ? 32 : 0)
    }
}
