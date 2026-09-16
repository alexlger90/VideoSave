import Foundation

/// Fail closed when a source requires authorization or a protection check fails.
enum MediaAccessPolicy {
    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw VideoSaveError.httpError }
        if [401, 403, 429, 451].contains(http.statusCode) { throw VideoSaveError.accessBlocked }
        guard (200..<300).contains(http.statusCode) else { throw VideoSaveError.httpError }
    }

    static func validatePage(_ html: String, finalURL: URL?) throws {
        let lower = html.lowercased()
        if ["verify you are human", "complete the captcha", "captcha required", "g-recaptcha", "h-captcha", "cf-chl-"].contains(where: lower.contains) {
            throw VideoSaveError.captchaRequired
        }
        let path = finalURL?.path.lowercased() ?? ""
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
