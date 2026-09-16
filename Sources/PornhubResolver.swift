import Foundation

enum PornhubMediaKind: String, Hashable {
    case direct
    case hls
}

struct PornhubMediaCandidate: Hashable {
    let url: URL
    let quality: Int
    let bandwidth: Int
    let kind: PornhubMediaKind

    var qualityLabel: String {
        quality > 0 ? "\(quality)p" : "Original"
    }

    var typeLabel: String {
        switch kind {
        case .direct:
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "DATEI" : ext
        case .hls:
            return "HLS"
        }
    }
}

struct PornhubResolution {
    let pageURL: URL
    let defaultURL: URL
    let variants: [HLSVariant]
    let requestHeaders: [String: String]
    let candidates: [PornhubMediaCandidate]
}

enum MediaCandidateOrdering {
    static func order(
        _ candidates: [PornhubMediaCandidate],
        quality: String
    ) -> [PornhubMediaCandidate] {
        let target = quality == "Original"
            ? nil
            : Int(quality.replacingOccurrences(of: "p", with: ""))

        return candidates.sorted { lhs, rhs in
            if let target {
                let lhsGroup = qualityGroup(lhs.quality, target: target)
                let rhsGroup = qualityGroup(rhs.quality, target: target)

                if lhsGroup != rhsGroup {
                    return lhsGroup < rhsGroup
                }

                if lhs.quality != rhs.quality {
                    switch lhsGroup {
                    case 1:
                        return lhs.quality > rhs.quality
                    case 2:
                        return lhs.quality < rhs.quality
                    default:
                        return lhs.quality > rhs.quality
                    }
                }
            } else if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality
            }

            if lhs.kind != rhs.kind {
                return lhs.kind == .direct
            }

            if lhs.bandwidth != rhs.bandwidth {
                return lhs.bandwidth > rhs.bandwidth
            }

            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    private static func qualityGroup(_ quality: Int, target: Int) -> Int {
        if quality == target { return 0 }
        if quality > 0 && quality < target { return 1 }
        if quality > target { return 2 }
        return 3
    }
}

/// Historical name kept so the rest of the app does not need a breaking API change.
/// Pornhub keeps its dedicated URL validation, while the requested tube-site catalog
/// is routed through the shared public-media resolver.
enum PornhubResolver {
    static func isPornhubPage(_ url: URL) -> Bool {
        isActualPornhubVideoPage(url) || SupportedSourceCatalog.matches(url)
    }

    static func resolve(
        _ pageURL: URL,
        using suppliedSession: URLSession? = nil
    ) async throws -> PornhubResolution {
        guard isPornhubPage(pageURL) else {
            throw VideoSaveError.unsupportedPage
        }

        return try await GenericTubeResolver.resolve(
            pageURL,
            using: suppliedSession
        )
    }

    static func sourceName(for url: URL) -> String {
        if isActualPornhubVideoPage(url) {
            return "Pornhub"
        }
        return SupportedSourceCatalog.displayName(for: url)
    }

    private static func isActualPornhubVideoPage(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else {
            return false
        }

        let normalizedHost = host.hasPrefix("www.")
            ? String(host.dropFirst(4))
            : host

        guard normalizedHost == "pornhub.com" ||
                normalizedHost.hasSuffix(".pornhub.com") else {
            return false
        }

        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )

        return url.path.lowercased() == "/view_video.php" &&
            components?.queryItems?.contains(where: {
                $0.name.lowercased() == "viewkey" &&
                    !($0.value ?? "").isEmpty
            }) == true
    }
}
