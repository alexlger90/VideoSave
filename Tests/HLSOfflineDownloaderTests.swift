import XCTest
@testable import VideoSave

final class HLSOfflineDownloaderTests: XCTestCase {
    func testTransportStreamPlaylistIsParsedInOrder() throws {
        let base = URL(string: "https://cdn.example/path/video.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg-001.ts
        #EXTINF:6.0,
        seg-002.ts
        #EXT-X-ENDLIST
        """

        let result = try HLSMediaPlaylistParser.parse(text: playlist, baseURL: base)
        XCTAssertEqual(result.container, .mpegTransportStream)
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.parts.map(\.url.absoluteString), [
            "https://cdn.example/path/seg-001.ts",
            "https://cdn.example/path/seg-002.ts"
        ])
        XCTAssertEqual(result.parts.map(\.kind), [.media, .media])
    }

    func testFragmentedMP4PlaylistKeepsInitializationSegmentFirst() throws {
        let base = URL(string: "https://cdn.example/hls/720.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        part-001.m4s
        #EXTINF:4.0,
        part-002.m4s
        #EXT-X-ENDLIST
        """

        let result = try HLSMediaPlaylistParser.parse(text: playlist, baseURL: base)
        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.parts.first?.kind, .initialization)
        XCTAssertEqual(result.parts.first?.url.absoluteString, "https://cdn.example/hls/init.mp4")
        XCTAssertEqual(result.parts.dropFirst().map(\.kind), [.media, .media])
    }

    func testByteRangePlaylistFailsInsteadOfBuildingCorruptFile() {
        let base = URL(string: "https://cdn.example/hls/video.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-BYTERANGE:1000@0
        media.mp4
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(try HLSMediaPlaylistParser.parse(text: playlist, baseURL: base)) { error in
            guard case HLSOfflineError.unsupportedByteRange = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEncryptedPlaylistStillFailsClosed() {
        let base = URL(string: "https://cdn.example/hls/video.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4.0,
        seg.ts
        #EXT-X-ENDLIST
        """

        XCTAssertThrowsError(try HLSMediaPlaylistParser.parse(text: playlist, baseURL: base)) { error in
            guard case VideoSaveError.protectedStream = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
