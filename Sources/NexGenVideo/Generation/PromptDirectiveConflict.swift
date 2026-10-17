import Foundation

enum PromptDirectiveConflict {
    private static let negations = Set(["no", "not", "without", "avoid", "never", "kein", "keine", "keinen", "keinem", "keiner", "keines", "ohne", "vermeide"])
    private static let articles = Set(["a", "an", "the", "any", "ein", "eine", "einen", "einem", "einer", "der", "die", "das"])
    private static let conjunctions = Set(["and", "but", "und", "aber"])

    static func first(in statements: [String], negatives: [String] = []) -> String? {
        let clauses = statements.flatMap {
            $0.lowercased().components(separatedBy: CharacterSet(charactersIn: ".,;:!?()\n"))
        }.map(words).filter { !$0.isEmpty }
        var positive: [[String]] = []
        var excluded = negatives.map(words)
        for clause in clauses {
            let indices = clause.indices.filter { negations.contains(clause[$0]) }
            if let first = indices.first {
                let hasPositivePrefix = first > 0 && ["with", "mit"].contains(clause[first - 1])
                    && (clause[first] == "no" || clause[first].hasPrefix("kein"))
                if ["without", "ohne"].contains(clause[first])
                    || (first > 0 && conjunctions.contains(clause[first - 1])) || hasPositivePrefix {
                    positive.append(Array(clause.prefix(first)))
                }
            } else {
                positive.append(clause)
            }
            for index in indices {
                guard index == 0 || !negations.contains(clause[index - 1]) else { continue }
                var phrase = Array(clause.dropFirst(index + 1).prefix {
                    !negations.contains($0) && !conjunctions.contains($0)
                })
                if let first = phrase.first, articles.contains(first) { phrase.removeFirst() }
                if !phrase.isEmpty { excluded.append(phrase) }
            }
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
