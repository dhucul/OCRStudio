import SwiftUI

/// Thumbnail list of the pages in the working document. Pages can be reordered
/// (drag) and deleted to curate a batch before saving it as one PDF.
struct PageSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPageID) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                PageRow(page: page, number: index + 1)
                    .tag(page.id)
                    .contextMenu {
                        Button("Delete Page", role: .destructive) { model.deletePage(page.id) }
                    }
            }
            .onMove { from, to in model.movePages(fromOffsets: from, toOffset: to) }
            .onDelete { offsets in model.deletePages(atOffsets: offsets) }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.pages.isEmpty {
                Text("No pages yet.\nScan or open files to begin.\n\nScan several sheets, then Save PDF\nto combine them into one document.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

private struct PageRow: View {
    let page: PageVM
    let number: Int

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: page.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 56)
                    .background(Color(white: 0.95))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                Text("\(number)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(number)")
                    .font(.callout)
                    .lineLimit(1)
                Text(page.sourceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let ocr = page.ocr {
                    Text("\(ocr.lines.count) lines"
                         + (ocr.barcodes.isEmpty ? "" : " · \(ocr.barcodes.count) codes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not recognized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
