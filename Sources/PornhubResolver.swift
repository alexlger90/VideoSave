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

    static func isPornhubPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "pornhub.com"
                || normalizedHost.hasSuffix(".pornhub.com")
                || normalizedHost == "pornhub.net"
                || normalizedHost == "pornhub.org"
                || normalizedHost == "pornhubpremium.com"
                || normalizedHost.hasSuffix(".pornhubpremium.com")
        else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.path.lowercased().contains("view_video.php")
            && components?.queryItems?.contains(where: {
                $0.name.lowercased() == "viewkey" && !($0.value ?? "").isEmpty
            }) == true
    }

    static func resolve(_ pageURL: URL) async throws -> PornhubResolution {
        guard isPornhubPage(pageURL) else {
            throw VideoSaveError.unsupportedPage
        }

        var request = URLRequest(url: pageURL)
        request.httpMethod = "GET"
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "https://www.pornhub.com/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VideoSaveError.httpError
        }

        if http.statusCode == 403 || http.statusCode == 429 {
            throw VideoSaveError.accessBlocked
        }

        guard 200..<400 ~= http.statusCode else {
            throw VideoSaveError.httpError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw VideoSaveError.mediaNotFound
        }

        let candidates = extractCandidates(from: html, baseURL: pageURL)

        guard !candidates.isEmpty else {
            if html.localizedCaseInsensitiveContains("captcha")
                || html.localizedCaseInsensitiveContains("verify you are human") {
                throw VideoSaveError.captchaRequired
            }
            throw VideoSaveError.mediaNotFound
        }

        // Prefer HLS master playlists. Signed HLS URLs are normally short-lived,
        // so the resolver is deliberately run again immediately before download.
        let sorted = candidates.sorted {
            if $0.quality != $1.quality {
                return $0.quality > $1.quality
            }
            return $0.bandwidth > $1.bandwidth
        }

        var hlsCandidates: [MediaCandidate] = []
        var directCandidates: [MediaCandidate] = []

        for candidate in sorted {
            if candidate.url.pathExtension.lowercased() == "m3u8" {
                hlsCandidates.append(candidate)
            } else {
                directCandidates.append(candidate)
            }
        }

        let headers = [
            "Referer": "https://www.pornhub.com/",
            "Accept": "*/*"
        ]

        if let hls = hlsCandidates.first {
            let (playlistData, playlistResponse) = try await URLSession.shared.data(
                from: hls.url
            )

            guard (playlistResponse as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let playlist = String(data: playlistData, encoding: .utf8)
            else {
                throw VideoSaveError.httpError
            }

            if playlist.contains("#EXT-X-KEY")
                || playlist.contains("#EXT-X-SESSION-KEY") {
                throw VideoSaveError.protectedStream
            }

            let variants = try HLSParser.parseMasterPlaylist(
                text: playlist,
                baseURL: hls.url
            ).sorted {
                if $0.height != $1.height {
                    return $0.height > $1.height
                }
                return $0.bandwidth > $1.bandwidth
            }

            if !variants.isEmpty {
                return PornhubResolution(
                    pageURL: pageURL,
                    defaultURL: hls.url,
                    variants: variants,
                    requestHeaders: headers
                )
            }

            return PornhubResolution(
                pageURL: pageURL,
                defaultURL: hls.url,
                variants: [
                    HLSVariant(
                        url: hls.url,
                        width: 0,
                        height: hls.quality,
                        bandwidth: hls.bandwidth
                    )
                ],
                requestHeaders: headers
            )
        }

        guard let best = directCandidates.first else {
            throw VideoSaveError.mediaNotFound
        }

        let variants = directCandidates.map {
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
            requestHeaders: headers
        )
    }

    private static func extractCandidates(
        from html: String,
        baseURL: URL
    ) -> [MediaCandidate] {
        var candidates: [MediaCandidate] = []

        // Primary path: flashvars_N JSON used by the page. The JSON is decoded
        // without executing page JavaScript.
        for objectText in assignedJSONObjects(in: html, variablePrefix: "flashvars") {
            if let object = try? JSONSerialization.jsonObject(
                with: Data(objectText.utf8)
            ) as? [String: Any] {
                collectMediaDefinitions(
                    from: object,
                    baseURL: baseURL,
                    into: &candidates
                )
            }
        }

        // Fallback: collect literal videoUrl fields from embedded JSON/JS.
        let videoURLPattern =
            #""videoUrl"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: videoURLPattern) {
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: nsRange) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let value = String(html[range])
                if let url = makeURL(value, baseURL: baseURL) {
                    candidates.append(
                        MediaCandidate(
                            url: url,
                            quality: qualityFromURL(url),
                            bandwidth: 0
                        )
                    )
                }
            }
        }

        // Last fallback: links explicitly exposed by the page as downloadable
        // media. No authentication, CAPTCHA or access-control mechanism is bypassed.
        let hrefPattern =
            #"<a\b[^>]*\bhref\s*=\s*["']([^"']+\.(?:mp4|m3u8)(?:\?[^"']*)?)["'][^>]*>"#
        if let regex = try? NSRegularExpression(
            pattern: hrefPattern,
            options: [.caseInsensitive]
        ) {
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: nsRange) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let value = String(html[range])
                if let url = makeURL(value, baseURL: baseURL) {
                    candidates.append(
                        MediaCandidate(
                            url: url,
                            quality: qualityFromURL(url),
                            bandwidth: 0
                        )
                    )
                }
            }
        }

        return deduplicate(candidates)
    }

    private static func collectMediaDefinitions(
        from object: [String: Any],
        baseURL: URL,
        into candidates: inout [MediaCandidate]
    ) {
        if let definitions = object["mediaDefinitions"] as? [[String: Any]] {
            for definition in definitions {
                guard let rawURL = definition["videoUrl"] as? String,
                      let url = makeURL(rawURL, baseURL: baseURL)
                else { continue }

                let quality = intValue(definition["quality"])
                    ?? qualityFromURL(url)
                let bandwidth = intValue(definition["bitrate"])
                    ?? intValue(definition["bandwidth"])
                    ?? 0

                candidates.append(
                    MediaCandidate(
                        url: url,
                        quality: quality,
                        bandwidth: bandwidth
                    )
                )
            }
        }

        // Some page revisions nest media definitions inside another object.
        for value in object.values {
            if let nested = value as? [String: Any] {
                collectMediaDefinitions(
                    from: nested,
                    baseURL: baseURL,
                    into: &candidates
                )
            } else if let nestedArray = value as? [[String: Any]] {
                for nested in nestedArray {
                    collectMediaDefinitions(
                        from: nested,
                        baseURL: baseURL,
                        into: &candidates
                    )
                }
            }
        }
    }

    private static func assignedJSONObjects(
        in html: String,
        variablePrefix: String
    ) -> [String] {
        let pattern = #"\bvar\s+\#(variablePrefix)_\d+\s*=\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [String] = []

        for match in regex.matches(in: html, range: nsRange) {
            let startOffset = match.range.location + match.range.length
            guard startOffset < nsRange.length else { continue }
            let start = html.index(
                html.startIndex,
                offsetBy: startOffset
            )

            guard let openBrace = html[start...].firstIndex(of: "{") else {
                continue
            }

            if let object = balancedJSONObject(
                in: html,
                from: openBrace
            ) {
                results.append(object)
            }
        }

        return results
    }

    private static func balancedJSONObject(
        in text: String,
        from start: String.Index
    ) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func makeURL(
        _ raw: String,
        baseURL: URL
    ) -> URL? {
        var value = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u003A", with: ":")
            .replacingOccurrences(of: "\\u003F", with: "?")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let decoded = value.removingPercentEncoding,
           decoded.hasPrefix("http") {
            value = decoded
        }

        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private static func qualityFromURL(_ url: URL) -> Int {
        let value = url.absoluteString

        let patterns = [
            #"(?i)(\d{3,4})p"#,
            #"(?i)[_/](\d{3,4})[_/]"#,
            #"(?i)(?:quality|resolution)[=_-](\d{3,4})"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
               ),
               let range = Range(match.range(at: 1), in: value),
               let number = Int(value[range]) {
                return number
            }
        }

        return 0
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func deduplicate(
        _ candidates: [MediaCandidate]
    ) -> [MediaCandidate] {
        var seen = Set<String>()
        return candidates.filter {
            let key = $0.url.absoluteString
            guard seen.insert(key).inserted else { return false }
            return true
        }
    }
}
