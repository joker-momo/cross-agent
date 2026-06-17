import Foundation

enum VerdictParserError: LocalizedError, Equatable {
    case empty
    case noJSONObject
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "empty reviewer output"
        case .noJSONObject:
            return "no JSON object found in reviewer output"
        case .invalidJSON(let message):
            return "invalid JSON: \(message)"
        }
    }
}

enum VerdictParser {
    static func parse(_ raw: String) throws -> Verdict {
        let candidate = try extractJSON(raw)
        do {
            return try JSONDecoder().decode(Verdict.self, from: Data(candidate.utf8))
        } catch {
            throw VerdictParserError.invalidJSON(error.localizedDescription)
        }
    }

    static func extractJSON(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw VerdictParserError.empty }

        if let fenced = fencedJSON(in: raw) {
            return fenced
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            throw VerdictParserError.noJSONObject
        }
        return String(trimmed[start...end])
    }

    private static func fencedJSON(in raw: String) -> String? {
        guard let fenceStart = raw.range(of: "```") else { return nil }
        let afterFence = raw[fenceStart.upperBound...]
        let contentStart: String.Index
        if afterFence.hasPrefix("json") {
            contentStart = afterFence.index(afterFence.startIndex, offsetBy: 4)
        } else {
            contentStart = afterFence.startIndex
        }
        guard let fenceEnd = afterFence[contentStart...].range(of: "```") else { return nil }
        return String(afterFence[contentStart..<fenceEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
