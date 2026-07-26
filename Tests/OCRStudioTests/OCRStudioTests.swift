import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import OCRStudio

final class OCRStudioTests: XCTestCase {

    func testGeometryRoundTrip() {
        let normalized = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.30)
        let pixels = Geometry.pixelRectTopLeft(
            fromNormalized: normalized, width: 1_000, height: 2_000
        )
        XCTAssertEqual(pixels.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(pixels.origin.y, 1_000, accuracy: 0.001)
        XCTAssertEqual(pixels.width, 500, accuracy: 0.001)
        XCTAssertEqual(pixels.height, 600, accuracy: 0.001)

        let pdf = Geometry.pdfRect(
            fromPixelTopLeft: pixels, imageHeight: 2_000, scale: 0.5
        )
        XCTAssertEqual(pdf.origin.x, 125, accuracy: 0.001)
        XCTAssertEqual(pdf.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(pdf.width, 250, accuracy: 0.001)
        XCTAssertEqual(pdf.height, 300, accuracy: 0.001)
    }

    func testSettingsDecodeMissingNewKeysWithDefaults() throws {
        let legacy = Data(#"{"recognitionLanguages":["fr-FR"],"rasterDPI":300}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)

        XCTAssertEqual(settings.recognitionLanguages, ["fr-FR"])
        XCTAssertEqual(settings.rasterDPI, 300)
        XCTAssertTrue(settings.automaticLanguageDetection)
        XCTAssertTrue(settings.detectBarcodes)
        XCTAssertEqual(settings.textLayerPolicy, .ocrIfSparse)
        XCTAssertTrue(settings.autoCropScannedPages)
    }

    func testTextPDFPreservesLogicalPages() throws {
        let output = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        try RichTextExport.writeTextPDF(pages: ["First page", "Second page"], to: output)

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("First page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Second page") == true)
    }

    func testDocxDropsForbiddenXMLNoncharacters() {
        let forbidden = "before\u{FFFE}middle\u{FFFF}after"
        let data = DocxWriter.data(pages: [forbidden])

        XCTAssertNil(data.range(of: Data([0xEF, 0xBF, 0xBE])))
        XCTAssertNil(data.range(of: Data([0xEF, 0xBF, 0xBF])))
        XCTAssertNotNil(data.range(of: Data("beforemiddleafter".utf8)))
    }

    func testMultiPageTIFFIngestsEveryFrame() async throws {
        let source = temporaryURL(extension: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = try solidImage(width: 12, height: 18)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.tiff.identifier as CFString, 2, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pages = try await FileIngestor().ingest(url: source, dpi: 200)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].image.width, 12)
        XCTAssertEqual(pages[0].image.height, 18)
    }

    func testImageIngestAppliesMetadataOrientation() async throws {
        let source = temporaryURL(extension: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = try solidImage(width: 12, height: 18)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6 // 90° clockwise
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pages = try await FileIngestor().ingest(url: source, dpi: 200)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].image.width, 18)
        XCTAssertEqual(pages[0].image.height, 12)
    }

    func testInvalidPDFDPIThrowsBeforeRasterization() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeTextPDF(at: source, text: "DPI validation")

        do {
            _ = try await FileIngestor().ingest(url: source, dpi: .infinity)
            XCTFail("Expected invalid DPI to throw")
        } catch PipelineError.invalidDPI {
            // Expected.
        }
    }

    func testExistingPDFTextRetainsGeometryAndSearchability() async throws {
        let source = temporaryURL(extension: "pdf")
        let output = temporaryURL(extension: "pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try makeTextPDF(at: source, text: "Existing searchable text")

        let ingested = try await FileIngestor().ingest(url: source, dpi: 144)
        XCTAssertEqual(ingested.count, 1)
        XCTAssertFalse(ingested[0].existingLines.isEmpty)
        XCTAssertTrue(ingested[0].existingLines.allSatisfy {
            $0.box.width > 0 && $0.box.height > 0
        })

        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.enhanceContrast = false
        settings.denoise = false
        let manager = JobManager()
        let pages = try await manager.process(url: source, settings: settings)
        try await manager.writeSearchablePDF(pages, to: output)

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(result.string?.contains("Existing searchable text") == true)
    }

    func testCorruptInputThrowsInsteadOfProducingNoPages() async throws {
        let source = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("not an image".utf8).write(to: source)

        do {
            _ = try await JobManager().process(url: source, settings: Settings())
            XCTFail("Expected corrupt input to throw")
        } catch {
            XCTAssertTrue(error is PipelineError)
        }
    }

    func testWatchRetriesFailureAndProcessesRecreatedPath() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recorder = AttemptRecorder()
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in await recorder.record() }
        try await watcher.start(folder: folder, pollInterval: 0.03)

        let input = folder.appendingPathComponent("page.png")
        try Data("first".utf8).write(to: input)
        let retriedSuccessfully = await eventually { await recorder.count >= 2 }
        XCTAssertTrue(retriedSuccessfully)

        try FileManager.default.removeItem(at: input)
        try await Task.sleep(nanoseconds: 100_000_000)
        try Data("replacement".utf8).write(to: input)
        let replacementProcessed = await eventually { await recorder.count >= 3 }
        XCTAssertTrue(replacementProcessed)
        await watcher.stop()
    }

    func testWatchRejectsAFileAsFolder() async throws {
        let file = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)

        do {
            try await WatchFolderService().start(folder: file, pollInterval: 0.03)
            XCTFail("Expected a non-directory watch path to throw")
        } catch {
            // Expected.
        }
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioTest-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTextPDF(at url: URL, text: String) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(
            consumer: consumer, mediaBox: &mediaBox, nil
        ))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 36, y: 120)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
    }
}

private actor AttemptRecorder {
    private(set) var count = 0

    func record() -> Bool {
        count += 1
        return count >= 2
    }
}
