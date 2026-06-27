import SwiftUI

/// The detail pane: the selected page image with optional OCR box overlay, plus a
/// text/barcode inspector on the right.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    @State private var showBoxes = true

    var body: some View {
        if let page = model.selectedPage {
            HSplitView {
                ImageWithBoxes(page: page, showBoxes: showBoxes)
                    .frame(minWidth: 360)
                TextInspector(page: page)
                    .frame(minWidth: 280, maxWidth: 460)
            }
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $showBoxes) {
                        Label("Boxes", systemImage: "rectangle.dashed")
                    }
                }
            }
        } else {
            ContentUnavailableView("No Page Selected",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Scan a document or open a file to see it here."))
        }
    }
}

private struct ImageWithBoxes: View {
    let page: PageVM
    let showBoxes: Bool

    var body: some View {
        GeometryReader { geo in
            let imgW = CGFloat(page.image.width)
            let imgH = CGFloat(page.image.height)
            let scale = min(geo.size.width / imgW, geo.size.height / imgH)
            let w = imgW * scale
            let h = imgH * scale

            ZStack(alignment: .topLeading) {
                Image(nsImage: page.nsImage)
                    .resizable()
                    .frame(width: w, height: h)

                if showBoxes, let ocr = page.ocr {
                    Canvas { context, _ in
                        for line in ocr.lines {
                            for word in line.words {
                                let r = scaled(word.box, scale)
                                context.stroke(Path(r),
                                               with: .color(.blue.opacity(0.55)),
                                               lineWidth: 1)
                            }
                        }
                        for code in ocr.barcodes {
                            let r = scaled(code.box, scale)
                            context.stroke(Path(roundedRect: r, cornerRadius: 2),
                                           with: .color(.green),
                                           lineWidth: 2)
                        }
                    }
                    .frame(width: w, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .background(Color(white: 0.12))
    }

    private func scaled(_ box: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: box.minX * s, y: box.minY * s, width: box.width * s, height: box.height * s)
    }
}

private struct TextInspector: View {
    @Bindable var page: PageVM

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recognized Text").font(.headline)
                Spacer()
                if let c = page.ocr?.averageConfidence {
                    Text("\(Int(c * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Average OCR confidence")
                }
                Button {
                    page.editedText = page.ocr?.fullText ?? ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Revert edits to the recognized text")
                .disabled(page.editedText == (page.ocr?.fullText ?? ""))
            }

            Text("Edit below — your changes are used by the Word / PDF / Text exports.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextEditor(text: $page.editedText)
                .font(.system(.body))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if let barcodes = page.ocr?.barcodes, !barcodes.isEmpty {
                Text("Barcodes").font(.headline)
                ForEach(Array(barcodes.enumerated()), id: \.offset) { _, code in
                    VStack(alignment: .leading) {
                        Text(code.symbology).font(.caption).foregroundStyle(.secondary)
                        Text(code.payload).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
    }
}
