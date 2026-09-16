import Foundation
import AVFoundation
import CoreML
import CoreImage

/// AI inference runs on decoded frames; a final composition restores audio and orientation.
enum VideoUpscaler {
    static func upscaleVideo(asset: AVAsset, format: String, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let modelURL = Bundle.main.url(forResource: "RealESRGAN_x2plus_522_fp16", withExtension: "mlmodelc") else {
            throw VideoSaveError.exportUnavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard let shape = model.modelDescription.inputDescriptionsByName["input"]?.multiArrayConstraint?.shape,
              shape.count == 4, shape[1].intValue == 3,
              shape[2].intValue == shape[3].intValue,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first else {
            throw VideoSaveError.exportUnavailable
        }
        let modelSize = shape[3].intValue
        guard modelSize > 32 else { throw VideoSaveError.exportUnavailable }
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else { throw VideoSaveError.noVideoTrack }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        let width = Int(naturalSize.width) * 2
        let height = Int(naturalSize.height) * 2
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ai_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temp) }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoSaveError.exportUnavailable }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 35_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw VideoSaveError.exportUnavailable }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else { throw VideoSaveError.exportFailed }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? VideoSaveError.exportFailed }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let buffer = try autoreleasepool {
                    try upscaleFrame(sample, model: model, modelSize: modelSize, outputName: outputName, context: context)
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? VideoSaveError.exportFailed }
                progress(min(max(time.seconds / max(duration.seconds, 0.001), 0), 1) * 0.9)
            }
            guard reader.status == .completed else { throw reader.error ?? VideoSaveError.exportFailed }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? VideoSaveError.exportFailed }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        return try await finish4K(videoURL: temp, original: asset, transform: transform, fps: fps, format: format)
    }

    static func targetSize(for size: CGSize) -> CGSize {
        let scale = min(3840 / max(size.width, size.height), 2160 / min(size.width, size.height))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2), height: max(2, floor(size.height * scale / 2) * 2))
    }

    private static func finish4K(videoURL: URL, original: AVAsset, transform: CGAffineTransform, fps: Float, format: String) async throws -> URL {
        let upscaled = AVURLAsset(url: videoURL)
        guard let source = try await upscaled.load(.tracks).first(where: { $0.mediaType == .video }) else { throw VideoSaveError.noVideoTrack }
        let duration = try await upscaled.load(.duration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoSaveError.exportUnavailable }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        for audioSource in try await original.load(.tracks).filter({ $0.mediaType == .audio }) {
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoSaveError.exportUnavailable }
            let audioRange = try await audioSource.load(.timeRange)
            let range = CMTimeRangeGetIntersection(audioRange, CMTimeRange(start: .zero, duration: duration))
            if range.duration.seconds > 0 { try audio.insertTimeRange(range, of: audioSource, at: range.start) }
        }
        let natural = try await source.load(.naturalSize)
        // Translation is normalized after rotation; dimensions are already doubled.
        let rotation = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        let bounds = CGRect(origin: .zero, size: natural).applying(rotation)
        let oriented = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        let target = targetSize(for: oriented)
        let scale = target.width / oriented.width
        let finalTransform = rotation.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(finalTransform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = target
        videoComposition.frameDuration = CMTime(value: 1000, timescale: Int32(max(1, min(fps, 240)) * 1000))
        videoComposition.instructions = [instruction]
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw VideoSaveError.exportUnavailable }
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoSave_4K_\(UUID().uuidString).\(format == "MOV" ? "mov" : "mp4")")
        exporter.outputURL = destination
        exporter.outputFileType = format == "MOV" ? .mov : .mp4
        exporter.videoComposition = videoComposition
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw exporter.error ?? VideoSaveError.exportFailed
        }
        return destination
    }

    private static func upscaleFrame(_ sample: CMSampleBuffer, model: MLModel, modelSize: Int, outputName: String, context: CIContext) throws -> CVPixelBuffer {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { throw VideoSaveError.exportFailed }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cvPixelBuffer: source), toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        }
        let pad = 10
        let tileSize = modelSize - 2 * pad
        let outWidth = width * 2, outHeight = height * 2
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in stride(from: 0, to: height, by: tileSize) {
            for x in stride(from: 0, to: width, by: tileSize) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let array = try MLMultiArray(shape: [1, 3, NSNumber(value: modelSize), NSNumber(value: modelSize)], dataType: .float32)
                    let input = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
                    let strides = array.strides.map(\.intValue)
                    for yy in 0..<modelSize {
                        let sy = min(height - 1, max(0, y + yy - pad))
                        for xx in 0..<modelSize {
                            let sx = min(width - 1, max(0, x + xx - pad))
                            for channel in 0..<3 {
                                input[channel * strides[1] + yy * strides[2] + xx * strides[3]] = Float(rgba[(sy * width + sx) * 4 + channel]) / 255
                            }
                        }
                    }
                    let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: array)]))
                    guard let output = prediction.featureValue(for: outputName)?.multiArrayValue,
                          output.shape.count == 4, output.shape[1].intValue == 3,
                          output.shape[2].intValue == modelSize * 2, output.shape[3].intValue == modelSize * 2 else { throw VideoSaveError.exportFailed }
                    let os = output.strides.map(\.intValue)
                    for yy in 0..<(min(tileSize, height - y) * 2) {
                        for xx in 0..<(min(tileSize, width - x) * 2) {
                            let dest = ((y * 2 + yy) * outWidth + x * 2 + xx) * 4
                            for channel in 0..<3 {
                                let value = output[channel * os[1] + (yy + pad * 2) * os[2] + (xx + pad * 2) * os[3]].floatValue
                                pixels[dest + channel] = UInt8(max(0, min(255, value.isFinite ? value * 255 : 0)))
                            }
                            pixels[dest + 3] = 255
                        }
                    }
                }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: outWidth * 4,
                            size: CGSize(width: outWidth, height: outHeight), format: .RGBA8, colorSpace: colorSpace)
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, outWidth, outHeight, kCVPixelFormatType_32BGRA, attributes, &result) == kCVReturnSuccess,
              let result else { throw VideoSaveError.exportFailed }
        context.render(image, to: result, bounds: image.extent, colorSpace: colorSpace)
        return result
    }
}
