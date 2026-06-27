import SwiftUI

/// Thumbnail list of the pages in the working document.
struct PageSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPageID) {
            ForEach(model.pages) { page in
                PageRow(page: page)
                    .tag(page.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.pages.isEmpty {
                Text("No pages yet.\nScan or open files to begin.")
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

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: page.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 56)
                .background(Color(white: 0.95))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))

            VStack(alignment: .leading, spacing: 2) {
                Text(page.sourceName)
                    .font(.callout)
                    .lineLimit(1)
                if let ocr = page.ocr {
                    Text("\(ocr.lines.count) lines"
                         + (ocr.barcodes.isEmpty ? "" : " · \(ocr.barcodes.count) codes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let c = ocr.averageConfidence {
                        Text("\(Int(c * 100))% confidence")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
