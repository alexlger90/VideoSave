import Foundation

/// The same URL validation is used by the extension and the app's paste action.
enum SharedLink {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = validatedURL(trimmed) { return direct }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            match.url.flatMap { validatedURL($0.absoluteString) }
        }.first
    }

    private static func validatedURL(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
