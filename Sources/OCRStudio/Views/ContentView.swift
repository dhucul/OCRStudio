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
            Button { model.rerunOCR() } label: {
                Label("Run OCR", systemImage: "text.viewfinder")
            }
            .disabled(!model.hasPages || model.isBusy)

            Menu {
                Button("Searchable PDF…") { model.exportSearchablePDF() }
                Button("Plain Text…") { model.exportText() }
                Button("Markdown…") { model.exportMarkdown() }
                Button("JSON (boxes)…") { model.exportJSON() }
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
            .disabled(!model.hasPages)
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
