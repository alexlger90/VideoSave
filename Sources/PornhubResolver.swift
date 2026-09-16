import Foundation

enum PornhubMediaKind: String, Hashable {
    case direct
    case hls
}

struct PornhubMediaCandidate: Hashable {
    let url: URL
    let quality: Int
    let bandwidth: Int
    let kind: PornhubMediaKind

    var qualityLabel: String {
        quality > 0 ? "\(quality)p" : "Original"
    }

    var typeLabel: String {
        switch kind {
        case .direct: return url.pathExtension.uppercased().isEmpty ? "DATEI" : url.pathExtension.uppercased()
        case .hls: return "HLS"
        }
    }
}

struct PornhubResolution {
    let pageURL: URL
    let defaultURL: URL
    let variants: [HLSVariant]
    let requestHeaders: [String: String]
    let candidates: [PornhubMediaCandidate]
}

enum MediaCandidateOrdering {
    static func order(_ candidates: [PornhubMediaCandidate], quality: String) -> [PornhubMediaCandidate] {
        let target = quality == "Original" ? nil : Int(quality.replacingOccurrences(of: "p", with: ""))

        return candidates.sorted { lhs, rhs in
            if let target {
                let lhsGroup = qualityGroup(lhs.quality, target: target)
                let rhsGroup = qualityGroup(rhs.quality, target: target)
                if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }

                if lhs.quality != rhs.quality {
                    switch lhsGroup {
                    case 1: return lhs.quality > rhs.quality // closest lower quality first
                    case 2: return lhs.quality < rhs.quality // closest higher quality first
                    default: return lhs.quality > rhs.quality
                    }
                }
            } else if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality
            }

            if lhs.kind != rhs.kind {
                return lhs.kind == .direct // prefer a normal media file at the same quality
            }
            if lhs.bandwidth != rhs.bandwidth {
                return lhs.bandwidth > rhs.bandwidth
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    private static func qualityGroup(_ quality: Int, target: Int) -> Int {
        if quality == target { return 0 }
        if quality > 0 && quality < target { return 1 }
        if quality > target { return 2 }
        return 3
    }
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
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func isPornhubPage(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "pornhub.com" || normalizedHost.hasSuffix(".pornhub.com") else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.path.lowercased() == "/view_video.php" &&
            components?.queryItems?.contains(where: {
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
            "User-Agent": VideoSaveBrowserUserAgent
        ]

        let (data, response) = try await requestData(url: pageURL, headers: pageHeaders, session: networkSession)
        guard let html = String(data: data, encoding: .utf8) else {
            try MediaAccessPolicy.validateResponse(response)
            throw VideoSaveError.mediaNotFound
        }

        // Validate the page before trusting media references contained in challenge/error markup.
        try MediaAccessPolicy.validatePage(html, finalURL: response.url)
        try MediaAccessPolicy.validateResponse(response)

        let extracted = extractCandidates(from: html, baseURL: response.url ?? pageURL)
        guard !extracted.isEmpty else { throw VideoSaveError.mediaNotFound }

        var mediaHeaders = [
            "Referer": pageURL.absoluteString,
            "Accept": "*/*",
            "User-Agent": VideoSaveBrowserUserAgent
        ]
        if suppliedSession == nil,
           let cookies = HTTPCookieStorage.shared.cookies(for: pageURL),
           !cookies.isEmpty {
            mediaHeaders["Cookie"] = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
        }

        let sorted = extracted.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.bandwidth > $1.bandwidth
        }

        var resolvedCandidates: [PornhubMediaCandidate] = sorted
            .filter { $0.url.pathExtension.lowercased() != "m3u8" }
            .map {
                PornhubMediaCandidate(
                    url: $0.url,
                    quality: $0.quality,
                    bandwidth: $0.bandwidth,
                    kind: .direct
                )
            }

        // Keep every usable HLS source. Master playlists are expanded to concrete
        // variants because some AVFoundation versions expose no video track for the
        // master URL itself even though its child playlist is perfectly playable.
        for hls in sorted.filter({ $0.url.pathExtension.lowercased() == "m3u8" }) {
            do {
                let (playlistData, playlistResponse) = try await requestData(
                    url: hls.url,
                    headers: mediaHeaders,
                    session: networkSession
                )
                try MediaAccessPolicy.validateResponse(playlistResponse)
                guard let playlist = String(data: playlistData, encoding: .utf8) else {
                    continue
                }
                try MediaAccessPolicy.validatePlaylist(playlist)

                let masterVariants = try HLSParser.parseMasterPlaylist(
                    text: playlist,
                    baseURL: playlistResponse.url ?? hls.url
                )

                if masterVariants.isEmpty {
                    resolvedCandidates.append(
                        PornhubMediaCandidate(
                            url: hls.url,
                            quality: hls.quality,
                            bandwidth: hls.bandwidth,
                            kind: .hls
                        )
                    )
                } else {
                    resolvedCandidates.append(contentsOf: masterVariants.map {
                        PornhubMediaCandidate(
                            url: $0.url,
                            quality: $0.height > 0 ? $0.height : hls.quality,
                            bandwidth: $0.bandwidth,
                            kind: .hls
                        )
                    })
                }
            } catch let error as VideoSaveError {
                // Access-control and stream-protection decisions are terminal. A stale
                // or malformed public candidate may simply be skipped in favor of another.
                switch error {
                case .accessBlocked, .captchaRequired, .protectedStream:
                    throw error
                default:
                    continue
                }
            } catch {
                continue
            }
        }

        resolvedCandidates = deduplicateResolved(resolvedCandidates)
        let ordered = MediaCandidateOrdering.order(resolvedCandidates, quality: "Original")
        guard let best = ordered.first else { throw VideoSaveError.mediaNotFound }

        let variants = ordered.map {
            HLSVariant(
                url: $0.url,
                width: 0,
                height: $0.quality,
                bandwidth: $0.bandwidth
            )
        }

        return PornhubResolution(
            pageURL: pageURL,
            defaultURL: best.url,
            variants: variants,
            requestHeaders: mediaHeaders,
            candidates: ordered
        )
    }

    private static func requestData(
        url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await session.data(for: request)
    }

    private static func extractCandidates(from html: String, baseURL: URL) -> [MediaCandidate] {
        var candidates: [MediaCandidate] = []

        let qualityPattern = #"qualityItems_[^=;]*\s*=\s*(\[[\s\S]*?\])\s*;"#
        if let regex = try? NSRegularExpression(pattern: qualityPattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range(at: 1), in: html),
                      let data = String(html[r]).data(using: .utf8),
                      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    continue
                }
                for item in items {
                    guard let raw = item["url"] as? String,
                          let url = makeURL(raw, baseURL: baseURL) else { continue }
                    candidates.append(
                        MediaCandidate(
                            url: url,
                            quality: qualityNumber(item["text"]) ?? qualityNumber(item["quality"]) ?? qualityFromURL(url),
                            bandwidth: intValue(item["bitrate"]) ?? intValue(item["bandwidth"]) ?? 0
                        )
                    )
                }
            }
        }

        for objectText in assignedJSONObjects(in: html, variablePrefix: "flashvars") {
            if let object = try? JSONSerialization.jsonObject(with: Data(objectText.utf8)) as? [String: Any] {
                collectMediaDefinitions(from: object, baseURL: baseURL, into: &candidates)
            }
        }

        // Older/newer page payloads can expose the same media through one of these
        // explicit video keys rather than mediaDefinitions.
        for key in ["videoUrl", "video_url"] {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"[\"']"# + escapedKey + #"[\"']\s*:\s*[\"']([^\"']+)[\"']"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(html.startIndex..<html.endIndex, in: html)
                for match in regex.matches(in: html, range: range) {
                    guard let r = Range(match.range(at: 1), in: html),
                          let url = makeURL(String(html[r]), baseURL: baseURL) else { continue }
                    candidates.append(MediaCandidate(url: url, quality: qualityFromURL(url), bandwidth: 0))
                }
            }
        }

        // Standards-based HTML5 sources are safe to consider when they point directly
        // to one of the media formats VideoSave already supports.
        let sourcePattern = #"(?is)<source\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#
        if let regex = try? NSRegularExpression(pattern: sourcePattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range(at: 1), in: html),
                      let url = makeURL(String(html[r]), baseURL: baseURL) else { continue }
                candidates.append(MediaCandidate(url: url, quality: qualityFromURL(url), bandwidth: 0))
            }
        }

        return deduplicate(candidates)
    }

    private static func collectMediaDefinitions(
        from object: [String: Any],
        baseURL: URL,
        into candidates: inout [MediaCandidate]
    ) {
        if let defs = object["mediaDefinitions"] as? [[String: Any]] {
            for definition in defs {
                guard let raw = definition["videoUrl"] as? String,
                      let url = makeURL(raw, baseURL: baseURL) else { continue }
                candidates.append(
                    MediaCandidate(
                        url: url,
                        quality: qualityNumber(definition["quality"]) ?? qualityFromURL(url),
                        bandwidth: intValue(definition["bitrate"]) ?? intValue(definition["bandwidth"]) ?? 0
                    )
                )
            }
        }

        for value in object.values {
            if let nested = value as? [String: Any] {
                collectMediaDefinitions(from: nested, baseURL: baseURL, into: &candidates)
            } else if let array = value as? [[String: Any]] {
                for nested in array {
                    collectMediaDefinitions(from: nested, baseURL: baseURL, into: &candidates)
                }
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
            guard offset < nsRange.length,
                  let start = Range(NSRange(location: offset, length: 0), in: html)?.lowerBound,
                  let brace = html[start...].firstIndex(of: "{"),
                  let object = balancedJSONObject(in: html, from: brace) else { continue }
            results.append(object)
        }
        return results
    }

    private static func balancedJSONObject(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
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

        if let decoded = value.removingPercentEncoding, decoded.hasPrefix("http") {
            value = decoded
        }

        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return url
    }

    private static func qualityNumber(_ value: Any?) -> Int? {
        if let number = intValue(value) { return number }
        guard let string = value as? String else { return nil }
        return Int(string.filter(\.isNumber))
    }

    private static func qualityFromURL(_ url: URL) -> Int {
        let value = url.absoluteString
        for pattern in [
            #"(?i)(\d{3,4})p"#,
            #"(?i)[_/](\d{3,4})[_/]"#,
            #"(?i)(?:quality|resolution)[=_-](\d{3,4})"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
               let range = Range(match.range(at: 1), in: value),
               let number = Int(value[range]) {
                return number
            }
        }
        return 0
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func deduplicate(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private static func deduplicateResolved(_ candidates: [PornhubMediaCandidate]) -> [PornhubMediaCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
