import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                ScanPanel()
                Divider()
                PageSidebar()
            }
            .frame(minWidth: 260)
        } detail: {
            PreviewPane()
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.openFilePicker() } label: {
                Label("Open", systemImage: "folder")
            }
            .disabled(model.isBusy)
            Button { model.rerunOCR() } label: {
                Label("Run OCR", systemImage: "text.viewfinder")
            }
            .disabled(!model.hasPages || model.isBusy)

            Button { model.exportSearchablePDF() } label: {
                Label("Save PDF", systemImage: "doc.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Combine all \(model.pages.count) page(s) into one searchable PDF")
            .disabled(!model.hasPages || model.isBusy)

            Menu {
                Section("Edited text") {
                    Button("Word Document (.docx)…") { model.exportWord() }
                    Button("PDF (text)…") { model.exportTextPDF() }
                    Button("Plain Text (.txt)…") { model.exportText() }
                }
                Section("From scan") {
                    Button("Searchable PDF (scan + text)…") { model.exportSearchablePDF() }
                    Button("Markdown…") { model.exportMarkdown() }
                    Button("JSON (boxes)…") { model.exportJSON() }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.hasPages || model.isBusy)

            Button { model.toggleWatch() } label: {
                Label(model.isWatching ? "Stop Watch" : "Watch Folder",
                      systemImage: model.isWatching ? "eye.fill" : "eye")
            }

            Button(role: .destructive) { model.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(!model.hasPages || model.isBusy)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.isBusy {
                Button("Cancel") { model.cancelJob() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer()
            Text("\(model.pages.count) page\(model.pages.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
