import Foundation

/// Shared URL validation for the app, share extension and VideoSave deep links.
enum SharedLink {
    static let appScheme = "videosave"

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = validatedURL(trimmed) { return direct }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            match.url.flatMap { validatedURL($0.absoluteString) }
        }.first
    }

    static func appImportURL(for sharedURL: URL) -> URL? {
        guard let safeURL = validatedURL(sharedURL.absoluteString) else { return nil }
        var components = URLComponents()
        components.scheme = appScheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: safeURL.absoluteString)]
        return components.url
    }

    static func importedURL(from appURL: URL) -> URL? {
        guard appURL.scheme?.lowercased() == appScheme,
              appURL.host?.lowercased() == "import",
              let components = URLComponents(url: appURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        return validatedURL(raw)
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
