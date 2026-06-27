import SwiftUI

/// Scanner picker + scan settings + Scan button. Observes `ScannerService`
/// (a Combine `ObservableObject`) for live device discovery and status.
struct ScanPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScanPanelInner(scanner: model.scanner, model: model)
    }
}

private struct ScanPanelInner: View {
    @ObservedObject var scanner: ScannerService
    @Bindable var model: AppModel
    @State private var selectedScanner: String = ""

    private let dpiOptions = [150, 200, 300, 400, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scanner")
                .font(.headline)

            HStack {
                Picker("", selection: $selectedScanner) {
                    if scanner.scanners.isEmpty {
                        Text("No scanners").tag("")
                    }
                    ForEach(scanner.scanners) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                .labelsHidden()

                Button {
                    scanner.startBrowsing()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh scanner list")
            }

            if scanner.scanners.isEmpty {
                noScannerHint
            } else {
                nativeScanControls
            }

            if model.epsonScannerAppURL != nil {
                Divider()
                epsonFallback
            }

            Text(scanner.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .onChange(of: scanner.scanners.map(\.id)) { _, ids in
            if selectedScanner.isEmpty, let first = ids.first { selectedScanner = first }
        }
    }

    // MARK: Native (ImageCaptureCore) scan controls

    private var nativeScanControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $model.scanSource) {
                Text("Flatbed").tag(ScanJobOptions.Source.flatbed)
                Text("Document Feeder").tag(ScanJobOptions.Source.documentFeeder)
            }

            Picker("Page size", selection: $model.scanPageSize) {
                ForEach(ScanJobOptions.PageSize.allCases) { Text($0.label).tag($0) }
            }
            .help("Feeder/sheet-fed scanners capture at this size; auto-crop trims the margins.")

            Picker("Resolution", selection: $model.scanDPI) {
                ForEach(dpiOptions, id: \.self) { Text("\($0) dpi").tag($0) }
            }

            Toggle("Color", isOn: $model.scanColor)
            Toggle("Duplex (ADF)", isOn: $model.scanDuplex)
                .disabled(model.scanSource != .documentFeeder)

            Button {
                let id = selectedScanner.isEmpty ? scanner.scanners.first?.id : selectedScanner
                if let id { model.scan(scannerID: id) }
            } label: {
                Label("Scan", systemImage: "scanner")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(scanner.isScanning || model.isBusy)
        }
    }

    // MARK: Hint shown when macOS/ICA can't see any scanner

    private var noScannerHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS doesn't see a scanner", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Text("If Epson's software detects your scanner but macOS doesn't, scan with Epson below and save into a **Watch Folder** (Settings ▸ Output) — OCR Studio will auto-OCR every file dropped there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Epson-software fallback

    private var epsonButton: some View {
        Button {
            model.launchEpsonScanner()
        } label: {
            Label("Scan with Epson…", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var epsonFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Prominent when it's the only way to scan; secondary otherwise.
            if scanner.scanners.isEmpty {
                epsonButton.buttonStyle(.borderedProminent)
            } else {
                epsonButton.buttonStyle(.bordered)
            }

            Button {
                model.toggleWatch()
            } label: {
                Label(model.isWatching ? "Stop Watching Folder" : "Start Watching Folder",
                      systemImage: model.isWatching ? "eye.fill" : "eye")
                    .frame(maxWidth: .infinity)
            }

            Text(model.isWatching
                 ? "Watching for new scans…"
                 : "Set a Watch Folder in Settings, then save Epson scans there.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
