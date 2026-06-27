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

            Picker("Source", selection: $model.scanSource) {
                Text("Flatbed").tag(ScanJobOptions.Source.flatbed)
                Text("Document Feeder").tag(ScanJobOptions.Source.documentFeeder)
            }

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
            .disabled(scanner.scanners.isEmpty || scanner.isScanning || model.isBusy)

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
}
