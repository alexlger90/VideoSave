import SwiftUI
import AVFoundation
import Photos
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @State private var urlText = ""
    @State private var selectedQuality = "Original"
    @State private var selectedFormat = "MP4"
    @State private var aiUpscale = false
    @State private var variants: [HLSVariant] = []
    @State private var isChecking = false

    private let qualities = ["Original", "1080p", "720p", "480p", "360p", "240p"]
    private let formats = ["MP4", "MOV"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Video-URL")
                            .font(.headline)

                        TextField(
                            "https://www.pornhub.com/view_video.php?viewkey=…",
                            text: $urlText
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)

                        Button {
                            Task {
                                await checkURL()
                            }
                        } label: {
                            Label(
                                isChecking ? "Prüfe…" : "Qualitäten prüfen",
                                systemImage: "list.bullet.rectangle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            urlText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                            || isChecking
                            || manager.isBusy
                        )
                    }

                    if !variants.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Qualität")
                                .font(.headline)

                            Picker("Qualität", selection: $selectedQuality) {
                                ForEach(
                                    availableQualityNames,
                                    id: \.self
                                ) {
                                    Text($0).tag($0)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(
                                "Bei unterstützten Seiten werden die vom Server angebotenen Videoqualitäten angezeigt."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Qualität")
                                .font(.headline)

                            Picker(
                                "Qualität",
                                selection: $selectedQuality
                            ) {
                                ForEach(
                                    qualities,
                                    id: \.self
                                ) {
                                    Text($0).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ausgabe")
                            .font(.headline)

                        Picker(
                            "Format",
                            selection: $selectedFormat
                        ) {
                            ForEach(
                                formats,
                                id: \.self
                            ) {
                                Text($0).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle(isOn: $aiUpscale) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI-Upscaling")

                                Text("2× → 4K UHD bei 1080p-Quelle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if manager.isBusy {
                        VStack(spacing: 8) {
                            ProgressView(value: manager.progress)

                            Text(manager.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !manager.status.isEmpty {
                        Text(manager.status)
                            .font(.callout)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                    }

                    Button {
                        Task {
                            await manager.download(
                                urlString: urlText,
                                quality: selectedQuality,
                                variants: variants,
                                format: selectedFormat,
                                upscale2x: aiUpscale
                            )
                        }
                    } label: {
                        Label(
                            "Video speichern",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        urlText
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                        || manager.isBusy
                    )

                    if let outputURL = manager.outputURL,
                       !manager.isBusy {

                        VStack(spacing: 10) {
                            Button {
                                manager.presentFileExporter = true
                            } label: {
                                Label(
                                    "In Dateien exportieren",
                                    systemImage: "folder"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task {
                                    await manager.saveToPhotos()
                                }
                            } label: {
                                Label(
                                    "In Fotos speichern",
                                    systemImage: "photo"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Text(outputURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("VideoSave")
            .fileExporter(
                isPresented: $manager.presentFileExporter,
                document: manager.exportDocument,
                contentType: selectedFormat == "MOV"
                    ? .quickTimeMovie
                    : .mpeg4Movie,
                defaultFilename:
                    manager.outputURL?
                        .deletingPathExtension()
                        .lastPathComponent
                    ?? "VideoSave"
            ) { result in
                manager.handleExportResult(result)
            }
            .alert(
                "VideoSave",
                isPresented: $manager.showError
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(manager.errorMessage)
            }
        }
    }

    private var availableQualityNames: [String] {
        var result = ["Original"]

        result += variants.compactMap { variant in
            let p = variant.height

            guard p > 0 else {
                return nil
            }

            return "\(p)p"
        }

        return Array(
            NSOrderedSet(array: result)
        ) as? [String] ?? result
    }

    private func checkURL() async {
        isChecking = true
        defer {
            isChecking = false
        }

        do {
            let parsed = try await manager.inspect(
                urlString: urlText
            )

            variants = parsed

            if let best = parsed.first?.height,
               selectedQuality != "Original" {
                _ = best
            }

            manager.status = parsed.isEmpty
                ? "Direkter Medienlink erkannt."
                : "\(parsed.count) HLS-Qualitäten gefunden."

        } catch {
            variants = []
            selectedQuality = "Original"
            manager.status = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
