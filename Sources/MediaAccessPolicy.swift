import Foundation

// Keep browser identity consistent between direct resolving and the manual CAPTCHA view.
let VideoSaveBrowserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

// AVURLAsset accepts this raw options key for HTTP request headers. Xcode 16.4
// no longer exposes the old SDK declaration to Swift, so keep the string here.
let AVURLAssetHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

/// Fail closed when a source requires authorization or a protection check fails.
enum MediaAccessPolicy {
    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw VideoSaveError.httpError }
        if [401, 403, 429, 451].contains(http.statusCode) { throw VideoSaveError.accessBlocked }
        guard (200..<300).contains(http.statusCode) else { throw VideoSaveError.httpError }
    }

    static func validatePage(_ html: String, finalURL: URL?) throws {
        let visible = visibleText(from: html)
        let lowerHTML = html.lowercased()
        let path = finalURL?.path.lowercased() ?? ""
        let query = finalURL?.query?.lowercased() ?? ""

        // Normal video pages may preload CAPTCHA/Cloudflare JavaScript or even an
        // invisible widget. Those background assets must not block a playable page.
        // We stop for visible challenge wording, a real challenge URL, or active
        // challenge markup on a response that has no concrete media reference.
        // Detection never solves or bypasses the challenge.
        let explicitChallengeText = [
            "verify you are human",
            "verify that you are human",
            "complete the captcha",
            "captcha required",
            "human verification",
            "please complete the security check",
            "checking if the site connection is secure",
            "performing security verification"
        ]
        let challengeURL =
            path.contains("/captcha") ||
            path.contains("/challenge") ||
            path.contains("/verify-human") ||
            path.contains("/human-verification") ||
            query.contains("captcha=") ||
            query.contains("challenge=")

        let activeChallengeMarkup = [
            "class=\"g-recaptcha\"",
            "class='g-recaptcha'",
            "class=\"h-captcha\"",
            "class='h-captcha'",
            "class=\"cf-turnstile\"",
            "class='cf-turnstile'",
            "id=\"challenge-form\"",
            "id='challenge-form'",
            "data-sitekey=",
            "/cdn-cgi/challenge-platform/"
        ].contains(where: lowerHTML.contains)

        let hasMediaContainer = [
            "qualityitems_",
            "\"videourl\"",
            "\"mediadefinitions\""
        ].contains(where: lowerHTML.contains)
        let hasMediaExtension = [".mp4", ".m3u8", ".m4v", ".mov"]
            .contains(where: lowerHTML.contains)
        let hasConcreteMediaReference = hasMediaContainer && hasMediaExtension

        if challengeURL ||
            explicitChallengeText.contains(where: visible.contains) ||
            (activeChallengeMarkup && !hasConcreteMediaReference) {
            throw VideoSaveError.captchaRequired
        }

        if path.hasPrefix("/login") || path.hasPrefix("/auth") ||
            ["login required", "log in to watch", "sign in to watch", "not available in your region", "not available in your country", "access denied", "premium members only", "this video is private"].contains(where: visible.contains) {
            throw VideoSaveError.accessBlocked
        }
    }

    static func validateDownloadedMedia(response: URLResponse, fileURL: URL) throws {
        let mimeType = response.mimeType?.lowercased() ?? ""
        let textualMime = mimeType == "text/html" ||
            mimeType == "application/xhtml+xml" ||
            mimeType.hasPrefix("text/")

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefixData = try handle.read(upToCount: 64 * 1024) ?? Data()
        let prefix = String(data: prefixData, encoding: .utf8) ?? ""
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let looksLikeHTML = textualMime ||
            trimmed.hasPrefix("<!doctype html") ||
            trimmed.hasPrefix("<html") ||
            trimmed.hasPrefix("<head") ||
            trimmed.hasPrefix("<body")

        guard looksLikeHTML else { return }

        // A CDN can answer a media URL with an HTML challenge/error page. Detect
        // that here so AVFoundation never receives HTML as if it were an MP4.
        try validatePage(prefix, finalURL: response.url)
        throw VideoSaveError.mediaNotFound
    }

    static func validatePlaylist(_ text: String) throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw VideoSaveError.mediaNotFound
        }
        if text.contains("#EXT-X-KEY") || text.contains("#EXT-X-SESSION-KEY") {
            throw VideoSaveError.protectedStream
        }
    }

    private static func visibleText(from html: String) -> String {
        var text = html
        let removablePatterns = [
            #"(?is)<!--.*?-->"#,
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<template\b[^>]*>.*?</template>"#,
            #"(?is)<[^>]+>"#
        ]
        for pattern in removablePatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&quot;": "\"",
            "&#39;": "'", "&lt;": "<", "&gt;": ">"
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
