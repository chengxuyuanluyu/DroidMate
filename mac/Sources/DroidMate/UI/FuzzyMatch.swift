import Foundation

/// Fuzzy-match scoring and range highlighting for command palette search.
/// Returns nil if query doesn't match in order; otherwise a positive score
/// (higher = better).
///
/// Bonuses: exact substring (+100), word-boundary start (+30 each),
/// target starts with query (+50).
func fuzzyScore(query: String, target: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = query.lowercased()
    let t = target.lowercased()

    if let range = t.range(of: q) {
        var score = 100
        if range.lowerBound == t.startIndex { score += 50 }
        if range.lowerBound > t.startIndex,
           t[t.index(before: range.lowerBound)] == " " { score += 30 }
        return score
    }

    var qi = q.startIndex
    var score = 0
    var lastCharWasSpace = true
    for ti in t.indices {
        guard qi < q.endIndex else { break }
        if t[ti] == q[qi] {
            score += 10
            if lastCharWasSpace { score += 15 }
            if ti == t.startIndex { score += 20 }
            qi = q.index(after: qi)
            lastCharWasSpace = false
        } else {
            lastCharWasSpace = t[ti] == " "
        }
    }
    return qi == q.endIndex ? score : nil
}

/// Character ranges in `target` that the fuzzy query matches (for highlighting).
func fuzzyMatchedRanges(query: String, in target: String) -> [Range<Int>] {
    guard !query.isEmpty else { return [] }
    let q = query.lowercased()
    let t = target.lowercased()

    if let range = t.range(of: q) {
        let start = t.distance(from: t.startIndex, to: range.lowerBound)
        let end = t.distance(from: t.startIndex, to: range.upperBound)
        return [start..<end]
    }

    var qi = q.startIndex
    var ranges: [Range<Int>] = []
    var runStart: Int? = nil
    var runEnd = 0
    for (idx, tv) in t.enumerated() {
        guard qi < q.endIndex else { break }
        if tv == q[qi] {
            if runStart == nil { runStart = idx }
            runEnd = idx + 1
            qi = q.index(after: qi)
        } else if let s = runStart {
            ranges.append(s..<runEnd)
            runStart = nil
        }
    }
    if let s = runStart { ranges.append(s..<runEnd) }
    return ranges
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
