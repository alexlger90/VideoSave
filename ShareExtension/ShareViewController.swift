import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareLinkView(model: model, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
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
                for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    if let value = try? await load(provider, type: type),
                       let url = SharedLink.url(from: value) {
                        model.url = url
                        model.isLoading = false
                        return
                    }
                }
            }
            if let text = item.attributedContentText?.string, let url = SharedLink.url(from: text) {
                model.url = url
                model.isLoading = false
                return
            }
        }
        model.isLoading = false
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
}

private struct ShareLinkView: View {
    @ObservedObject var model: ShareModel
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "flag.checkered").font(.largeTitle).foregroundStyle(.red)
                    Text("Ab in die Garage.").font(.largeTitle.bold())
                    if model.isLoading {
                        ProgressView("Link wird übernommen…")
                    } else if let url = model.url {
                        Text(url.host ?? "Videolink").font(.headline)
                        Text(url.absoluteString).font(.footnote.monospaced())
                            .foregroundStyle(.secondary).lineLimit(5)
                        Text(model.copied
                             ? "Link kopiert. Öffne VideoSave und tippe auf „Einsetzen“. Dort kannst du Qualität, Format und 4K wählen."
                             : "Kopiere den Link und setze ihn anschließend in VideoSave ein. Download und 4K-Verarbeitung laufen in der App.")
                            .font(.body)
                        Button {
                            UIPasteboard.general.setItems([[UTType.url.identifier: url,
                                                          UTType.utf8PlainText.identifier: url.absoluteString]],
                                                         options: [.localOnly: true])
                            model.copied = true
                        } label: {
                            Label(model.copied ? "Erneut kopieren" : "Link für VideoSave kopieren", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        if model.copied {
                            Button("Fertig", action: finish).frame(maxWidth: .infinity, minHeight: 44)
                        }
                    } else {
                        Label("Kein unterstützter Weblink gefunden. Teile die Adresse einer Videoseite oder einen direkten Videolink.", systemImage: "link.badge.plus")
                    }
                }
                .padding(24)
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.06))
            .navigationTitle("VideoSave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: finish) } }
        }
        .tint(Color(red: 1, green: 0.24, blue: 0.19))
        .preferredColorScheme(.dark)
    }
}
