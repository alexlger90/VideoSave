import Foundation

struct PornhubResolution {
    let pageURL: URL
    let defaultURL: URL
    let variants: [HLSVariant]
    let requestHeaders: [String: String]
}

enum PornhubResolver {
    private struct MediaCandidate { let url: URL; let quality: Int; let bandwidth: Int }

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
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "pornhub.com" || normalizedHost.hasSuffix(".pornhub.com") else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.path.lowercased() == "/view_video.php" && components?.queryItems?.contains(where: { $0.name.lowercased() == "viewkey" && !($0.value ?? "").isEmpty }) == true
    }

    static func resolve(_ pageURL: URL, using suppliedSession: URLSession? = nil) async throws -> PornhubResolution {
        let networkSession = suppliedSession ?? session
        guard isPornhubPage(pageURL) else { throw VideoSaveError.unsupportedPage }
        let pageHeaders = ["Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Referer":"https://www.pornhub.com/", "Accept-Language":"en-US,en;q=0.8", "User-Agent":VideoSaveBrowserUserAgent]
        let (data, response) = try await requestData(url: pageURL, headers: pageHeaders, session: networkSession)
        guard let html = String(data: data, encoding: .utf8) else { try MediaAccessPolicy.validateResponse(response); throw VideoSaveError.mediaNotFound }
        try MediaAccessPolicy.validatePage(html, finalURL: response.url)
        try MediaAccessPolicy.validateResponse(response)
        let candidates = extractCandidates(from: html, baseURL: response.url ?? pageURL)
        guard !candidates.isEmpty else { throw VideoSaveError.mediaNotFound }

        let sorted = candidates.sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.bandwidth > $1.bandwidth }
        let hlsCandidates = sorted.filter { $0.url.pathExtension.lowercased() == "m3u8" }
        let directCandidates = sorted.filter { $0.url.pathExtension.lowercased() != "m3u8" }
        var mediaHeaders = ["Referer":pageURL.absoluteString, "Accept":"*/*", "User-Agent":VideoSaveBrowserUserAgent]
        if suppliedSession == nil, let cookies = HTTPCookieStorage.shared.cookies(for: pageURL), !cookies.isEmpty {
            mediaHeaders["Cookie"] = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
        }

        if let best = directCandidates.first {
            return PornhubResolution(pageURL: pageURL, defaultURL: best.url, variants: directCandidates.map { HLSVariant(url: $0.url, width: 0, height: $0.quality, bandwidth: $0.bandwidth) }, requestHeaders: mediaHeaders)
        }
        guard let hls = hlsCandidates.first else { throw VideoSaveError.mediaNotFound }
        let (playlistData, playlistResponse) = try await requestData(url: hls.url, headers: mediaHeaders, session: networkSession)
        try MediaAccessPolicy.validateResponse(playlistResponse)
        guard let playlist = String(data: playlistData, encoding: .utf8) else { throw VideoSaveError.mediaNotFound }
        try MediaAccessPolicy.validatePlaylist(playlist)
        let variants = try HLSParser.parseMasterPlaylist(text: playlist, baseURL: playlistResponse.url ?? hls.url).sorted { $0.height != $1.height ? $0.height > $1.height : $0.bandwidth > $1.bandwidth }
        let playableVariants = variants.isEmpty ? [HLSVariant(url: hls.url, width: 0, height: hls.quality, bandwidth: hls.bandwidth)] : variants
        // A master playlist itself may not expose a video track to AVFoundation.
        // For "Original", use the highest concrete variant when one exists.
        let playableDefault = variants.first?.url ?? hls.url
        return PornhubResolution(pageURL: pageURL, defaultURL: playableDefault, variants: playableVariants, requestHeaders: mediaHeaders)
    }

    private static func requestData(url: URL, headers: [String:String], session: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url); request.httpMethod = "GET"; for (f,v) in headers { request.setValue(v, forHTTPHeaderField: f) }; return try await session.data(for: request)
    }

    private static func extractCandidates(from html: String, baseURL: URL) -> [MediaCandidate] {
        var candidates:[MediaCandidate] = []
        let qualityPattern = #"qualityItems_[^=;]*\s*=\s*(\[[\s\S]*?\])\s*;"#
        if let regex = try? NSRegularExpression(pattern: qualityPattern) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range(at:1), in:html), let data = String(html[r]).data(using:.utf8), let items = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] else { continue }
                for item in items { guard let raw=item["url"] as? String, let url=makeURL(raw,baseURL:baseURL) else { continue }; candidates.append(MediaCandidate(url:url,quality:qualityNumber(item["text"]) ?? qualityNumber(item["quality"]) ?? qualityFromURL(url),bandwidth:0)) }
            }
        }
        for objectText in assignedJSONObjects(in:html,variablePrefix:"flashvars") { if let object=try? JSONSerialization.jsonObject(with:Data(objectText.utf8)) as? [String:Any] { collectMediaDefinitions(from:object,baseURL:baseURL,into:&candidates) } }
        let pattern = #""videoUrl"\s*:\s*"([^"]+)""#
        if let regex=try? NSRegularExpression(pattern:pattern) { let range=NSRange(html.startIndex..<html.endIndex,in:html); for match in regex.matches(in:html,range:range) { guard let r=Range(match.range(at:1),in:html), let url=makeURL(String(html[r]),baseURL:baseURL) else { continue }; candidates.append(MediaCandidate(url:url,quality:qualityFromURL(url),bandwidth:0)) } }
        return deduplicate(candidates)
    }

    private static func collectMediaDefinitions(from object:[String:Any],baseURL:URL,into candidates:inout [MediaCandidate]) {
        if let defs=object["mediaDefinitions"] as? [[String:Any]] { for d in defs { guard let raw=d["videoUrl"] as? String, let url=makeURL(raw,baseURL:baseURL) else { continue }; candidates.append(MediaCandidate(url:url,quality:qualityNumber(d["quality"]) ?? qualityFromURL(url),bandwidth:intValue(d["bitrate"]) ?? intValue(d["bandwidth"]) ?? 0)) } }
        for value in object.values { if let nested=value as? [String:Any] { collectMediaDefinitions(from:nested,baseURL:baseURL,into:&candidates) } else if let array=value as? [[String:Any]] { for nested in array { collectMediaDefinitions(from:nested,baseURL:baseURL,into:&candidates) } } }
    }

    private static func assignedJSONObjects(in html:String,variablePrefix:String)->[String] { let pattern=#"\bvar\s+\#(variablePrefix)_\d+\s*=\s*"#; guard let regex=try? NSRegularExpression(pattern:pattern) else{return[]}; let ns=NSRange(html.startIndex..<html.endIndex,in:html); var results:[String]=[]; for match in regex.matches(in:html,range:ns){let offset=match.range.location+match.range.length; guard offset<ns.length, let start=Range(NSRange(location:offset,length:0),in:html)?.lowerBound, let brace=html[start...].firstIndex(of:"{"), let object=balancedJSONObject(in:html,from:brace) else{continue}; results.append(object)}; return results }
    private static func balancedJSONObject(in text:String,from start:String.Index)->String? { var depth=0,inString=false,escaped=false,index=start; while index<text.endIndex { let c=text[index]; if inString { if escaped{escaped=false}else if c=="\\"{escaped=true}else if c=="\""{inString=false} } else if c=="\""{inString=true}else if c=="{"{depth+=1}else if c=="}"{depth-=1;if depth==0{return String(text[start...index])}}; index=text.index(after:index)}; return nil }
    private static func makeURL(_ raw:String,baseURL:URL)->URL? { var value=raw.replacingOccurrences(of:"\\/",with:"/").replacingOccurrences(of:"\\u002F",with:"/").replacingOccurrences(of:"\\u003A",with:":").replacingOccurrences(of:"\\u003F",with:"?").replacingOccurrences(of:"\\u003D",with:"=").replacingOccurrences(of:"\\u0026",with:"&").replacingOccurrences(of:"&amp;",with:"&").trimmingCharacters(in:.whitespacesAndNewlines); if let decoded=value.removingPercentEncoding,decoded.hasPrefix("http"){value=decoded}; guard let url=URL(string:value,relativeTo:baseURL)?.absoluteURL,["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,["mp4","mov","m4v","m3u8"].contains(url.pathExtension.lowercased()) else{return nil}; return url }
    private static func qualityNumber(_ value:Any?)->Int? { if let n=intValue(value){return n}; guard let s=value as? String else{return nil}; return Int(s.filter(\.isNumber)) }
    private static func qualityFromURL(_ url:URL)->Int { let value=url.absoluteString; for pattern in [#"(?i)(\d{3,4})p"#,#"(?i)[_/](\d{3,4})[_/]"#,#"(?i)(?:quality|resolution)[=_-](\d{3,4})"#] { if let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:value,range:NSRange(value.startIndex..<value.endIndex,in:value)),let range=Range(match.range(at:1),in:value),let number=Int(value[range]){return number} }; return 0 }
    private static func intValue(_ value:Any?)->Int? { if let i=value as? Int{return i}; if let n=value as? NSNumber{return n.intValue}; if let s=value as? String{return Int(s)}; return nil }
    private static func deduplicate(_ candidates:[MediaCandidate])->[MediaCandidate] { var seen=Set<String>(); return candidates.filter{seen.insert($0.url.absoluteString).inserted} }
}
