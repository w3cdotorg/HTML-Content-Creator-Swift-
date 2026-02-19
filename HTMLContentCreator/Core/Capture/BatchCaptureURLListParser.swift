import Foundation

struct BatchCaptureURLImportResult: Equatable {
    let urls: [String]
    let nonEmptyLineCount: Int
    let ignoredLineCount: Int
    let duplicateCount: Int
}

enum BatchCaptureURLListParser {
    private static let supportedTextEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .isoLatin1
    ]

    static func parseFile(at fileURL: URL) throws -> BatchCaptureURLImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "readURLList",
                path: fileURL,
                underlying: error
            )
        }

        guard !data.isEmpty else {
            return BatchCaptureURLImportResult(urls: [], nonEmptyLineCount: 0, ignoredLineCount: 0, duplicateCount: 0)
        }

        for encoding in supportedTextEncodings {
            if let text = String(data: data, encoding: encoding) {
                return parse(text: text)
            }
        }

        throw AppError.invalidInput("Unsupported text encoding in \(fileURL.lastPathComponent).")
    }

    static func parse(text: String) -> BatchCaptureURLImportResult {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let lines = text.components(separatedBy: .newlines)

        var urls: [String] = []
        var seen = Set<String>()
        var nonEmptyLineCount = 0
        var ignoredLineCount = 0
        var duplicateCount = 0

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            nonEmptyLineCount += 1

            if line.hasPrefix("#") || line.hasPrefix("//") || isLikelyHeader(line: line, lineIndex: index) {
                ignoredLineCount += 1
                continue
            }

            let extracted = extractHTTPURLs(from: line, detector: detector)
            if extracted.isEmpty {
                ignoredLineCount += 1
                continue
            }

            for value in extracted {
                if seen.insert(value).inserted {
                    urls.append(value)
                } else {
                    duplicateCount += 1
                }
            }
        }

        return BatchCaptureURLImportResult(
            urls: urls,
            nonEmptyLineCount: nonEmptyLineCount,
            ignoredLineCount: ignoredLineCount,
            duplicateCount: duplicateCount
        )
    }

    private static func extractHTTPURLs(from line: String, detector: NSDataDetector?) -> [String] {
        var output: [String] = []

        for token in tokenCandidates(from: line) {
            if let normalized = normalizeURLString(token) {
                output.append(normalized)
            }
        }

        if !output.isEmpty {
            return output
        }

        if let detector {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in detector.matches(in: line, options: [], range: range) {
                if let tokenRange = Range(match.range, in: line) {
                    let token = String(line[tokenRange])
                    if let normalized = normalizeURLString(token) {
                        output.append(normalized)
                        continue
                    }
                }

                guard let raw = match.url?.absoluteString else { continue }
                if let normalized = normalizeURLString(raw) {
                    output.append(normalized)
                }
            }
        }

        return output
    }

    private static func tokenCandidates(from line: String) -> [String] {
        line
            .split(whereSeparator: { separator in
                separator == "," || separator == ";" || separator == "\t" || separator == " "
            })
            .map(String.init)
    }

    private static func normalizeURLString(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>[]()"))

        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url.absoluteString
        }

        guard looksLikeHostOrPath(trimmed) else { return nil }
        guard let guessedURL = URL(string: "https://\(trimmed)"),
              let scheme = guessedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return guessedURL.absoluteString
    }

    private static func looksLikeHostOrPath(_ raw: String) -> Bool {
        if raw.contains("@") || raw.contains(" ") {
            return false
        }

        guard raw.contains(".") else { return false }
        guard let components = URLComponents(string: "https://\(raw)"),
              let host = components.host,
              host.contains(".")
        else {
            return false
        }
        return true
    }

    private static func isLikelyHeader(line: String, lineIndex: Int) -> Bool {
        guard lineIndex <= 2 else { return false }

        let lower = line.lowercased()
        if lower.contains("http://") || lower.contains("https://") {
            return false
        }

        let tokens = lower.split(whereSeparator: { separator in
            separator == "," || separator == ";" || separator == "\t" || separator == " "
        })
        return tokens.contains("url") || tokens.contains("urls") || tokens.contains("link") || tokens.contains("website")
    }
}
