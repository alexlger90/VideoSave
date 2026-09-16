import XCTest
@testable import VideoSave

final class GenericTubeResolverTests: XCTestCase {
    func testRequestedCatalogContainsAllSources() {
        XCTAssertEqual(SupportedSourceCatalog.names.count, 113)
        for expected in [
            "XVideos", "SpankBang", "xHamster", "Eporner",
            "XNXX", "Porn4K.to", "NoodleMagazine", "XKeezMovies"
        ] {
            XCTAssertTrue(SupportedSourceCatalog.names.contains(expected), expected)
        }
    }

    func testCatalogRoutingRecognizesRepresentativeDomains() {
        let supported = [
            "https://www.xvideos.com/video123/test",
            "https://de.xhamster.com/videos/test",
            "https://spankbang.com/abc/video/test",
            "https://porn4k.to/video/test",
            "https://sexpebune.ro/video/test",
            "https://xxx.gr/video/test",
            "https://noodlemagazine.com/watch/test"
        ]

        for value in supported {
            XCTAssertTrue(
                PornhubResolver.isPornhubPage(URL(string: value)!),
                value
            )
        }

        XCTAssertFalse(
            PornhubResolver.isPornhubPage(
                URL(string: "https://xvideos.com.evil.example/video/test")!
            )
        )
        XCTAssertFalse(
            PornhubResolver.isPornhubPage(
                URL(string: "https://www.xvideos.com/media/test.mp4")!
            )
        )
    }

    func testPornhubStillRequiresARealVideoPage() {
        XCTAssertTrue(
            PornhubResolver.isPornhubPage(
                URL(string: "https://www.pornhub.com/view_video.php?viewkey=abc")!
            )
        )
        XCTAssertFalse(
            PornhubResolver.isPornhubPage(
                URL(string: "https://www.pornhub.com/")!
            )
        )
        XCTAssertFalse(
            PornhubResolver.isPornhubPage(
                URL(string: "https://www.pornhub.com/view_video.php?viewkey=")!
            )
        )
    }

    func testGenericResolverExtractsMultipleDirectFiles() async throws {
        let page = URL(string: "https://www.xvideos.com/video123/test")!
        let html = #"""
        <html>
          <video>
            <source src="https://cdn.example/video-1080.mp4" type="video/mp4">
          </video>
          <script>
            const player = {"file":"https:\/\/cdn.example\/video-720.mp4"};
          </script>
        </html>
        """#

        let session = makeSession(routes: [
            page.absoluteString: GenericFixture(
                body: html,
                contentType: "text/html"
            )
        ])
        defer { session.invalidateAndCancel() }

        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.map(\.kind), [.direct, .direct])
        XCTAssertEqual(result.candidates.map(\.quality), [1080, 720])
        XCTAssertEqual(
            result.defaultURL.absoluteString,
            "https://cdn.example/video-1080.mp4"
        )
    }

    func testGenericResolverExpandsPublicHLSMaster() async throws {
        let page = URL(string: "https://spankbang.com/abc/video/test")!
        let html = #"""
        <script>
          const player = {"hls":"https://cdn.example/master.m3u8"};
        </script>
        """#
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn.example/hls/1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://cdn.example/hls/720.m3u8
        """

        let session = makeSession(routes: [
            page.absoluteString: GenericFixture(
                body: html,
                contentType: "text/html"
            ),
            "https://cdn.example/master.m3u8": GenericFixture(
                body: master,
                contentType: "application/vnd.apple.mpegurl"
            )
        ])
        defer { session.invalidateAndCancel() }

        let result = try await PornhubResolver.resolve(page, using: session)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.map(\.kind), [.hls, .hls])
        XCTAssertEqual(result.candidates.map(\.quality), [1080, 720])
    }

    func testGenericResolverFailsClosedOnVisibleCaptcha() async {
        let page = URL(string: "https://www.xvideos.com/video123/test")!
        let html = #"""
        <main>Verify you are human.</main>
        <video src="https://cdn.example/video-720.mp4"></video>
        """#

        let session = makeSession(routes: [
            page.absoluteString: GenericFixture(
                body: html,
                contentType: "text/html"
            )
        ])
        defer { session.invalidateAndCancel() }

        do {
            _ = try await PornhubResolver.resolve(page, using: session)
            XCTFail("Visible CAPTCHA must stop generic resolution")
        } catch VideoSaveError.captchaRequired {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSession(
        routes: [String: GenericFixture]
    ) -> URLSession {
        GenericFixtureProtocol.routes = routes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenericFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct GenericFixture {
    let body: String
    let contentType: String
    var statusCode: Int = 200
}

private final class GenericFixtureProtocol: URLProtocol {
    static var routes: [String: GenericFixture] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.routes[url.absoluteString] else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data("Not found".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": fixture.contentType]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }
}
