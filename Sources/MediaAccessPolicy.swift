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
        let lower = html.lowercased()
        let path = finalURL?.path.lowercased() ?? ""
        let query = finalURL?.query?.lowercased() ?? ""

        // Pornhub can ship CAPTCHA/challenge wording and related JavaScript in a
        // normal public video page. Do not treat that passive text as an active
        // challenge when the same response already contains a concrete playable
        // media reference. We still fail closed on an actual challenge URL or on
        // challenge text when no playable media is present. Nothing here solves,
        // submits, or bypasses a CAPTCHA.
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

        let hasMediaContainer = [
            "qualityitems_",
            "\"videourl\"",
            "\"mediadefinitions\""
        ].contains(where: lower.contains)
        let hasMediaExtension = [".mp4", ".m3u8", ".m4v", ".mov"]
            .contains(where: lower.contains)
        let hasPlayableMediaReference = hasMediaContainer && hasMediaExtension

        if challengeURL ||
            (!hasPlayableMediaReference && explicitChallengeText.contains(where: lower.contains)) {
            throw VideoSaveError.captchaRequired
        }

        if path.hasPrefix("/login") || path.hasPrefix("/auth") ||
            ["login required", "log in to watch", "sign in to watch", "not available in your region", "not available in your country", "access denied", "premium members only", "this video is private"].contains(where: lower.contains) {
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
}
