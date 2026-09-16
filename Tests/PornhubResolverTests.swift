import XCTest
@testable import VideoSave

final class PornhubResolverTests: XCTestCase {
    private let page = URL(string: "https://www.pornhub.com/view_video.php?viewkey=test")!

    func testOnlySupportedHTTPPagesMatch() {
        XCTAssertTrue(PornhubResolver.isPornhubPage(page))
        XCTAssertTrue(PornhubResolver.isPornhubPage(URL(string: "https://de.pornhub.com/view_video.php?viewkey=abc")!))
        for value in ["https://pornhub.com.evil.example/view_video.php?viewkey=x",
                      "https://notpornhub.com/view_video.php?viewkey=x",
                      "https://pornhub.com/view_video.php?viewkey=",
                      "https://pornhub.com/fake/view_video.php?viewkey=x",
                      "file://pornhub.com/view_video.php?viewkey=x"] {
            XCTAssertFalse(PornhubResolver.isPornhubPage(URL(string: value)!), value)
        }
    }

    func testDirectQualityItemsAreSortedWithoutBrowser() async throws {
        let session = makeSession(body: #"var qualityItems_1 = [{"url":"https://cdn.example/720.mp4","text":"720p"},{"url":"https://cdn.example/1080.mp4","text":"1080p"}];"#)
        defer { session.invalidateAndCancel() }
        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.defaultURL.absoluteString, "https://cdn.example/1080.mp4")
        XCTAssertEqual(result.variants.map(\.height), [1080, 720])
        XCTAssertEqual(result.requestHeaders["Referer"], page.absoluteString)
    }

    func testUnicodeBeforeFlashvarsAndNonMediaURLs() async throws {
        let session = makeSession(body: #"🚗 ä var flashvars_42 = {"mediaDefinitions":[{"videoUrl":"https://cdn.example/720.mp4","quality":720},{"videoUrl":"javascript:alert(1)"},{"videoUrl":"https://example.com/login"}]};"#)
        defer { session.invalidateAndCancel() }
        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.variants.count, 1)
        XCTAssertEqual(result.variants.first?.height, 720)
    }

    func testVisibleChallengeStillFailsClosedEvenWithMediaCandidate() async {
        let session = makeSession(body: #"<main>Verify you are human.</main><script>var qualityItems_1 = [{"url":"https://cdn.example/720.mp4","text":"720p"}];</script>"#)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await PornhubResolver.resolve(page, using: session)
            XCTFail("Visible CAPTCHA must stop resolution")
        } catch VideoSaveError.captchaRequired { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testChallengeWordsInsideScriptsDoNotCauseFalsePositive() async throws {
        let session = makeSession(body: #"<script>const message='Verify you are human'; const provider='h-captcha';</script>var qualityItems_1 = [{"url":"https://cdn.example/720.mp4","text":"720p"}];"#)
        defer { session.invalidateAndCancel() }
        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.defaultURL.absoluteString, "https://cdn.example/720.mp4")
    }

    func testChallengeWordingWithoutMediaStillFailsClosed() {
        XCTAssertThrowsError(try MediaAccessPolicy.validatePage("Verify you are human", finalURL: page)) { error in
            guard case VideoSaveError.captchaRequired = error else { return XCTFail("Unexpected error") }
        }
    }

    func testPassiveCaptchaAssetsDoNotTriggerFalsePositive() async throws {
        let session = makeSession(body: #"<script src="https://www.google.com/recaptcha/api.js"></script><script>const provider='h-captcha'; const cloudflare='cf-chl-widget';</script>var qualityItems_1 = [{"url":"https://cdn.example/1080.mp4","text":"1080p"}];"#)
        defer { session.invalidateAndCancel() }
        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.defaultURL.absoluteString, "https://cdn.example/1080.mp4")
    }

    func testChallengeURLStillFailsClosed() {
        XCTAssertThrowsError(try MediaAccessPolicy.validatePage(
            "Please wait",
            finalURL: URL(string: "https://www.pornhub.com/challenge?id=1")
        )) { error in
            guard case VideoSaveError.captchaRequired = error else { return XCTFail("Unexpected error") }
        }
    }

    func testBlockedHTTPStatusesAreRejected() {
        for status in [401, 403, 429, 451] {
            let response = HTTPURLResponse(url: page, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try MediaAccessPolicy.validateResponse(response)) { error in
                guard case VideoSaveError.accessBlocked = error else { return XCTFail("Unexpected error") }
            }
        }
    }

    func testLoginAndRegionGatesAreRejected() {
        XCTAssertThrowsError(try MediaAccessPolicy.validatePage("Log in to watch", finalURL: page))
        XCTAssertThrowsError(try MediaAccessPolicy.validatePage("Not available in your country", finalURL: page))
        XCTAssertThrowsError(try MediaAccessPolicy.validatePage("", finalURL: URL(string: "https://pornhub.com/login")))
        XCTAssertNoThrow(try MediaAccessPolicy.validatePage("Public video", finalURL: page))
    }

    func testEncryptedAndInvalidPlaylistsFailClosed() {
        for text in ["#EXTM3U\n#EXT-X-KEY:METHOD=AES-128", "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES", "<html>Access denied</html>"] {
            XCTAssertThrowsError(try MediaAccessPolicy.validatePlaylist(text))
        }
        XCTAssertNoThrow(try MediaAccessPolicy.validatePlaylist("#EXTM3U\n#EXTINF:5,\nsegment.ts"))
    }

    func test4KDimensionsPreserveAspectRatioAndOrientation() {
        XCTAssertEqual(VideoUpscaler.targetSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(VideoUpscaler.targetSize(for: CGSize(width: 1280, height: 720)), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(VideoUpscaler.targetSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 2160, height: 3840))
        XCTAssertEqual(VideoUpscaler.targetSize(for: CGSize(width: 1440, height: 1080)), CGSize(width: 2880, height: 2160))
    }

    func testSharedBrowserLinksAndText() {
        XCTAssertEqual(SharedLink.url(from: "https://www.pornhub.com/view_video.php?viewkey=test")?.host, "www.pornhub.com")
        XCTAssertEqual(SharedLink.url(from: "Mein Video https://cdn.example/video.mp4 ansehen")?.path, "/video.mp4")
        XCTAssertNil(SharedLink.url(from: "file:///private/video.mp4"))
        XCTAssertNil(SharedLink.url(from: "javascript:alert(1)"))
        XCTAssertNil(SharedLink.url(from: "Kein Link"))
    }

    func testShareDeepLinkRoundTrip() throws {
        let original = URL(string: "https://www.pornhub.com/view_video.php?viewkey=abc123&foo=bar")!
        let deepLink = try XCTUnwrap(SharedLink.appImportURL(for: original))
        XCTAssertEqual(deepLink.scheme, "videosave")
        XCTAssertEqual(SharedLink.importedURL(from: deepLink), original)
        XCTAssertNil(SharedLink.importedURL(from: URL(string: "videosave://import?url=javascript:alert(1)")!))
    }

    private func makeSession(body: String) -> URLSession {
        FixtureProtocol.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class FixtureProtocol: URLProtocol {
    static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
