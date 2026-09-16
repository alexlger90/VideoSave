import Foundation

enum SupportedSourceCatalog {
    static let names: [String] = [
        "XVideos",
        "PornBaker",
        "Pornhub",
        "SpankBang",
        "XGroovy",
        "xHamster",
        "Eporner",
        "Sxyprn",
        "PornHoarder",
        "Porn Sex Video",
        "HQPorner",
        "PornOne",
        "PornHD3x",
        "YouPorn",
        "RedTube",
        "FpoXXX",
        "Porneec",
        "Porn4Days",
        "Beeg",
        "XNXX",
        "Porn00",
        "InXXX",
        "XMoviesForYou",
        "PMVHaven",
        "FreshPorno",
        "ExePorn",
        "HdAbla",
        "Doeda",
        "TnAFlix",
        "SuperPorn",
        "AnySex",
        "BustyBus",
        "LetsPorn",
        "Evooli",
        "FreeOnes",
        "CollectionOfBestPorn",
        "Thumbzilla",
        "RedPorn",
        "HDporn92",
        "Shooshtime",
        "DrTuber",
        "Porn300",
        "PornoBae",
        "PussySpace",
        "VePorn",
        "LuxureTV",
        "Pornkai",
        "IPornTV",
        "PornZog",
        "ITPornIT",
        "UPornia",
        "VXXX",
        "PornoXO",
        "BaddiesXXX",
        "TheyAreHuge",
        "PornXP",
        "NoodleMagazine",
        "UKDevilz",
        "Mat6Tube",
        "SoloPornoItaliani",
        "YuVideos",
        "XXXGR",
        "BaddieHub",
        "AnyPorn",
        "Hypnosis Porn",
        "DampLips",
        "Buceteiro",
        "Tube8",
        "PornDig",
        "Intporn",
        "Sexu",
        "RedheadPornX",
        "PervertSlut",
        "Just Porn",
        "Netfapx",
        "YourDailyPornVideos",
        "PerfectGirls",
        "XLook",
        "HD-Easyporn",
        "PornHat",
        "PornHex",
        "PlayPorn",
        "PornHD8K",
        "TeenCFNM",
        "FSIBlog",
        "SextvX",
        "LaidHub",
        "PornDish",
        "JustFullPorn",
        "PornDoe",
        "TXXX",
        "CumLouder",
        "PornGo",
        "ClicPorn",
        "Just XXX",
        "PornTube",
        "PornAnn",
        "3Movs",
        "Porn4K.to",
        "PornRewind",
        "UltraHorny",
        "SegaVideo",
        "LongPorn",
        "PornL",
        "Camfall",
        "PornTrex",
        "PornXpert",
        "SexPeBune",
        "YouJizz",
        "XTapes",
        "ZHornyHub",
        "PetiteSpinners",
        "XKeezMovies"
    ]

    private static let compoundSuffixes: Set<String> = [
        "co.uk", "com.br", "com.au", "co.nz", "co.za",
        "com.mx", "com.ar", "com.tr", "com.ua"
    ]

    static func matches(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              !GenericTubeResolver.isDirectMediaURL(url) else {
            return false
        }

        // Pornhub keeps its dedicated path-sensitive resolver.
        if brandKeys(for: url).contains("pornhub") {
            return false
        }

        let keys = brandKeys(for: url)
        return names.contains { !keys.isDisjoint(with: sourceKeys(for: $0)) }
    }

    static func displayName(for url: URL) -> String {
        let keys = brandKeys(for: url)
        if let match = names.first(where: { !keys.isDisjoint(with: sourceKeys(for: $0)) }) {
            return match
        }
        return url.host ?? "Webseite"
    }

    private static func brandKeys(for url: URL) -> Set<String> {
        guard let host = url.host?.lowercased() else { return [] }
        var labels = host.split(separator: ".").map(String.init)
        while labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else {
            return labels.first.map { Set([normalize($0)]) } ?? Set()
        }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        let suffixCount = compoundSuffixes.contains(lastTwo) ? 2 : 1
        guard labels.count > suffixCount else { return [] }

        let brandIndex = labels.count - suffixCount - 1
        let brand = labels[brandIndex]
        let suffix = labels.suffix(suffixCount).joined()
        return [normalize(brand), normalize(brand + suffix)]
    }

    private static func sourceKeys(for name: String) -> Set<String> {
        var keys: Set<String> = [normalize(name)]
        if let first = name.split(separator: ".", maxSplits: 1).first {
            keys.insert(normalize(String(first)))
        }
        return keys
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum GenericTubeResolver {
    private struct RawCandidate {
        let url: URL
        let quality: Int
        let bandwidth: Int
        let kind: PornhubMediaKind
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

    static func isDirectMediaURL(_ url: URL) -> Bool {
        mediaKind(for: url) != nil
    }

    static func resolve(
        _ pageURL: URL,
        using suppliedSession: URLSession? = nil
    ) async throws -> PornhubResolution {
        let networkSession = suppliedSession ?? session
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
              pageURL.host != nil,
              !isDirectMediaURL(pageURL) else {
            throw VideoSaveError.unsupportedPage
        }

        let pageHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            "Referer": rootReferer(for: pageURL),
            "Accept-Language": "en-US,en;q=0.8",
            "User-Agent": VideoSaveBrowserUserAgent
        ]

        let (data, response) = try await requestData(
            url: pageURL,
            headers: pageHeaders,
            session: networkSession
        )

        guard let body = String(data: data, encoding: .utf8) else {
            try MediaAccessPolicy.validateResponse(response)
            throw VideoSaveError.mediaNotFound
        }

        // Surface a real CAPTCHA/login/access page before considering embedded URLs.
        try MediaAccessPolicy.validatePage(body, finalURL: response.url)
        try MediaAccessPolicy.validateResponse(response)

        let baseURL = response.url ?? pageURL
        let extracted = extractCandidates(from: body, baseURL: baseURL)
        guard !extracted.isEmpty else {
            throw VideoSaveError.mediaNotFound
        }

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

        var resolved: [PornhubMediaCandidate] = []

        for candidate in extracted.sorted(by: candidateSort) {
            switch candidate.kind {
            case .direct:
                resolved.append(
                    PornhubMediaCandidate(
                        url: candidate.url,
                        quality: candidate.quality,
                        bandwidth: candidate.bandwidth,
                        kind: .direct
                    )
                )

            case .hls:
                do {
                    let (playlistData, playlistResponse) = try await requestData(
                        url: candidate.url,
                        headers: mediaHeaders,
                        session: networkSession
                    )

                    if let text = String(data: playlistData, encoding: .utf8),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                        try MediaAccessPolicy.validatePage(text, finalURL: playlistResponse.url)
                    }

                    try MediaAccessPolicy.validateResponse(playlistResponse)
                    guard let playlist = String(data: playlistData, encoding: .utf8) else {
                        continue
                    }
                    try MediaAccessPolicy.validatePlaylist(playlist)

                    let variants = try HLSParser.parseMasterPlaylist(
                        text: playlist,
                        baseURL: playlistResponse.url ?? candidate.url
                    )

                    if variants.isEmpty {
                        resolved.append(
                            PornhubMediaCandidate(
                                url: candidate.url,
                                quality: candidate.quality,
                                bandwidth: candidate.bandwidth,
                                kind: .hls
                            )
                        )
                    } else {
                        resolved.append(contentsOf: variants.map {
                            PornhubMediaCandidate(
                                url: $0.url,
                                quality: $0.height > 0 ? $0.height : candidate.quality,
                                bandwidth: $0.bandwidth,
                                kind: .hls
                            )
                        })
                    }
                } catch let error as VideoSaveError {
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
        }

        let ordered = MediaCandidateOrdering.order(
            deduplicateResolved(resolved),
            quality: "Original"
        )
        guard let best = ordered.first else {
            throw VideoSaveError.mediaNotFound
        }

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

    private static func rootReferer(for url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else {
            return url.absoluteString
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        return components.url?.absoluteString ?? url.absoluteString
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

    private static func extractCandidates(from body: String, baseURL: URL) -> [RawCandidate] {
        var candidates: [RawCandidate] = []

        let patterns = [
            #"(?:src|data-src|data-video-src|data-video-url|content)\s*=\s*[\"']([^\"']+)[\"']"#,
            #"[\"'](?:contentUrl|videoUrl|video_url|videoSrc|video_src|file|source|src|url|hls|hlsUrl|hls_url|streamUrl|stream_url|downloadUrl|download_url|mediaUrl|media_url|mp4|playbackUrl|playback_url)[\"']\s*[:=]\s*[\"']([^\"']+)[\"']"#,
            #"(https?:\\?/\\?/[^\s\"'<>]+?\.(?:mp4|m4v|mov|m3u8)(?:\?[^\s\"'<>]*)?)"#,
            #"(//[^\s\"'<>]+?\.(?:mp4|m4v|mov|m3u8)(?:\?[^\s\"'<>]*)?)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }

            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            for match in regex.matches(in: body, range: range) {
                guard match.numberOfRanges > 1,
                      let capture = Range(match.range(at: 1), in: body),
                      let url = makeMediaURL(String(body[capture]), baseURL: baseURL),
                      let kind = mediaKind(for: url) else {
                    continue
                }

                let urlQuality = qualityFromURL(url)
                let quality = urlQuality > 0
                    ? urlQuality
                    : (qualityAround(match: match.range, in: body) ?? 0)
                candidates.append(
                    RawCandidate(
                        url: url,
                        quality: quality,
                        bandwidth: 0,
                        kind: kind
                    )
                )
            }
        }

        return deduplicateRaw(candidates)
    }

    private static func qualityAround(match: NSRange, in text: String) -> Int? {
        let nsLength = (text as NSString).length
        let start = max(0, match.location - 140)
        let end = min(nsLength, match.location + match.length + 140)
        guard end > start,
              let range = Range(NSRange(location: start, length: end - start), in: text) else {
            return nil
        }

        let snippet = String(text[range])
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(2160|1440|1080|720|540|480|360|240)p"#),
              let found = regex.firstMatch(
                in: snippet,
                range: NSRange(snippet.startIndex..<snippet.endIndex, in: snippet)
              ),
              let numberRange = Range(found.range(at: 1), in: snippet) else {
            return nil
        }
        return Int(snippet[numberRange])
    }

    private static func makeMediaURL(_ raw: String, baseURL: URL) -> URL? {
        var value = raw
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u003A"#, with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u003F"#, with: "?", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u003D"#, with: "=", options: .caseInsensitive)
            .replacingOccurrences(of: #"\u0026"#, with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))

        if value.hasPrefix("//") {
            value = (baseURL.scheme ?? "https") + ":" + value
        }

        if let decoded = value.removingPercentEncoding,
           decoded.lowercased().contains(".mp4") ||
            decoded.lowercased().contains(".m4v") ||
            decoded.lowercased().contains(".mov") ||
            decoded.lowercased().contains(".m3u8") {
            value = decoded
        }

        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              mediaKind(for: url) != nil else {
            return nil
        }
        return url
    }

    private static func mediaKind(for url: URL) -> PornhubMediaKind? {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "m3u8" { return .hls }
        if ["mp4", "m4v", "mov"].contains(pathExtension) { return .direct }

        let lower = url.absoluteString.lowercased()
        if lower.range(of: #"\.m3u8(?:[?#]|$)"#, options: .regularExpression) != nil {
            return .hls
        }
        if lower.range(of: #"\.(?:mp4|m4v|mov)(?:[?#]|$)"#, options: .regularExpression) != nil {
            return .direct
        }
        return nil
    }

    private static func qualityFromURL(_ url: URL) -> Int {
        let value = url.absoluteString
        for pattern in [
            #"(?i)(\d{3,4})p"#,
            #"(?i)(?:^|[_/.-])(\d{3,4})(?:p)?(?:[_/.-]|$)"#,
            #"(?i)(?:quality|resolution|height)[=_-](\d{3,4})"#
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let range = Range(match.range(at: 1), in: value),
                  let number = Int(value[range]) else {
                continue
            }
            return number
        }
        return 0
    }

    private static func candidateSort(_ lhs: RawCandidate, _ rhs: RawCandidate) -> Bool {
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        if lhs.kind != rhs.kind { return lhs.kind == .direct }
        if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
        return lhs.url.absoluteString < rhs.url.absoluteString
    }

    private static func deduplicateRaw(_ candidates: [RawCandidate]) -> [RawCandidate] {
        var byURL: [String: RawCandidate] = [:]
        for candidate in candidates {
            let key = candidate.url.absoluteString
            if let existing = byURL[key] {
                if existing.quality == 0 && candidate.quality > 0 {
                    byURL[key] = candidate
                }
            } else {
                byURL[key] = candidate
            }
        }
        return Array(byURL.values)
    }

    private static func deduplicateResolved(
        _ candidates: [PornhubMediaCandidate]
    ) -> [PornhubMediaCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
