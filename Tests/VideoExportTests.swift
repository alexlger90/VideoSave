import XCTest
import AVFoundation
@testable import VideoSave

final class VideoExportTests: XCTestCase {
    func test4KExportKeepsAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoURL = folder.appendingPathComponent("source.mov")
        try await makeVideo(at: videoURL)
        let audioURL = folder.appendingPathComponent("tone.wav")
        try makeTone().write(to: audioURL)
        let original = AVMutableComposition()
        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.load(.tracks)
        let audio = try XCTUnwrap(audioTracks.first)
        let compositionTrack = try XCTUnwrap(original.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)), of: audio, at: .zero)
        let result = try await VideoUpscaler.finish4K(videoURL: videoURL, original: original, transform: .identity, fps: 4, format: "MP4")
        defer { try? FileManager.default.removeItem(at: result) }
        let asset = AVURLAsset(url: result)
        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 1)
        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 3840, height: 2160))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 0.1)
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 18])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? VideoSaveError.exportFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 2))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func makeTone() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) {
            data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
        }
        func integer(_ value: UInt32) { word(UInt16(value & 65535)); word(UInt16(value >> 16)) }
        let count = 24_000
        text("RIFF"); integer(UInt32(36 + count * 2)); text("WAVEfmt "); integer(16)
        word(1); word(1); integer(48_000); integer(96_000); word(2); word(16)
        text("data"); integer(UInt32(count * 2))
        for index in 0..<count {
            let sample = Int16(sin(Double(index) * 2 * .pi * 440 / 48_000) * 8_000)
            word(UInt16(bitPattern: sample))
        }
        return data
    }
}
