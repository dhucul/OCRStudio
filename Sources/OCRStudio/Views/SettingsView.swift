import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            // OCR
            Form {
                TextField("Languages (comma-separated)", text: languagesBinding)
                    .help("BCP-47 codes in priority order, e.g. en-US, fr-FR")
                Toggle("Detect language automatically",
                       isOn: $model.settings.automaticLanguageDetection)
                Toggle("Detect barcodes / QR codes", isOn: $model.settings.detectBarcodes)
                Picker("PDFs with existing text", selection: $model.settings.textLayerPolicy) {
                    ForEach(TextLayerPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .padding()
            .tabItem { Label("OCR", systemImage: "text.viewfinder") }

            // Image preprocessing
            Form {
                Toggle("Auto-crop & deskew (photographed docs)",
                       isOn: $model.settings.autoCropDeskew)
                Toggle("Enhance contrast", isOn: $model.settings.enhanceContrast)
                Toggle("Denoise", isOn: $model.settings.denoise)
                Toggle("Convert to grayscale", isOn: $model.settings.grayscale)
                Divider()
                Picker("Rasterize PDFs at", selection: $model.settings.rasterDPI) {
                    ForEach([150.0, 200.0, 300.0, 400.0], id: \.self) {
                        Text("\(Int($0)) dpi").tag($0)
                    }
                }
            }
            .padding()
            .tabItem { Label("Image", systemImage: "wand.and.stars") }

            // Output / folders
            Form {
                folderRow("Output folder",
                          url: model.settings.outputDirectory) { model.settings.outputDirectory = $0 }
                folderRow("Watch folder",
                          url: model.settings.watchFolder) { model.settings.watchFolder = $0 }
                Text("Files dropped into the watch folder are auto-OCR'd to a searchable PDF + text sidecar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Output", systemImage: "folder") }
        }
        .frame(width: 480, height: 320)
        .padding()
    }

    private func folderRow(_ label: String, url: URL?, onPick: @escaping (URL?) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Text(url?.path ?? "Not set")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { if let picked = chooseFolder() { onPick(picked) } }
                if url != nil { Button("Clear") { onPick(nil) } }
            }
        }
    }

    private var languagesBinding: Binding<String> {
        Binding(
            get: { model.settings.recognitionLanguages.joined(separator: ", ") },
            set: { newValue in
                model.settings.recognitionLanguages = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
