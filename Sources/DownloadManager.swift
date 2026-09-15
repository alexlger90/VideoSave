import Foundation
import AVFoundation
import CoreML
import Photos
import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

struct HLSVariant: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let width: Int
    let height: Int
    let bandwidth: Int

    var label: String { height > 0 ? "\(height)p" : "Original" }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.mpeg4Movie, .quickTimeMovie]
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadNoPermission)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var outputURL: URL?
    @Published var isBusy = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var presentFileExporter = false

    var exportDocument: ExportDocument? {
        guard let outputURL else { return nil }
        return ExportDocument(url: outputURL)
    }

    private var downloadSession: URLSession!
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var sourceURL: URL?

    override init() {
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4

        downloadSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    func inspect(urlString: String) async throws -> [HLSVariant] {
        guard let url = URL(
            string: urlString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) else {
            throw VideoSaveError.invalidURL
        }

        if PornhubResolver.isPornhubPage(url) {
            status = "Pornhub-Video wird aufgelöst…"
            let resolved = try await PornhubResolver.resolve(url)
            return resolved.variants.sorted {
                if $0.height != $1.height {
                    return $0.height > $1.height
                }
                return $0.bandwidth > $1.bandwidth
            }
        }

        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              200..<400 ~= http.statusCode else {
            throw VideoSaveError.httpError
        }

        guard let text = String(
            data: data,
            encoding: .utf8
        ),
        text.contains("#EXTM3U") else {
            return []
        }

        let parsed = try HLSParser.parseMasterPlaylist(
            text: text,
            baseURL: url
        )

        return parsed.sorted {
            if $0.height != $1.height {
                return $0.height > $1.height
            }
            return $0.bandwidth > $1.bandwidth
        }
    }

    func download(
        urlString: String,
        quality: String,
        variants: [HLSVariant],
        format: String,
        upscale2x: Bool
    ) async {
        isBusy = true
        progress = 0
        outputURL = nil
        status = "Vorbereiten…"

        defer {
            isBusy = false
        }

        do {
            guard let original = URL(
                string: urlString.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ) else {
                throw VideoSaveError.invalidURL
            }

            var effectiveOriginal = original
            var effectiveVariants = variants
            var requestHeaders: [String: String] = [:]

            if PornhubResolver.isPornhubPage(original) {
                status = "Videoquelle wird aufgelöst…"
                let resolved = try await PornhubResolver.resolve(original)

                effectiveOriginal = resolved.defaultURL
                effectiveVariants = resolved.variants
                requestHeaders = resolved.requestHeaders
            }

            let selectedURL = selectURL(
                original: effectiveOriginal,
                quality: quality,
                variants: effectiveVariants
            )

            if selectedURL.pathExtension.lowercased() == "m3u8" {
                status = "HLS-Stream wird geprüft…"

                try await rejectProtectedHLSIfNeeded(
                    url: selectedURL,
                    headers: requestHeaders
                )

                let temp = try await exportHLS(
                    url: selectedURL,
                    format: format,
                    headers: requestHeaders
                )

                try await finishVideo(
                    inputURL: temp,
                    format: format,
                    upscale2x: upscale2x
                )
            } else {
                status = "Video wird heruntergeladen…"

                let temp = try await downloadDirect(
                    url: selectedURL,
                    headers: requestHeaders
                )

                try await finishVideo(
                    inputURL: temp,
                    format: format,
                    upscale2x: upscale2x
                )
            }

            status = "Fertig."
            progress = 1

        } catch {
            status = "Fehler"
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func selectURL(
        original: URL,
        quality: String,
        variants: [HLSVariant]
    ) -> URL {
        guard !variants.isEmpty,
              quality != "Original" else {
            return original
        }

        let target = Int(
            quality.replacingOccurrences(
                of: "p",
                with: ""
            )
        ) ?? Int.max

        if let exact = variants.first(
            where: { $0.height == target }
        ) {
            return exact.url
        }

        return variants.min {
            abs($0.height - target)
            < abs($1.height - target)
        }?.url ?? original
    }

    private func downloadDirect(
        url: URL,
        headers: [String: String]
    ) async throws -> URL {
        sourceURL = url

        return try await withCheckedThrowingContinuation {
            continuation in

            downloadContinuation = continuation

            var request = URLRequest(url: url)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }

            downloadSession
                .downloadTask(with: request)
                .resume()
        }
    }

    private func exportHLS(
        url: URL,
        format: String,
        headers: [String: String]
    ) async throws -> URL {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options[AVURLAssetHTTPHeaderFieldsKey] = headers
        }

        let asset = AVURLAsset(
            url: url,
            options: options.isEmpty ? nil : options
        )

        let tracks = try await asset.load(.tracks)

        guard tracks.contains(
            where: { $0.mediaType == .video }
        ) else {
            throw VideoSaveError.noVideoTrack
        }

        let preset = AVAssetExportPresetHighestQuality

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw VideoSaveError.exportUnavailable
        }

        let ext = format == "MOV" ? "mov" : "mp4"

        let destination =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "videosave_\(UUID().uuidString).\(ext)"
                )

        exporter.outputURL = destination
        exporter.outputFileType =
            format == "MOV" ? .mov : .mp4
        exporter.shouldOptimizeForNetworkUse = true

        status = "HLS wird in \(format) exportiert…"

        await exporter.export()

        guard exporter.status == .completed else {
            throw exporter.error
                ?? VideoSaveError.exportFailed
        }

        return destination
    }

    private func rejectProtectedHLSIfNeeded(
        url: URL,
        headers: [String: String]
    ) async throws {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) =
            try await URLSession.shared.data(
                for: request
            )

        guard
            (response as? HTTPURLResponse)?
                .statusCode ?? 200 < 400,
            let text = String(
                data: data,
                encoding: .utf8
            )
        else {
            return
        }

        if text.contains("#EXT-X-KEY")
            || text.contains("#EXT-X-SESSION-KEY") {
            throw VideoSaveError.protectedStream
        }
    }

    private func finishVideo(
        inputURL: URL,
        format: String,
        upscale2x: Bool
    ) async throws {
        defer {
            try? FileManager.default.removeItem(
                at: inputURL
            )
        }

        let asset = AVURLAsset(url: inputURL)

        let tracks = try await asset.load(.tracks)

        guard let videoTrack = tracks.first(
            where: { $0.mediaType == .video }
        ) else {
            throw VideoSaveError.noVideoTrack
        }

        let naturalSize =
            try await videoTrack.load(.naturalSize)

        let transform =
            try await videoTrack.load(
                .preferredTransform
            )

        let oriented = orientedSize(
            naturalSize,
            transform: transform
        )

        if upscale2x {
            guard oriented.width <= 1920.5,
                  oriented.height <= 1080.5 else {
                throw VideoSaveError.upscaleOnly1080p
            }

            status = "AI-Upscaling 2×…"

            outputURL =
                try await VideoUpscaler.upscaleVideo(
                    asset: asset,
                    format: format
                ) { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                    }
                }

        } else {
            status = "Video wird finalisiert…"

            outputURL =
                try await copyOrConvert(
                    asset: asset,
                    format: format
                )
        }
    }

    private func orientedSize(
        _ size: CGSize,
        transform: CGAffineTransform
    ) -> CGSize {
        let rect = CGRect(
            origin: .zero,
            size: size
        ).applying(transform)

        return CGSize(
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private func copyOrConvert(
        asset: AVAsset,
        format: String
    ) async throws -> URL {
        let ext = format == "MOV" ? "mov" : "mp4"

        let url =
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "VideoSave_\(Date().timeIntervalSince1970).\(ext)"
            )

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSaveError.exportUnavailable
        }

        exporter.outputURL = url
        exporter.outputFileType =
            format == "MOV" ? .mov : .mp4
        exporter.shouldOptimizeForNetworkUse = false

        await exporter.export()

        guard exporter.status == .completed else {
            throw exporter.error
                ?? VideoSaveError.exportFailed
        }

        return url
    }

    func saveToPhotos() async {
        guard let outputURL else {
            return
        }

        do {
            let status =
                await PHPhotoLibrary.requestAuthorization(
                    for: .addOnly
                )

            guard status == .authorized
                    || status == .limited else {
                throw VideoSaveError.photosDenied
            }

            try await PHPhotoLibrary.shared()
                .performChanges {
                    PHAssetChangeRequest
                        .creationRequestForAssetFromVideo(
                            atFileURL: outputURL
                        )
                }

            self.status = "In Fotos gespeichert."

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func handleExportResult(
        _ result: Result<URL, Error>
    ) {
        switch result {
        case .success:
            status = "In Dateien exportiert."

        case .failure(let error)
            where (error as NSError).code
                != NSUserCancelledError:

            errorMessage = error.localizedDescription
            showError = true

        case .failure:
            break
        }
    }
}

extension DownloadManager:
    URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "videosave_download_\(UUID().uuidString).\(downloadTask.originalRequest?.url?.pathExtension ?? "mp4")"
                )

        do {
            try FileManager.default.copyItem(
                at: location,
                to: destination
            )

            Task { @MainActor in
                self.downloadContinuation?
                    .resume(returning: destination)

                self.downloadContinuation = nil
            }

        } catch {
            Task { @MainActor in
                self.downloadContinuation?
                    .resume(throwing: error)

                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }

        Task { @MainActor in
            self.downloadContinuation?
                .resume(throwing: error)

            self.downloadContinuation = nil
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        let p =
            Double(totalBytesWritten)
            / Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            self.progress = p
        }
    }
}

enum VideoSaveError: LocalizedError {
    case invalidURL
    case httpError
    case unsupportedPage
    case mediaNotFound
    case accessBlocked
    case captchaRequired
    case noVideoTrack
    case exportUnavailable
    case exportFailed
    case protectedStream
    case upscaleOnly1080p
    case photosDenied

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Die Video-URL ist ungültig."

        case .httpError:
            return "Der Server konnte die Videoquelle nicht öffnen."

        case .unsupportedPage:
            return "Diese Seite wird nicht als unterstützte Videoquelle erkannt."

        case .mediaNotFound:
            return "Auf der öffentlich zugänglichen Seite wurde keine direkt verfügbare Videoquelle gefunden."

        case .accessBlocked:
            return "Der Server hat den Zugriff auf die Seite blockiert (z. B. HTTP 403/429). VideoSave umgeht keine Zugriffssperren."

        case .captchaRequired:
            return "Die Seite verlangt eine CAPTCHA-/Mensch-Überprüfung. VideoSave umgeht diese Überprüfung nicht."

        case .noVideoTrack:
            return "Die Quelle enthält keine Videospur."

        case .exportUnavailable:
            return "Der iPhone-Videoexport ist für diese Quelle nicht verfügbar."

        case .exportFailed:
            return "Der Videoexport ist fehlgeschlagen."

        case .protectedStream:
            return "Dieser HLS-Stream ist technisch geschützt. VideoSave umgeht keinen DRM-/Schutzmechanismus."

        case .upscaleOnly1080p:
            return "Das 2×-AI-Upscaling ist in dieser Version für Quellen bis 1080p vorgesehen."

        case .photosDenied:
            return "Der Zugriff auf Fotos wurde nicht erlaubt."
        }
    }
}

enum HLSParser {
    static func parseMasterPlaylist(
        text: String,
        baseURL: URL
    ) throws -> [HLSVariant] {

        let lines =
            text.components(
                separatedBy: .newlines
            )

        var variants: [HLSVariant] = []

        var pending:
            (
                width: Int,
                height: Int,
                bandwidth: Int
            )?

        for raw in lines {
            let line =
                raw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            if line.hasPrefix(
                "#EXT-X-STREAM-INF:"
            ) {

                let attrs =
                    parseAttributes(
                        String(
                            line.dropFirst(
                                "#EXT-X-STREAM-INF:"
                                    .count
                            )
                        )
                    )

                let res =
                    attrs["RESOLUTION"]?
                        .split(separator: "x")
                        .compactMap {
                            Int($0)
                        }
                    ?? []

                pending = (
                    res.count == 2 ? res[0] : 0,
                    res.count == 2 ? res[1] : 0,
                    Int(
                        attrs["BANDWIDTH"] ?? "0"
                    ) ?? 0
                )

            } else if
                !line.isEmpty,
                !line.hasPrefix("#"),
                let p = pending,
                let url = URL(
                    string: line,
                    relativeTo: baseURL
                )?.absoluteURL
            {

                variants.append(
                    HLSVariant(
                        url: url,
                        width: p.width,
                        height: p.height,
                        bandwidth: p.bandwidth
                    )
                )

                pending = nil
            }
        }

        return variants
    }

    private static func parseAttributes(
        _ text: String
    ) -> [String: String] {

        var result: [String: String] = [:]
        var current = ""
        var quoted = false
        var parts: [String] = []

        for ch in text {
            if ch == "\"" {
                quoted.toggle()
            }

            if ch == "," && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        for part in parts {
            let kv =
                part.split(
                    separator: "=",
                    maxSplits: 1
                )
                .map(String.init)

            if kv.count == 2 {
                result[kv[0]] =
                    kv[1].trimmingCharacters(
                        in: CharacterSet(
                            charactersIn: "\""
                        )
                    )
            }
        }

        return result
    }
}

@MainActor
private enum VideoUpscaler {

    static func upscaleVideo(
        asset: AVAsset,
        format: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {

        guard let modelURL =
            Bundle.main.url(
                forResource:
                    "RealESRGAN_x2plus_522_fp16",
                withExtension: "mlmodelc"
            )
        else {
            throw VideoSaveError.exportUnavailable
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model =
            try MLModel(
                contentsOf: modelURL,
                configuration: config
            )

        let spec = model.modelDescription

        guard let inputFeature =
            spec.inputDescriptionsByName["input"],
            let inputConstraint =
                inputFeature.multiArrayConstraint
        else {
            throw VideoSaveError.exportUnavailable
        }

        let outputName =
            spec.outputDescriptionsByName.keys.first
            ?? ""

        guard !outputName.isEmpty else {
            throw VideoSaveError.exportUnavailable
        }

        let outputConstraint =
            spec.outputDescriptionsByName[
                outputName
            ]?.multiArrayConstraint

        guard outputConstraint != nil else {
            throw VideoSaveError.exportUnavailable
        }

        let size =
            inputConstraint.shape.last?
                .intValue
            ?? 522

        let tileSize = 512
        let pad = size - tileSize

        let reader =
            try AVAssetReader(asset: asset)

        guard let videoTrack =
            try await asset.load(.tracks)
                .first(
                    where: {
                        $0.mediaType == .video
                    }
                )
        else {
            throw VideoSaveError.noVideoTrack
        }

        let readerOutput =
            AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA
                ]
            )

        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let duration =
            try await asset.load(.duration)

        let durationSeconds =
            max(duration.seconds, 0.001)

        let natural =
            try await videoTrack.load(
                .naturalSize
            )

        let transform =
            try await videoTrack.load(
                .preferredTransform
            )

        let oriented =
            orientedSize(
                natural,
                transform: transform
            )

        let outputSize =
            CGSize(
                width: oriented.width * 2,
                height: oriented.height * 2
            )

        let outputURL =
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "VideoSave_4K_\(Date().timeIntervalSince1970).\(format == "MOV" ? "mov" : "mp4")"
            )

        guard let writer =
            try? AVAssetWriter(
                outputURL: outputURL,
                fileType:
                    format == "MOV"
                    ? .mov
                    : .mp4
            )
        else {
            throw VideoSaveError.exportUnavailable
        }

        let settings: [String: Any] = [
            AVVideoCodecKey:
                AVVideoCodecType.h264,

            AVVideoWidthKey:
                Int(outputSize.width),

            AVVideoHeightKey:
                Int(outputSize.height),

            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:
                    35_000_000
            ]
        ]

        let writerInput =
            AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings
            )

        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = .identity

        writer.add(writerInput)

        if let audioTrack =
            try await asset.load(.tracks)
                .first(
                    where: {
                        $0.mediaType == .audio
                    }
                )
        {
            let audioOutput =
                AVAssetReaderTrackOutput(
                    track: audioTrack,
                    outputSettings: nil
                )

            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
            }

            let audioInput =
                AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil
                )

            audioInput.expectsMediaDataInRealTime = false

            if writer.canAdd(audioInput) {
                writer.add(audioInput)
            }

            try reader.startReading()

            writer.startWriting()
            writer.startSession(
                atSourceTime: .zero
            )

            while writer.status == .writing {
                if let sample =
                    audioOutput.copyNextSampleBuffer()
                {
                    if audioInput.isReadyForMoreMediaData {
                        audioInput.append(sample)
                    }
                } else {
                    audioInput.markAsFinished()
                    break
                }
            }

            reader.cancelReading()

            return try await upscaleVideoWithoutAudio(
                asset: asset,
                model: model,
                modelSize: size,
                tileSize: tileSize,
                pad: pad,
                outputURL: outputURL,
                writer: writer,
                writerInput: writerInput,
                durationSeconds: durationSeconds,
                oriented: oriented,
                outputSize: outputSize,
                progress: progress
            )
        }

        writer.startWriting()

        writer.startSession(
            atSourceTime: .zero
        )

        guard reader.startReading() else {
            throw reader.error
                ?? VideoSaveError.exportFailed
        }

        while let sample =
            readerOutput.copyNextSampleBuffer()
        {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(
                    nanoseconds: 1_000_000
                )
            }

            let pts =
                CMSampleBufferGetPresentationTimeStamp(
                    sample
                ).seconds

            let upscaled =
                try upscaleSample(
                    sample,
                    model: model,
                    modelSize: size,
                    tileSize: tileSize,
                    pad: pad,
                    outputSize: outputSize
                )

            writerInput.append(upscaled)

            progress(
                min(
                    max(
                        pts / durationSeconds,
                        0
                    ),
                    1
                )
            )
        }

        writerInput.markAsFinished()

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error
                ?? VideoSaveError.exportFailed
        }

        return outputURL
    }

    private static func upscaleVideoWithoutAudio(
        asset: AVAsset,
        model: MLModel,
        modelSize: Int,
        tileSize: Int,
        pad: Int,
        outputURL: URL,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        durationSeconds: Double,
        oriented: CGSize,
        outputSize: CGSize,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {

        writerInput.markAsFinished()
        writer.cancelWriting()

        try? FileManager.default.removeItem(
            at: outputURL
        )

        let reader =
            try AVAssetReader(asset: asset)

        guard let track =
            try await asset.load(.tracks)
                .first(
                    where: {
                        $0.mediaType == .video
                    }
                )
        else {
            throw VideoSaveError.noVideoTrack
        }

        let output =
            AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA
                ]
            )

        reader.add(output)

        let newWriter =
            try AVAssetWriter(
                outputURL: outputURL,
                fileType:
                    outputURL.pathExtension == "mov"
                    ? .mov
                    : .mp4
            )

        let settings: [String: Any] = [
            AVVideoCodecKey:
                AVVideoCodecType.h264,

            AVVideoWidthKey:
                Int(outputSize.width),

            AVVideoHeightKey:
                Int(outputSize.height),

            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:
                    35_000_000
            ]
        ]

        let input =
            AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings
            )

        newWriter.add(input)

        guard reader.startReading() else {
            throw reader.error
                ?? VideoSaveError.exportFailed
        }

        newWriter.startWriting()

        newWriter.startSession(
            atSourceTime: .zero
        )

        while let sample =
            output.copyNextSampleBuffer()
        {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(
                    nanoseconds: 1_000_000
                )
            }

            let pts =
                CMSampleBufferGetPresentationTimeStamp(
                    sample
                ).seconds

            input.append(
                try upscaleSample(
                    sample,
                    model: model,
                    modelSize: modelSize,
                    tileSize: tileSize,
                    pad: pad,
                    outputSize: outputSize
                )
            )

            progress(
                min(
                    max(
                        pts / durationSeconds,
                        0
                    ),
                    1
                )
            )
        }

        input.markAsFinished()

        await newWriter.finishWriting()

        guard newWriter.status == .completed else {
            throw newWriter.error
                ?? VideoSaveError.exportFailed
        }

        return outputURL
    }

    private static func upscaleSample(
        _ sample: CMSampleBuffer,
        model: MLModel,
        modelSize: Int,
        tileSize: Int,
        pad: Int,
        outputSize: CGSize
    ) throws -> CMSampleBuffer {

        guard let pb =
            CMSampleBufferGetImageBuffer(sample)
        else {
            throw VideoSaveError.exportFailed
        }

        let ci = CIImage(
            cvPixelBuffer: pb
        )

        let context =
            CIContext(options: nil)

        guard let cg =
            context.createCGImage(
                ci,
                from: ci.extent
            )
        else {
            throw VideoSaveError.exportFailed
        }

        let inputW = cg.width
        let inputH = cg.height

        var outputPixels =
            [UInt8](
                repeating: 0,
                count:
                    Int(outputSize.width)
                    * Int(outputSize.height)
                    * 4
            )

        var weight =
            [Float](
                repeating: 0,
                count:
                    Int(outputSize.width)
                    * Int(outputSize.height)
            )

        let colorSpace =
            CGColorSpaceCreateDeviceRGB()

        let srcData =
            UnsafeMutablePointer<UInt8>
                .allocate(
                    capacity:
                        inputW
                        * inputH
                        * 4
                )

        defer {
            srcData.deallocate()
        }

        guard let ctx =
            CGContext(
                data: srcData,
                width: inputW,
                height: inputH,
                bitsPerComponent: 8,
                bytesPerRow: inputW * 4,
                space: colorSpace,
                bitmapInfo:
                    CGImageAlphaInfo
                        .premultipliedLast
                        .rawValue
            )
        else {
            throw VideoSaveError.exportFailed
        }

        ctx.draw(
            cg,
            in: CGRect(
                x: 0,
                y: 0,
                width: inputW,
                height: inputH
            )
        )

        for y in stride(
            from: 0,
            to: inputH,
            by: tileSize - 32
        ) {
            for x in stride(
                from: 0,
                to: inputW,
                by: tileSize - 32
            ) {

                let tw =
                    min(
                        tileSize,
                        inputW - x
                    )

                let th =
                    min(
                        tileSize,
                        inputH - y
                    )

                var array =
                    try MLMultiArray(
                        shape: [
                            1,
                            3,
                            NSNumber(
                                value: modelSize
                            ),
                            NSNumber(
                                value: modelSize
                            )
                        ],
                        dataType: .float32
                    )

                let plane =
                    modelSize * modelSize

                for yy in 0..<modelSize {
                    let sy =
                        min(
                            inputH - 1,
                            max(
                                0,
                                y + yy - pad
                            )
                        )

                    for xx in 0..<modelSize {
                        let sx =
                            min(
                                inputW - 1,
                                max(
                                    0,
                                    x + xx - pad
                                )
                            )

                        let idx =
                            (sy * inputW + sx) * 4

                        array[
                            yy * modelSize + xx
                        ] =
                            NSNumber(
                                value:
                                    Float(
                                        srcData[idx]
                                    ) / 255
                            )

                        array[
                            plane
                            + yy * modelSize
                            + xx
                        ] =
                            NSNumber(
                                value:
                                    Float(
                                        srcData[idx + 1]
                                    ) / 255
                            )

                        array[
                            2 * plane
                            + yy * modelSize
                            + xx
                        ] =
                            NSNumber(
                                value:
                                    Float(
                                        srcData[idx + 2]
                                    ) / 255
                            )
                    }
                }

                let result =
                    try model.prediction(
                        from:
                            MLDictionaryFeatureProvider(
                                dictionary: [
                                    "input":
                                        MLFeatureValue(
                                            multiArray: array
                                        )
                                ]
                            )
                    )

                guard
                    let outputName =
                        model
                            .modelDescription
                            .outputDescriptionsByName
                            .keys
                            .first,

                    let featureValue =
                        result.featureValue(
                            for: outputName
                        ),

                    let out =
                        featureValue.multiArrayValue
                else {
                    throw VideoSaveError.exportFailed
                }

                let outW =
                    modelSize * 2

                let outH =
                    modelSize * 2

                for yy in 0..<(th * 2) {
                    for xx in 0..<(tw * 2) {

                        let oy =
                            (y * 2) + yy

                        let ox =
                            (x * 2) + xx

                        if oy >= Int(outputSize.height)
                            || ox >= Int(outputSize.width) {
                            continue
                        }

                        let srcY =
                            yy + pad * 2

                        let srcX =
                            xx + pad * 2

                        let r =
                            max(
                                0,
                                min(
                                    outH - 1,
                                    srcY
                                )
                            )

                        let c =
                            max(
                                0,
                                min(
                                    outW - 1,
                                    srcX
                                )
                            )

                        let base =
                            r * outW + c

                        let rr =
                            UInt8(
                                max(
                                    0,
                                    min(
                                        255,
                                        out[base]
                                            .floatValue
                                            * 255
                                    )
                                )
                            )

                        let gg =
                            UInt8(
                                max(
                                    0,
                                    min(
                                        255,
                                        out[
                                            plane + base
                                        ]
                                        .floatValue
                                        * 255
                                    )
                                )
                            )

                        let bb =
                            UInt8(
                                max(
                                    0,
                                    min(
                                        255,
                                        out[
                                            2 * plane + base
                                        ]
                                        .floatValue
                                        * 255
                                    )
                                )
                            )

                        let di =
                            (
                                oy
                                * Int(outputSize.width)
                                + ox
                            ) * 4

                        outputPixels[di] = rr
                        outputPixels[di + 1] = gg
                        outputPixels[di + 2] = bb
                        outputPixels[di + 3] = 255

                        weight[
                            oy
                            * Int(outputSize.width)
                            + ox
                        ] = 1
                    }
                }
            }
        }

        let outPB =
            try makePixelBuffer(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )

        CVPixelBufferLockBaseAddress(
            outPB,
            []
        )

        defer {
            CVPixelBufferUnlockBaseAddress(
                outPB,
                []
            )
        }

        memcpy(
            CVPixelBufferGetBaseAddress(outPB),
            outputPixels,
            outputPixels.count
        )

        var timing =
            CMSampleTimingInfo(
                duration:
                    CMSampleBufferGetDuration(
                        sample
                    ),
                presentationTimeStamp:
                    CMSampleBufferGetPresentationTimeStamp(
                        sample
                    ),
                decodeTimeStamp:
                    CMSampleBufferGetDecodeTimeStamp(
                        sample
                    )
            )

        var format:
            CMFormatDescription?

        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outPB,
            formatDescriptionOut: &format
        )

        var outSample:
            CMSampleBuffer?

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outPB,
            formatDescription: format!,
            sampleTiming: &timing,
            sampleBufferOut: &outSample
        )

        return outSample!
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {

        var pb: CVPixelBuffer?

        let attrs:
            [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey:
                    true,

                kCVPixelBufferCGBitmapContextCompatibilityKey:
                    true
            ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )

        guard let pb else {
            throw VideoSaveError.exportFailed
        }

        return pb
    }

    private static func orientedSize(
        _ size: CGSize,
        transform: CGAffineTransform
    ) -> CGSize {

        let rect =
            CGRect(
                origin: .zero,
                size: size
            )
            .applying(transform)

        return CGSize(
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }
}
