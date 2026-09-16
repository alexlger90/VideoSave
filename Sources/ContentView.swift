import SwiftUI
import UniformTypeIdentifiers

private enum GarageStyle {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.06)
    static let panel = Color(red: 0.085, green: 0.10, blue: 0.12)
    static let accent = Color(red: 1, green: 0.24, blue: 0.19)
}

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @State private var urlText = ""
    @State private var selectedQuality = "Original"
    @State private var selectedFormat = "MP4"
    @State private var aiUpscale = false
    @State private var variants: [HLSVariant] = []
    @State private var isChecking = false
    @FocusState private var linkFocused: Bool

    private var controlsLocked: Bool { isChecking || manager.isBusy }
    private var linkIsEmpty: Bool { urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    cockpit
                    sourceCard
                    setupCard
                    if !manager.status.isEmpty { statusCard }
                    saveButton
                    if let outputURL = manager.outputURL, !manager.isBusy {
                        exportCard(outputURL)
                    }
                    Label("Direkte Auflösung · ohne In-App-Browser", systemImage: "link")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(GarageStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .fileExporter(
                isPresented: $manager.presentFileExporter,
                document: manager.exportDocument,
                contentType: manager.outputURL?.pathExtension == "mov" ? .quickTimeMovie : .mpeg4Movie,
                defaultFilename: manager.outputURL?.deletingPathExtension().lastPathComponent ?? "VideoSave"
            ) { manager.handleExportResult($0) }
            .alert("VideoSave", isPresented: $manager.showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(manager.errorMessage)
            }
            .onChange(of: urlText) { _, _ in
                variants = []
                selectedQuality = "Original"
                manager.status = ""
            }
        }
        .tint(GarageStyle.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIDEOSAVE / GARAGE")
                    .font(.caption2.weight(.bold)).tracking(3)
                    .foregroundStyle(GarageStyle.accent)
                Text("Dein Video.\nDeine Ideallinie.")
                    .font(.largeTitle.weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "flag.checkered")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
        }
    }

    private var cockpit: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("COCKPIT", systemImage: "steeringwheel")
                    .font(.caption.weight(.bold)).tracking(2)
                Spacer()
                Text(manager.isBusy ? "IN ARBEIT" : isChecking ? "PRÜFUNG" : "BEREIT")
                    .font(.caption2.monospaced().weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(GarageStyle.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(GarageStyle.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(manager.isBusy ? "\(Int(min(max(manager.progress, 0), 1) * 100))" : "VS")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(manager.isBusy ? "%" : "PERFORMANCE")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 5) {
                ForEach(0..<20) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(index))
                        .frame(height: index > 15 ? 18 : 12)
                }
            }
            .accessibilityHidden(true)
            HStack(alignment: .top) {
                telemetry("QUALITÄT", value: selectedQuality)
                Spacer()
                telemetry("FORMAT", value: selectedFormat)
                Spacer()
                telemetry("UPSCALE", value: aiUpscale ? "4K AI" : "AUS")
            }
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.20, blue: 0.23), GarageStyle.panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func barColor(_ index: Int) -> Color {
        let filled = manager.isBusy ? Double(index) < manager.progress * 20 : index < 4
        return filled ? (index > 15 ? Color.orange : GarageStyle.accent) : .white.opacity(0.08)
    }

    private func telemetry(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold))
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("01", title: "Startposition", subtitle: "Videolink einfügen")
            TextField("https://…", text: $urlText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($linkFocused)
                .submitLabel(.done)
                .onSubmit { linkFocused = false }
                .padding(14)
                .background(GarageStyle.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
                .accessibilityLabel("Video-URL")
                .disabled(controlsLocked)
            PasteButton(payloadType: String.self) { values in
                if let pasted = values.compactMap({ SharedLink.url(from: $0) }).first {
                    urlText = pasted.absoluteString
                } else {
                    manager.status = "Die Zwischenablage enthält keinen HTTP-/HTTPS-Link."
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(controlsLocked)
            .accessibilityLabel("Videolink aus der Zwischenablage einsetzen")
            Button {
                linkFocused = false
                Task { await checkURL() }
            } label: {
                HStack {
                    if isChecking { ProgressView().tint(.white) }
                    Label(isChecking ? "Quelle wird geprüft…" : "Qualitäten prüfen", systemImage: "slider.horizontal.3")
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(linkIsEmpty || controlsLocked)
            Text("Pornhub-Videolinks und direkte MP4-/HLS-Quellen werden in der App verarbeitet.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .garageCard()
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("02", title: "Dein Setup", subtitle: "Abgestimmt auf dein Video")
            HStack {
                Label("Qualität", systemImage: "4k.tv")
                Spacer()
                Picker("Qualität", selection: $selectedQuality) {
                    ForEach(availableQualityNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Divider().overlay(.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 10) {
                Label("Dateiformat", systemImage: "film.stack")
                Picker("Format", selection: $selectedFormat) {
                    Text("MP4").tag("MP4")
                    Text("MOV").tag("MOV")
                }
                .pickerStyle(.segmented)
            }
            Divider().overlay(.white.opacity(0.06))
            Toggle(isOn: $aiUpscale) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("AI-Upscaling", systemImage: "sparkles")
                        .font(.body.weight(.semibold))
                    Text("4K-Ausgabe · Real-ESRGAN 2× + Skalierung")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(variants.isEmpty ? "Prüfe den Link, um verfügbare Qualitäten auszuwählen." : "\(availableQualityNames.count - 1) Auflösungen verfügbar. Original verwendet die beste angebotene Quelle.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(controlsLocked)
        .garageCard()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(manager.status, systemImage: manager.isBusy ? "gauge.with.dots.needle.67percent" : "info.circle")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if manager.isBusy {
                ProgressView(value: manager.progress)
                    .accessibilityLabel("Verarbeitungsfortschritt")
            }
        }
        .garageCard()
    }

    private var saveButton: some View {
        Button {
            linkFocused = false
            Task {
                await manager.download(urlString: urlText, quality: selectedQuality, variants: variants,
                                       format: selectedFormat, upscale2x: aiUpscale)
            }
        } label: {
            Label(manager.isBusy ? "Video wird verarbeitet…" : "Video speichern", systemImage: "arrow.down.to.line")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .disabled(linkIsEmpty || controlsLocked)
    }

    private func exportCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("03", title: "Im Ziel", subtitle: "Dein Video ist bereit")
            Button { manager.presentFileExporter = true } label: {
                Label("In Dateien exportieren", systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            Button { Task { await manager.saveToPhotos() } } label: {
                Label("In Fotos speichern", systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .garageCard()
    }

    private func sectionTitle(_ number: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Text(number).font(.headline.monospaced()).foregroundStyle(GarageStyle.accent)
                .frame(width: 40, height: 40)
                .background(GarageStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var availableQualityNames: [String] {
        ["Original"] + Array(Set(variants.map(\.height).filter { $0 > 0 })).sorted(by: >).map { "\($0)p" }
    }

    @MainActor private func checkURL() async {
        isChecking = true
        variants = []
        selectedQuality = "Original"
        defer { isChecking = false }
        do {
            variants = try await manager.inspect(urlString: urlText)
            manager.status = variants.isEmpty ? "Direkter Medienlink erkannt." : "Videoquelle bereit. Wähle dein Setup."
        } catch {
            manager.status = error.localizedDescription
        }
    }
}

private extension View {
    func garageCard() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GarageStyle.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

#Preview { ContentView() }
