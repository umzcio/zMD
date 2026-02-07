import Foundation

struct FuzzyMatchResult {
    let score: Int
    let matchedIndices: [Int]
}

/// Fuzzy string matching algorithm with scoring
func fuzzyMatch(query: String, target: String) -> FuzzyMatchResult? {
    let queryLower = query.lowercased()
    let targetLower = target.lowercased()

    guard !queryLower.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }

    let queryChars = Array(queryLower)
    let targetChars = Array(targetLower)
    let originalChars = Array(target)

    var matchedIndices: [Int] = []
    var queryIndex = 0
    var score = 0

    for (targetIndex, targetChar) in targetChars.enumerated() {
        guard queryIndex < queryChars.count else { break }

        if targetChar == queryChars[queryIndex] {
            matchedIndices.append(targetIndex)
            queryIndex += 1
        }
    }

    // All query chars must match
    guard queryIndex == queryChars.count else { return nil }

    // Score contiguous runs
    for i in 0..<matchedIndices.count {
        let idx = matchedIndices[i]

        // Contiguous bonus: previous match was adjacent
        if i > 0 && matchedIndices[i - 1] == idx - 1 {
            score += 5
        }

        // Start-of-word bonus
        if idx == 0 {
            score += 10
        } else {
            let prevChar = originalChars[idx - 1]
            // Word boundary: after space, underscore, dash, or camelCase
            if prevChar == " " || prevChar == "_" || prevChar == "-" || prevChar == "/" || prevChar == "." {
                score += 10
            } else if prevChar.isLowercase && originalChars[idx].isUppercase {
                score += 8
            }
        }

        // Early match bonus (favor matches near the start)
        let positionBonus = max(0, 5 - idx / 10)
        score += positionBonus
    }

    return FuzzyMatchResult(score: score, matchedIndices: matchedIndices)
}
