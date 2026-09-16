import Foundation

enum HLSOfflineContainer: String, Equatable {
    case mpegTransportStream = "MPEG-TS"
    case fragmentedMP4 = "fMP4"
}

enum HLSOfflinePartKind: Equatable {
    case initialization
    case media
}

struct HLSOfflinePart: Equatable {
    let url: URL
    let kind: HLSOfflinePartKind
}

struct HLSMediaPlaylistDescription: Equatable {
    let parts: [HLSOfflinePart]
    let segmentCount: Int
    let container: HLSOfflineContainer
}

struct HLSOfflineDownloadResult {
    let fileURL: URL
    let diagnosticLines: [String]
}

enum HLSOfflineError: LocalizedError {
    case noSegments
    case invalidPartURL
    case unsupportedByteRange
    case unsupportedLiveStream
    case emptyPart

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "Die HLS-Playlist enthält keine herunterladbaren Mediensegmente."
        case .invalidPartURL:
            return "Die HLS-Playlist enthält eine ungültige Segment-URL."
        case .unsupportedByteRange:
            return "Diese HLS-Quelle verwendet Byte-Range-Segmente, die VideoSave noch nicht lokal zusammensetzen kann."
        case .unsupportedLiveStream:
            return "Live-HLS wird nicht als Datei gespeichert. VideoSave verarbeitet nur abgeschlossene Video-Playlists."
        case .emptyPart:
            return "Ein HLS-Mediensegment war leer."
        }
    }
}

enum HLSMediaPlaylistParser {
    static func parse(text: String, baseURL: URL) throws -> HLSMediaPlaylistDescription {
        try MediaAccessPolicy.validatePlaylist(text)

        let lines = text.components(separatedBy: .newlines)
        var parts: [HLSOfflinePart] = []
        var segmentCount = 0
        var usesInitializationMap = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-BYTERANGE:") ||
                (line.hasPrefix("#EXT-X-MAP:") && line.uppercased().contains("BYTERANGE=")) {
                throw HLSOfflineError.unsupportedByteRange
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                guard let rawURI = attribute(named: "URI", in: line),
                      let mapURL = URL(string: rawURI, relativeTo: baseURL)?.absoluteURL,
                      ["http", "https"].contains(mapURL.scheme?.lowercased() ?? "") else {
                    throw HLSOfflineError.invalidPartURL
                }
                parts.append(HLSOfflinePart(url: mapURL, kind: .initialization))
                usesInitializationMap = true
                continue
            }

            if line.hasPrefix("#") { continue }

            guard let segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(segmentURL.scheme?.lowercased() ?? "") else {
                throw HLSOfflineError.invalidPartURL
            }
            parts.append(HLSOfflinePart(url: segmentURL, kind: .media))
            segmentCount += 1
        }

        guard segmentCount > 0 else { throw HLSOfflineError.noSegments }

        let mediaExtensions = parts
            .filter { $0.kind == .media }
            .map { $0.url.pathExtension.lowercased() }
        let looksLikeFragmentedMP4 = usesInitializationMap || mediaExtensions.contains {
            ["m4s", "mp4", "cmfa", "cmfv"].contains($0)
        }

        return HLSMediaPlaylistDescription(
            parts: parts,
            segmentCount: segmentCount,
            container: looksLikeFragmentedMP4 ? .fragmentedMP4 : .mpegTransportStream
        )
    }

    private static func attribute(named name: String, in line: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = escaped + #"\s*=\s*(?:\"([^\"]+)\"|([^,\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }

        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            if let swiftRange = Range(match.range(at: index), in: line) {
                return String(line[swiftRange])
            }
        }
        return nil
    }
}

@MainActor
enum HLSOfflineDownloader {
    static func download(
        url: URL,
        headers: [String: String],
        session: URLSession,
        depth: Int = 0,
        onProgress: (Double) -> Void
    ) async throws -> HLSOfflineDownloadResult {
        guard depth <= 4 else { throw VideoSaveError.mediaNotFound }

        let (playlistData, playlistResponse) = try await request(
            url: url,
            headers: headers,
            accept: "application/vnd.apple.mpegurl,application/x-mpegURL,*/*",
            session: session
        )
        try MediaAccessPolicy.validateResponse(playlistResponse)

        guard let playlistText = String(data: playlistData, encoding: .utf8) else {
            throw VideoSaveError.mediaNotFound
        }
        if !playlistText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            try MediaAccessPolicy.validatePage(playlistText, finalURL: playlistResponse.url)
            throw VideoSaveError.mediaNotFound
        }
        try MediaAccessPolicy.validatePlaylist(playlistText)

        let playlistURL = playlistResponse.url ?? url
        let variants = try HLSParser.parseMasterPlaylist(text: playlistText, baseURL: playlistURL)
        if let best = variants.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.bandwidth > $1.bandwidth
        }).first {
            let nested = try await download(
                url: best.url,
                headers: headers,
                session: session,
                depth: depth + 1,
                onProgress: onProgress
            )
            let label = best.height > 0 ? "\(best.height)p" : "beste Variante"
            return HLSOfflineDownloadResult(
                fileURL: nested.fileURL,
                diagnosticLines: ["HLS-Master → \(label)"] + nested.diagnosticLines
            )
        }

        // A finite VOD playlist is expected here. Avoid silently recording a live stream.
        guard playlistText.uppercased().contains("#EXT-X-ENDLIST") else {
            throw HLSOfflineError.unsupportedLiveStream
        }

        let description = try HLSMediaPlaylistParser.parse(text: playlistText, baseURL: playlistURL)
        let ext = description.container == .fragmentedMP4 ? "mp4" : "ts"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("videosave_hls_local_\(UUID().uuidString).\(ext)")

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        let totalParts = max(description.parts.count, 1)
        for (index, part) in description.parts.enumerated() {
            let (data, response) = try await request(
                url: part.url,
                headers: headers,
                accept: "*/*",
                session: session
            )
            try MediaAccessPolicy.validateResponse(response)
            try validateMediaPayload(data, response: response)
            guard !data.isEmpty else { throw HLSOfflineError.emptyPart }
            try handle.write(contentsOf: data)
            onProgress(Double(index + 1) / Double(totalParts) * 0.85)
        }

        try handle.synchronize()
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw HLSOfflineError.emptyPart }

        succeeded = true
        let mime = (playlistResponse as? HTTPURLResponse)?.mimeType ?? "unbekannt"
        return HLSOfflineDownloadResult(
            fileURL: destination,
            diagnosticLines: [
                "HLS-Playlist: \(description.segmentCount) Segmente · \(description.container.rawValue)",
                "Playlist-MIME: \(mime)",
                "HLS lokal geladen: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            ]
        )
    }

    private static func request(
        url: URL,
        headers: [String: String],
        accept: String,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    private static func validateMediaPayload(_ data: Data, response: URLResponse) throws {
        let mime = response.mimeType?.lowercased() ?? ""
        let prefixData = data.prefix(64 * 1024)
        let prefix = String(data: prefixData, encoding: .utf8) ?? ""
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let looksLikeHTML = mime == "text/html" ||
            mime == "application/xhtml+xml" ||
            trimmed.hasPrefix("<!doctype html") ||
            trimmed.hasPrefix("<html") ||
            trimmed.hasPrefix("<head") ||
            trimmed.hasPrefix("<body")

        if looksLikeHTML {
            try MediaAccessPolicy.validatePage(prefix, finalURL: response.url)
            throw VideoSaveError.mediaNotFound
        }
    }
}
