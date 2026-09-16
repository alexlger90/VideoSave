import Foundation

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
        let path = finalURL?.path.lowercased() ?? ""
        let query = finalURL?.query?.lowercased() ?? ""

        // Many normal video pages preload CAPTCHA/Cloudflare JavaScript. Only
        // visible challenge wording or an actual challenge URL counts as a CAPTCHA.
        // This detects the gate; it never solves or bypasses it.
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

        if challengeURL || explicitChallengeText.contains(where: visible.contains) {
            throw VideoSaveError.captchaRequired
        }

        if path.hasPrefix("/login") || path.hasPrefix("/auth") ||
            ["login required", "log in to watch", "sign in to watch", "not available in your region", "not available in your country", "access denied", "premium members only", "this video is private"].contains(where: visible.contains) {
            throw VideoSaveError.accessBlocked
        }
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
