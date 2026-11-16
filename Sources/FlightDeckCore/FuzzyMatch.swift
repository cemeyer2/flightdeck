import Foundation

// Ranking for the command palette (⌘K): Spotlight-style "type a few letters" matching over destinations, processes
// and commands. Kept in core so it can be unit tested.

/// Subsequence fuzzy matching with a score. Every query character must appear in the candidate in order
/// (case-insensitive); the score rewards matches at word starts, consecutive runs and an early first match, so
/// "fl" ranks "Flight Log" above "Safari Helper (Plugin)".
public enum FuzzyMatch {
    /// Score of `query` against `candidate`, higher is better; nil if it doesn't match. An empty query matches
    /// everything with score 0. Spaces in the query are ignored, so "flight log" and "flightlog" match alike.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        // Lowercasing can change the character count for a few scripts; camel-case detection then has nothing to align to.
        let camel = original.count == c.count
        // A plain substring match is what people expect most often; rank it above any scattered match.
        let joined = String(c)
        if let r = joined.range(of: String(q)) {
            let at = joined.distance(from: joined.startIndex, to: r.lowerBound)
            let wordStart = at == 0 || !c[at - 1].isLetter && !c[at - 1].isNumber
            return 1000 - min(at, 200) + (wordStart ? 300 : 0) + (q.count == c.count ? 200 : 0)
        }
        // Greedy left-to-right subsequence: good enough for short palette labels, and O(len(candidate)).
        var score = 0, qi = 0, last = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            // Word start: first character, after a separator, or a lower→upper camel-case boundary in the original.
            let boundary = i == 0 || !c[i - 1].isLetter && !c[i - 1].isNumber
                || (camel && original[i].isUppercase && original[i - 1].isLowercase)
            score += 10 + (boundary ? 25 : 0) + (i == last + 1 ? 15 : 0)
            last = i; qi += 1
        }
        guard qi == q.count else { return nil }
        return score - min(c.count, 100) / 10
    }
}
