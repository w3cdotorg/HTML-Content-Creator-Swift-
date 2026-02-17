import Foundation

enum LegacyMarkdownCodec {
    private static let captureMarkerPattern = #"^<!--\s*CAPTURE:\s*(.+?)\s*-->$"#
    private static let captureFieldPattern = #"^-\s*(Fichier|URL|Date):\s*(.+?)\s*$"#
    private static let noteStartPattern = #"^<!--\s*NOTE:\s*(.+?)\s*-->$"#
    private static let noteEndPattern = #"^<!--\s*END NOTE\s*-->$"#
    private static let safePNGFilenamePattern = #"^[a-zA-Z0-9._-]+\.png$"#

    static func parseCaptureLog(_ text: String) -> [CaptureRecord] {
        struct Builder {
            var filename: String?
            var urlString: String?
            var dateString: String?
        }

        var captures: [CaptureRecord] = []
        var current = Builder()

        func flushCurrent() {
            guard
                let filename = current.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
                !filename.isEmpty,
                let urlString = current.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
                let url = URL(string: urlString),
                let rawDate = current.dateString?.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return
            }

            let capturedAt = LegacyDateFormatter.parseFullDateTime(rawDate)
            captures.append(
                CaptureRecord(
                    filename: filename,
                    url: url,
                    capturedAt: capturedAt
                )
            )
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let markerValue = firstCaptureGroup(in: line, pattern: captureMarkerPattern) {
                flushCurrent()
                current = Builder()
                current.filename = markerValue
                continue
            }

            guard let fields = captureGroups(in: line, pattern: captureFieldPattern), fields.count >= 2 else {
                continue
            }

            let key = fields[0]
            let value = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "Fichier":
                current.filename = value.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            case "URL":
                current.urlString = value
            case "Date":
                current.dateString = value
            default:
                break
            }
        }

        flushCurrent()
        return captures
    }

    static func appendCapture(_ capture: CaptureRecord, to existing: String) -> String {
        let prefix = existing.isEmpty ? "# Captures\n\n" : existing
        let block = captureBlock(capture)
        return prefix + block
    }

    static func removeCapture(named filename: String, from existing: String) -> String {
        let escapedFilename = NSRegularExpression.escapedPattern(for: filename)
        let pattern = #"<!--\s*CAPTURE:\s*\#(escapedFilename)\s*-->[\s\S]*?(\n\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return existing
        }

        let range = NSRange(existing.startIndex..<existing.endIndex, in: existing)
        return regex.stringByReplacingMatches(in: existing, options: [], range: range, withTemplate: "")
    }

    static func parseNotes(_ text: String) -> [String: String] {
        var notes: [String: String] = [:]
        var currentFilename: String?
        var currentBuffer: [String] = []

        func flushCurrentNote() {
            guard let filename = currentFilename else { return }
            notes[filename] = currentBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            currentFilename = nil
            currentBuffer.removeAll(keepingCapacity: true)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let startValue = firstCaptureGroup(in: trimmed, pattern: noteStartPattern) {
                flushCurrentNote()
                currentFilename = startValue
                continue
            }

            if matches(trimmed, pattern: noteEndPattern) {
                flushCurrentNote()
                continue
            }

            if currentFilename != nil {
                currentBuffer.append(rawLine)
            }
        }

        flushCurrentNote()
        return notes
    }

    static func serializeNotes(_ notesByFilename: [String: String]) -> String {
        let filtered = notesByFilename
            .filter { key, value in
                matches(key, pattern: safePNGFilenamePattern) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }

        guard !filtered.isEmpty else {
            return "# Notes\n\n"
        }

        var output = "# Notes\n\n"
        for (filename, rawNote) in filtered {
            let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
            output += "<!-- NOTE: \(filename) -->\n"
            output += "\(note)\n"
            output += "<!-- END NOTE -->\n\n"
        }
        return output
    }

    static func parseOrder(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && matches($0, pattern: safePNGFilenamePattern) }
    }

    static func serializeOrder(_ filenames: [String]) -> String {
        let filtered = filenames.filter { matches($0, pattern: safePNGFilenamePattern) }
        return filtered.isEmpty ? "" : filtered.joined(separator: "\n") + "\n"
    }

    private static func captureBlock(_ capture: CaptureRecord) -> String {
        let dateText = capture.capturedAt
            .map(LegacyDateFormatter.fullDateTimeString(from:))
            ?? LegacyDateFormatter.fullDateTimeString(from: .now)

        return """
        <!-- CAPTURE: \(capture.filename) -->
        - Fichier: `\(capture.filename)`
        - URL: \(capture.url.absoluteString)
        - Date: \(dateText)
        - Capture: [\(capture.filename)](./\(capture.filename))


        """
    }

    private static func firstCaptureGroup(in value: String, pattern: String) -> String? {
        captureGroups(in: value, pattern: pattern)?.first
    }

    private static func captureGroups(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: nsRange) else {
            return nil
        }

        guard match.numberOfRanges > 1 else { return [] }
        var result: [String] = []
        result.reserveCapacity(match.numberOfRanges - 1)
        for idx in 1..<match.numberOfRanges {
            let range = match.range(at: idx)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                result.append("")
                continue
            }
            result.append(String(value[swiftRange]))
        }
        return result
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
