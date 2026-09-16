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
        ), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
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

        try MediaAccessPolicy.validateResponse(response)
        if (response as? HTTPURLResponse)?.mimeType == "text/html" {
            throw VideoSaveError.unsupportedPage
        }

        guard let text = String(
            data: data,
            encoding: .utf8
        ),
        text.contains("#EXTM3U") else {
            return []
        }

        try MediaAccessPolicy.validatePlaylist(text)
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
        guard !isBusy else { return }
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
            ), ["http", "https"].contains(original.scheme?.lowercased() ?? ""), original.host != nil else {
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
        headers: [String: String],
        depth: Int = 0
    ) async throws {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) =
            try await URLSession.shared.data(
                for: request
            )

        try MediaAccessPolicy.validateResponse(response)
        guard let text = String(data: data, encoding: .utf8) else { throw VideoSaveError.mediaNotFound }
        try MediaAccessPolicy.validatePlaylist(text)
        let baseURL = response.url ?? url
        let children = try HLSParser.parseMasterPlaylist(text: text, baseURL: baseURL).map(\.url)
        // Also inspect alternate audio/subtitle playlists before AVFoundation can load them.
        let regex = try NSRegularExpression(pattern: #"(?m)^#EXT-X-MEDIA:.*?URI="([^"]+)""#)
        let alternates = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return URL(string: String(text[range]), relativeTo: baseURL)?.absoluteURL
        }
        for child in Set(children + alternates) {
            guard depth < 4, ["http", "https"].contains(child.scheme?.lowercased() ?? "") else {
                throw VideoSaveError.protectedStream
            }
            try await rejectProtectedHLSIfNeeded(url: child, headers: headers, depth: depth + 1)
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
            guard max(oriented.width, oriented.height) <= 1920.5,
                  min(oriented.width, oriented.height) <= 1080.5 else {
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
            guard let response = downloadTask.response else { throw VideoSaveError.httpError }
            try MediaAccessPolicy.validateResponse(response)
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
