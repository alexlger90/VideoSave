import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareLinkView(
            model: model,
            openApp: { [weak self] in self?.openVideoSave() },
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        ))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        Task { await readSharedLink() }
    }

    private func readSharedLink() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                for type in [UTType.url.identifier, UTType.plainText.identifier]
                where provider.hasItemConformingToTypeIdentifier(type) {
                    if let value = try? await load(provider, type: type),
                       let url = SharedLink.url(from: value) {
                        accept(url)
                        return
                    }
                }
            }
            if let text = item.attributedContentText?.string,
               let url = SharedLink.url(from: text) {
                accept(url)
                return
            }
        }
        model.isLoading = false
    }

    private func accept(_ url: URL) {
        model.url = url
        model.isLoading = false
        UIPasteboard.general.setItems(
            [[UTType.url.identifier: url, UTType.utf8PlainText.identifier: url.absoluteString]],
            options: [.localOnly: true]
        )
        model.copied = true
        openVideoSave()
    }

    private func openVideoSave() {
        guard let url = model.url,
              let deepLink = SharedLink.appImportURL(for: url),
              !model.isOpening else { return }
        model.isOpening = true
        model.openFailed = false

        extensionContext?.open(deepLink) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                self.model.isOpening = false
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    // Share extensions are not guaranteed to be allowed to launch
                    // their containing app. Keep the copied link as the fallback.
                    self.model.openFailed = true
                }
            }
        }
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = value as? URL { continuation.resume(returning: url.absoluteString) }
                else if let text = value as? String { continuation.resume(returning: text) }
                else if let data = value as? Data { continuation.resume(returning: String(data: data, encoding: .utf8)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }
}

@MainActor
private final class ShareModel: ObservableObject {
    @Published var url: URL?
    @Published var isLoading = true
    @Published var copied = false
    @Published var isOpening = false
    @Published var openFailed = false
}

private struct ShareLinkView: View {
    @ObservedObject var model: ShareModel
    let openApp: () -> Void
    let finish: () -> Void

    private let background = Color(red: 0.035, green: 0.045, blue: 0.06)
    private let panel = Color(red: 0.085, green: 0.10, blue: 0.12)
    private let accent = Color(red: 1, green: 0.24, blue: 0.19)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("VIDEOSAVE / PIT LANE")
                                .font(.caption2.weight(.bold)).tracking(2.5)
                                .foregroundStyle(accent)
                            Text("Link in die Garage")
                                .font(.title.bold())
                        }
                        Spacer()
                        Image(systemName: "flag.checkered")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    if model.isLoading {
                        HStack(spacing: 12) {
                            ProgressView().tint(accent)
                            Text("Browser-Link wird übernommen…")
                        }
                        .pitCard(panel: panel)
                    } else if let url = model.url {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label(sourceName(url), systemImage: sourceIcon(url))
                                    .font(.headline)
                                Spacer()
                                Text(model.isOpening ? "ÖFFNEN" : "BEREIT")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(accent.opacity(0.16), in: Capsule())
                            }
                            Text(url.absoluteString)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                            Divider().overlay(.white.opacity(0.08))
                            HStack {
                                metric("QUELLE", sourceName(url))
                                Spacer()
                                metric("4K", "IN APP")
                                Spacer()
                                metric("WEBVIEW", "CAPTCHA ONLY")
                            }
                        }
                        .pitCard(panel: panel)

                        if model.openFailed {
                            Label("Der Link ist bereits übernommen. iOS hat das automatische Öffnen aus der Share Extension abgelehnt; öffne VideoSave anschließend normal und tippe bei Bedarf auf „Einsetzen“.", systemImage: "iphone.and.arrow.forward")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .pitCard(panel: panel)
                        } else {
                            Text("VideoSave versucht den Link direkt an die Haupt-App zu übergeben. Der Link liegt zusätzlich sicher in der Zwischenablage bereit.")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.86))
                        }

                        Button(action: openApp) {
                            HStack {
                                if model.isOpening { ProgressView().tint(.white) }
                                Label(model.isOpening ? "VideoSave wird geöffnet…" : "VideoSave öffnen",
                                      systemImage: "arrow.up.forward.app.fill")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .disabled(model.isOpening)

                        Button("Fertig", action: finish)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .buttonStyle(.bordered)
                    } else {
                        Label("Kein unterstützter Weblink gefunden. Teile im Browser die Adresse der Videoseite oder einen direkten Medienlink.", systemImage: "link.badge.plus")
                            .pitCard(panel: panel)
                    }

                    Label("Share Sheet → VideoSave · keine automatische CAPTCHA-Umgehung", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(22)
            }
            .background(background)
            .navigationTitle("VideoSave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: finish) } }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }

    private func sourceName(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        return host.contains("pornhub.com") ? "Pornhub" : (url.host ?? "Videolink")
    }

    private func sourceIcon(_ url: URL) -> String {
        (url.host ?? "").lowercased().contains("pornhub.com") ? "play.rectangle.fill" : "link"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(value).font(.caption.bold()).lineLimit(1)
        }
    }
}

private extension View {
    func pitCard(panel: Color) -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }
}
