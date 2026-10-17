import Foundation

enum PromptDirectiveConflict {
    private static let negations = Set(["no", "not", "without", "avoid", "never", "kein", "keine", "keinen", "keinem", "keiner", "keines", "ohne", "vermeide"])
    private static let articles = Set(["a", "an", "the", "any", "ein", "eine", "einen", "einem", "einer", "der", "die", "das"])

    static func first(in statements: [String], negatives: [String] = []) -> String? {
        let clauses = statements.flatMap {
            $0.lowercased().components(separatedBy: CharacterSet(charactersIn: ".,;:!?()\n"))
        }.map(words).filter { !$0.isEmpty }
        let positive = clauses.filter { $0.allSatisfy { !negations.contains($0) } }
        var excluded = negatives.map(words)
        for clause in clauses {
            guard let index = clause.firstIndex(where: negations.contains) else { continue }
            var phrase = Array(clause.dropFirst(index + 1))
            if let conjunction = phrase.firstIndex(where: { ["and", "but", "und", "aber"].contains($0) }) {
                phrase = Array(phrase.prefix(conjunction))
            }
            if let first = phrase.first, articles.contains(first) { phrase.removeFirst() }
            if !phrase.isEmpty { excluded.append(phrase) }
        }
        for phrase in excluded where !phrase.isEmpty {
            let needle = " " + phrase.joined(separator: " ") + " "
            if positive.contains(where: { (" " + $0.joined(separator: " ") + " ").contains(needle) }) {
                return phrase.joined(separator: " ")
            }
        }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
