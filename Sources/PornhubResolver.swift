import Foundation

struct PornhubResolution {
    let pageURL: URL
    let defaultURL: URL
    let variants: [HLSVariant]
    let requestHeaders: [String: String]
}

enum PornhubResolver {
    private struct MediaCandidate {
        let url: URL
        let quality: Int
        let bandwidth: Int
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func isPornhubPage(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "pornhub.com" || normalizedHost.hasSuffix(".pornhub.com") else {
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.path.lowercased() == "/view_video.php"
            && components?.queryItems?.contains(where: {
                $0.name.lowercased() == "viewkey" && !($0.value ?? "").isEmpty
            }) == true
    }

    static func resolve(_ pageURL: URL, using suppliedSession: URLSession? = nil) async throws -> PornhubResolution {
        let networkSession = suppliedSession ?? session
        guard isPornhubPage(pageURL) else { throw VideoSaveError.unsupportedPage }

        let pageHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Referer": "https://www.pornhub.com/",
            "Accept-Language": "en-US,en;q=0.8",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        ]

        let (data, response) = try await requestData(url: pageURL, headers: pageHeaders, session: networkSession)
        try MediaAccessPolicy.validateResponse(response)
        guard let html = String(data: data, encoding: .utf8) else { throw VideoSaveError.mediaNotFound }
        try MediaAccessPolicy.validatePage(html, finalURL: response.url)
        let candidates = extractCandidates(from: html, baseURL: response.url ?? pageURL)
        guard !candidates.isEmpty else { throw VideoSaveError.mediaNotFound }

        let sorted = candidates.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.bandwidth > $1.bandwidth
        }
        let hlsCandidates = sorted.filter { $0.url.pathExtension.lowercased() == "m3u8" }
        let directCandidates = sorted.filter { $0.url.pathExtension.lowercased() != "m3u8" }
        let mediaHeaders = ["Referer": pageURL.absoluteString, "Accept": "*/*", "User-Agent": pageHeaders["User-Agent"]!]

        if let hls = hlsCandidates.first {
            let (playlistData, playlistResponse) = try await requestData(url: hls.url, headers: mediaHeaders, session: networkSession)
            try MediaAccessPolicy.validateResponse(playlistResponse)
            guard let playlist = String(data: playlistData, encoding: .utf8) else { throw VideoSaveError.mediaNotFound }
            try MediaAccessPolicy.validatePlaylist(playlist)

            let variants = try HLSParser.parseMasterPlaylist(text: playlist, baseURL: playlistResponse.url ?? hls.url).sorted {
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.bandwidth > $1.bandwidth
            }
            return PornhubResolution(
                pageURL: pageURL,
                defaultURL: hls.url,
                variants: variants.isEmpty ? [HLSVariant(url: hls.url, width: 0, height: hls.quality, bandwidth: hls.bandwidth)] : variants,
                requestHeaders: mediaHeaders
            )
        }

        guard let best = directCandidates.first else { throw VideoSaveError.mediaNotFound }
        return PornhubResolution(
            pageURL: pageURL,
            defaultURL: best.url,
            variants: directCandidates.map { HLSVariant(url: $0.url, width: 0, height: $0.quality, bandwidth: $0.bandwidth) },
            requestHeaders: mediaHeaders
        )
    }

    private static func requestData(url: URL, headers: [String: String], session: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await session.data(for: request)
    }

    private static func extractCandidates(from html: String, baseURL: URL) -> [MediaCandidate] {
        var candidates: [MediaCandidate] = []

        // ResolveURL's current Pornhub plugin first looks for qualityItems_*.
        let qualityPattern = #"qualityItems_[^=;]*\s*=\s*(\[[\s\S]*?\])\s*;"#
        if let regex = try? NSRegularExpression(pattern: qualityPattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let swiftRange = Range(match.range(at: 1), in: html),
                      let data = String(html[swiftRange]).data(using: .utf8),
                      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                for item in items {
                    guard let raw = item["url"] as? String, let url = makeURL(raw, baseURL: baseURL) else { continue }
                    let quality = qualityNumber(item["text"]) ?? qualityNumber(item["quality"]) ?? qualityFromURL(url)
                    candidates.append(MediaCandidate(url: url, quality: quality, bandwidth: 0))
                }
            }
        }

        for objectText in assignedJSONObjects(in: html, variablePrefix: "flashvars") {
            if let object = try? JSONSerialization.jsonObject(with: Data(objectText.utf8)) as? [String: Any] {
                collectMediaDefinitions(from: object, baseURL: baseURL, into: &candidates)
            }
        }

        let videoURLPattern = #""videoUrl"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: videoURLPattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range(at: 1), in: html), let url = makeURL(String(html[r]), baseURL: baseURL) else { continue }
                candidates.append(MediaCandidate(url: url, quality: qualityFromURL(url), bandwidth: 0))
            }
        }

        return deduplicate(candidates)
    }

    private static func collectMediaDefinitions(from object: [String: Any], baseURL: URL, into candidates: inout [MediaCandidate]) {
        if let definitions = object["mediaDefinitions"] as? [[String: Any]] {
            for definition in definitions {
                guard let raw = definition["videoUrl"] as? String, let url = makeURL(raw, baseURL: baseURL) else { continue }
                candidates.append(MediaCandidate(
                    url: url,
                    quality: qualityNumber(definition["quality"]) ?? qualityFromURL(url),
                    bandwidth: intValue(definition["bitrate"]) ?? intValue(definition["bandwidth"]) ?? 0
                ))
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any] {
                collectMediaDefinitions(from: nested, baseURL: baseURL, into: &candidates)
            } else if let array = value as? [[String: Any]] {
                for nested in array { collectMediaDefinitions(from: nested, baseURL: baseURL, into: &candidates) }
            }
        }
    }

    private static func assignedJSONObjects(in html: String, variablePrefix: String) -> [String] {
        let pattern = #"\bvar\s+\#(variablePrefix)_\d+\s*=\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [String] = []
        for match in regex.matches(in: html, range: nsRange) {
            let offset = match.range.location + match.range.length
            guard offset < nsRange.length else { continue }
            guard let start = Range(NSRange(location: offset, length: 0), in: html)?.lowerBound else { continue }
            guard let brace = html[start...].firstIndex(of: "{"), let object = balancedJSONObject(in: html, from: brace) else { continue }
            results.append(object)
        }
        return results
    }

    private static func balancedJSONObject(in text: String, from start: String.Index) -> String? {
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(text[start...index]) } }
            index = text.index(after: index)
        }
        return nil
    }

    private static func makeURL(_ raw: String, baseURL: URL) -> URL? {
        var value = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u003A", with: ":")
            .replacingOccurrences(of: "\\u003F", with: "?")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = value.removingPercentEncoding, decoded.hasPrefix("http") { value = decoded }
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    private static func qualityNumber(_ value: Any?) -> Int? {
        if let number = intValue(value) { return number }
        guard let string = value as? String else { return nil }
        let digits = string.filter(\.isNumber)
        return Int(digits)
    }

    private static func qualityFromURL(_ url: URL) -> Int {
        let value = url.absoluteString
        for pattern in [#"(?i)(\d{3,4})p"#, #"(?i)[_/](\d{3,4})[_/]"#, #"(?i)(?:quality|resolution)[=_-](\d{3,4})"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
               let range = Range(match.range(at: 1), in: value), let number = Int(value[range]) { return number }
        }
        return 0
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func deduplicate(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
