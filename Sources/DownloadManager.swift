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

enum MediaFallbackPolicy {
    static func shouldTryNext(after error: Error) -> Bool {
        guard let error = error as? VideoSaveError else {
            // AVFoundation/network errors for one public candidate are candidate-specific.
            return true
        }

        switch error {
        case .accessBlocked, .captchaRequired, .protectedStream,
             .invalidURL, .upscaleOnly1080p, .photosDenied:
            return false
        case .httpError, .unsupportedPage, .mediaNotFound,
             .noVideoTrack, .exportUnavailable, .exportFailed:
            return true
        }
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
    @Published var diagnosticLog: [String] = []

    var exportDocument: ExportDocument? {
        guard let outputURL else { return nil }
        return ExportDocument(url: outputURL)
    }

    var diagnosticText: String {
        diagnosticLog.joined(separator: "\n")
    }

    private var downloadSession: URLSession!
    private var mediaSession: URLSession!
    private var downloadContinuation: CheckedContinuation<URL, Error>?

    override init() {
        super.init()

        let downloadConfig = URLSessionConfiguration.ephemeral
        downloadConfig.timeoutIntervalForRequest = 60
        downloadConfig.timeoutIntervalForResource = 60 * 60 * 4
        downloadConfig.httpShouldSetCookies = true
        downloadConfig.httpCookieAcceptPolicy = .always
        downloadConfig.httpCookieStorage = HTTPCookieStorage.shared
        downloadConfig.urlCache = nil

        downloadSession = URLSession(
            configuration: downloadConfig,
            delegate: self,
            delegateQueue: nil
        )

        let mediaConfig = URLSessionConfiguration.ephemeral
        mediaConfig.timeoutIntervalForRequest = 60
        mediaConfig.timeoutIntervalForResource = 180
        mediaConfig.httpShouldSetCookies = true
        mediaConfig.httpCookieAcceptPolicy = .always
        mediaConfig.httpCookieStorage = HTTPCookieStorage.shared
        mediaConfig.urlCache = nil
        mediaSession = URLSession(configuration: mediaConfig)
    }

    func inspect(urlString: String) async throws -> [HLSVariant] {
        guard let url = URL(
            string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        ), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw VideoSaveError.invalidURL
        }

        if PornhubResolver.isPornhubPage(url) {
            status = "Pornhub-Video wird aufgelöst…"
            let resolved = try await PornhubResolver.resolve(url)
            diagnosticLog = diagnosticsForResolution(resolved)
            return resolved.variants.sorted {
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.bandwidth > $1.bandwidth
            }
        }

        diagnosticLog = []
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await mediaSession.data(for: request)
        try MediaAccessPolicy.validateResponse(response)

        if (response as? HTTPURLResponse)?.mimeType == "text/html" {
            throw VideoSaveError.unsupportedPage
        }

        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            return []
        }

        try MediaAccessPolicy.validatePlaylist(text)
        return try HLSParser.parseMasterPlaylist(text: text, baseURL: response.url ?? url).sorted {
            if $0.height != $1.height { return $0.height > $1.height }
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
        errorMessage = ""

        defer { isBusy = false }

        do {
            guard let original = URL(
                string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            ), ["http", "https"].contains(original.scheme?.lowercased() ?? ""), original.host != nil else {
                throw VideoSaveError.invalidURL
            }

            if PornhubResolver.isPornhubPage(original) {
                status = "Videoquellen werden aufgelöst…"
                let resolved = try await PornhubResolver.resolve(original)
                diagnosticLog = diagnosticsForResolution(resolved)

                try await downloadPornhub(
                    resolution: resolved,
                    quality: quality,
                    format: format,
                    upscale2x: upscale2x
                )
            } else {
                diagnosticLog = []
                let selectedURL = selectURL(original: original, quality: quality, variants: variants)
                try await processCandidate(
                    url: selectedURL,
                    kind: selectedURL.pathExtension.lowercased() == "m3u8" ? .hls : .direct,
                    headers: [:],
                    format: format,
                    upscale2x: upscale2x
                )
            }

            status = diagnosticLog.isEmpty ? "Fertig." : "Fertig – funktionierende Quelle gefunden."
            progress = 1
        } catch {
            status = "Fehler"
            if diagnosticLog.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "\(error.localizedDescription)\n\nQuellen-Diagnose:\n\(diagnosticText)"
            }
            showError = true
        }
    }

    private func downloadPornhub(
        resolution: PornhubResolution,
        quality: String,
        format: String,
        upscale2x: Bool
    ) async throws {
        let candidates = MediaCandidateOrdering.order(resolution.candidates, quality: quality)
        guard !candidates.isEmpty else { throw VideoSaveError.mediaNotFound }

        appendDiagnostic("Reihenfolge für \(quality): \(candidates.count) Kandidat(en)")
        var lastError: Error = VideoSaveError.mediaNotFound

        for (index, candidate) in candidates.enumerated() {
            progress = 0
            let sourceName = diagnosticName(for: candidate)
            appendDiagnostic("Teste \(index + 1)/\(candidates.count): \(sourceName)")
            status = "Quelle \(index + 1)/\(candidates.count): \(candidate.qualityLabel) \(candidate.typeLabel)"

            do {
                try await processCandidate(
                    url: candidate.url,
                    kind: candidate.kind,
                    headers: resolution.requestHeaders,
                    format: format,
                    upscale2x: upscale2x
                )
                appendDiagnostic("✓ \(sourceName) funktioniert")
                return
            } catch {
                lastError = error
                appendDiagnostic("✗ \(sourceName): \(shortMessage(for: error))")

                if !MediaFallbackPolicy.shouldTryNext(after: error) {
                    throw error
                }
            }
        }

        throw lastError
    }

    private func processCandidate(
        url: URL,
        kind: PornhubMediaKind,
        headers: [String: String],
        format: String,
        upscale2x: Bool
    ) async throws {
        switch kind {
        case .hls:
            status = "HLS-Stream wird geprüft…"
            try await rejectProtectedHLSIfNeeded(url: url, headers: headers)

            status = "HLS wird geladen…"
            let temp = try await exportHLS(url: url, format: format, headers: headers)
            try await finishVideo(inputURL: temp, format: format, upscale2x: upscale2x)

        case .direct:
            status = "Video wird heruntergeladen…"
            let temp = try await downloadDirect(url: url, headers: headers)
            try await finishVideo(inputURL: temp, format: format, upscale2x: upscale2x)
        }
    }

    private func diagnosticsForResolution(_ resolution: PornhubResolution) -> [String] {
        let directCount = resolution.candidates.filter { $0.kind == .direct }.count
        let hlsCount = resolution.candidates.filter { $0.kind == .hls }.count
        let qualities = Array(Set(resolution.candidates.map(\.quality).filter { $0 > 0 })).sorted(by: >)
        let qualityText = qualities.isEmpty ? "unbekannt" : qualities.map { "\($0)p" }.joined(separator: ", ")
        return [
            "Resolver: \(resolution.candidates.count) Quelle(n) erkannt",
            "Direkt: \(directCount) · HLS: \(hlsCount)",
            "Qualitäten: \(qualityText)"
        ]
    }

    private func appendDiagnostic(_ line: String) {
        diagnosticLog.append(line)
        if diagnosticLog.count > 40 {
            diagnosticLog.removeFirst(diagnosticLog.count - 40)
        }
    }

    private func diagnosticName(for candidate: PornhubMediaCandidate) -> String {
        let host = candidate.url.host ?? "unbekannter Host"
        return "\(candidate.qualityLabel) \(candidate.typeLabel) @ \(host)"
    }

    private func shortMessage(for error: Error) -> String {
        if let videoError = error as? VideoSaveError {
            switch videoError {
            case .invalidURL: return "ungültige URL"
            case .httpError: return "HTTP-/Serverfehler"
            case .unsupportedPage: return "nicht unterstützte Antwort"
            case .mediaNotFound: return "keine Mediendaten"
            case .accessBlocked: return "Zugriff blockiert"
            case .captchaRequired: return "CAPTCHA erforderlich"
            case .noVideoTrack: return "keine Videospur"
            case .exportUnavailable: return "Export nicht verfügbar"
            case .exportFailed: return "Export fehlgeschlagen"
            case .protectedStream: return "geschützter Stream"
            case .upscaleOnly1080p: return "Upscaling-Quelle zu groß"
            case .photosDenied: return "Fotozugriff verweigert"
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    private func selectURL(
        original: URL,
        quality: String,
        variants: [HLSVariant]
    ) -> URL {
        guard !variants.isEmpty, quality != "Original" else { return original }

        let target = Int(quality.replacingOccurrences(of: "p", with: "")) ?? Int.max
        if let exact = variants.first(where: { $0.height == target }) {
            return exact.url
        }

        return variants.min {
            abs($0.height - target) < abs($1.height - target)
        }?.url ?? original
    }

    private func downloadDirect(
        url: URL,
        headers: [String: String]
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            downloadContinuation = continuation

            var request = URLRequest(url: url)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }

            downloadSession.downloadTask(with: request).resume()
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

        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)

        // Do not reject an HLS URL merely because load(.tracks) is initially empty.
        // Some valid variant playlists only expose their tracks once AVFoundation has
        // prepared the streaming asset. isPlayable is the safer preflight signal.
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw VideoSaveError.noVideoTrack }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSaveError.exportUnavailable
        }

        let ext = format == "MOV" ? "mov" : "mp4"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("videosave_hls_\(UUID().uuidString).\(ext)")

        exporter.outputURL = destination
        exporter.outputFileType = format == "MOV" ? .mov : .mp4
        exporter.shouldOptimizeForNetworkUse = true
        status = "HLS wird in \(format) exportiert…"

        await exporter.export()

        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw exporter.error ?? VideoSaveError.exportFailed
        }

        return destination
    }

    private func rejectProtectedHLSIfNeeded(
        url: URL,
        headers: [String: String],
        depth: Int = 0
    ) async throws {
        guard depth <= 6 else { throw VideoSaveError.mediaNotFound }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,*/*", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await mediaSession.data(for: request)
        try MediaAccessPolicy.validateResponse(response)

        guard let text = String(data: data, encoding: .utf8) else {
            throw VideoSaveError.mediaNotFound
        }

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            try MediaAccessPolicy.validatePage(text, finalURL: response.url)
            throw VideoSaveError.mediaNotFound
        }

        try MediaAccessPolicy.validatePlaylist(text)
        let baseURL = response.url ?? url

        let children = try HLSParser.parseMasterPlaylist(text: text, baseURL: baseURL).map(\.url)

        // Only alternate AUDIO/VIDEO playlists matter for the actual movie. Subtitle
        // playlists should not make an otherwise valid video candidate fail.
        let regex = try NSRegularExpression(
            pattern: #"(?mi)^#EXT-X-MEDIA:.*?TYPE=(?:AUDIO|VIDEO).*?URI=\"([^\"]+)\""#
        )
        let alternates = regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return URL(string: String(text[range]), relativeTo: baseURL)?.absoluteURL
        }

        for child in Set(children + alternates) {
            guard ["http", "https"].contains(child.scheme?.lowercased() ?? "") else {
                throw VideoSaveError.mediaNotFound
            }
            try await rejectProtectedHLSIfNeeded(
                url: child,
                headers: headers,
                depth: depth + 1
            )
        }
    }

    private func finishVideo(
        inputURL: URL,
        format: String,
        upscale2x: Bool
    ) async throws {
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.load(.tracks)

        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoSaveError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = orientedSize(naturalSize, transform: transform)

        if upscale2x {
            guard max(oriented.width, oriented.height) <= 1920.5,
                  min(oriented.width, oriented.height) <= 1080.5 else {
                throw VideoSaveError.upscaleOnly1080p
            }

            status = "AI-Upscaling 2×…"
            outputURL = try await VideoUpscaler.upscaleVideo(
                asset: asset,
                format: format
            ) { [weak self] p in
                Task { @MainActor in
                    self?.progress = p
                }
            }
        } else {
            status = "Video wird finalisiert…"
            outputURL = try await copyOrConvert(asset: asset, format: format)
        }
    }

    private func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func copyOrConvert(asset: AVAsset, format: String) async throws -> URL {
        let ext = format == "MOV" ? "mov" : "mp4"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoSave_\(UUID().uuidString).\(ext)")

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSaveError.exportUnavailable
        }

        exporter.outputURL = url
        exporter.outputFileType = format == "MOV" ? .mov : .mp4
        exporter.shouldOptimizeForNetworkUse = false
        await exporter.export()

        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw exporter.error ?? VideoSaveError.exportFailed
        }

        return url
    }

    func saveToPhotos() async {
        guard let outputURL else { return }

        do {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                throw VideoSaveError.photosDenied
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            }
            status = "In Fotos gespeichert."
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            status = "In Dateien exportiert."
        case .failure(let error) where (error as NSError).code != NSUserCancelledError:
            errorMessage = error.localizedDescription
            showError = true
        case .failure:
            break
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let pathExtension = downloadTask.originalRequest?.url?.pathExtension.lowercased()
        let safeExtension = ["mp4", "mov", "m4v"].contains(pathExtension ?? "") ? pathExtension! : "mp4"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("videosave_download_\(UUID().uuidString).\(safeExtension)")

        do {
            guard let response = downloadTask.response else { throw VideoSaveError.httpError }
            try MediaAccessPolicy.validateResponse(response)
            try MediaAccessPolicy.validateDownloadedMedia(response: response, fileURL: location)
            try FileManager.default.copyItem(at: location, to: destination)

            Task { @MainActor in
                guard let continuation = self.downloadContinuation else { return }
                self.downloadContinuation = nil
                continuation.resume(returning: destination)
            }
        } catch {
            Task { @MainActor in
                guard let continuation = self.downloadContinuation else { return }
                self.downloadContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        Task { @MainActor in
            guard let continuation = self.downloadContinuation else { return }
            self.downloadContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

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
    static func parseMasterPlaylist(text: String, baseURL: URL) throws -> [HLSVariant] {
        let lines = text.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var pending: (width: Int, height: Int, bandwidth: Int)?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let res = attrs["RESOLUTION"]?
                    .split(separator: "x")
                    .compactMap { Int($0) } ?? []

                pending = (
                    res.count == 2 ? res[0] : 0,
                    res.count == 2 ? res[1] : 0,
                    Int(attrs["BANDWIDTH"] ?? "0") ?? 0
                )
            } else if !line.isEmpty,
                      !line.hasPrefix("#"),
                      let p = pending,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
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

    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var quoted = false
        var parts: [String] = []

        for ch in text {
            if ch == "\"" { quoted.toggle() }
            if ch == "," && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }

        if !current.isEmpty { parts.append(current) }

        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                result[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        return result
    }
}
